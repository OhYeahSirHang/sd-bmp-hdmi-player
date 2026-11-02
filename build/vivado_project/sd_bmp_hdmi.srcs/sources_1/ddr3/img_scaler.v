// --------------------------------------------------------------------
`timescale 1ns/1ps
// img_scaler.v  v2: 任意分辨率BMP -> HDMI(1920x1080) 自适应缩放显示
// --------------------------------------------------------------------
// 位置: ddr3_tx_buffer 内部(hdmi域), 读行缓冲 -> 缩放 -> 24bit像素
// 功能:
//   1. 几何计算: 按"等比缩放+居中黑边"计算显示区域
//      K = min(1920*H, 1080*W); disp_w = K/H; disp_h = K/W;
//      x_off=(1920-disp_w)/2;  y_off=(1080-disp_h)/2
//      1920x1080图: 全屏; 窄图: 左右黑边; 矮图: 上下黑边
//   2. 水平最近邻缩放: 定点相位 sx_fp += step_fix (step=W*2^16/disp_w),
//      源列 sx = sx_fp[27:16], 支持任意缩放比(0<disp_w<=1920)
//   3. 行旋转(滑动过渡): 源列加 rd_off 后取模 W
//   4. 行缓冲读取: 通过 tx_buffer 的双口BRAM(2048x128)读取,
//      缓冲选择 = band_line[1:0] (读侧行号低2位, 4槽), 与读侧取行写入一致
//   5. 黑边输出0, 有效区输出缩放像素; 输出与 de(延迟4拍)对齐
//   [FIX-COL] 行缓冲BRAM同步读(2拍) -> lane_d1对齐, de/in_box链扩4级
// --------------------------------------------------------------------
`include "../hdmi/vga_parameter_cfg.v"
module img_scaler(
    input               clk          , // 148.5MHz 像素时钟
    input               rst_n        ,
    input               hdmi_data_req, // vga_de (像素有效)
    input      [11:0]   img_w        , // 源宽(已同步到本域, 来自rd_bmp)
    input      [11:0]   img_h        , // 源高
    input      [11:0]   rd_off       , // 源像素行旋转偏移(来自img_trans, 滑动)
    input               geom_update  , // 1: 换帧时刻(img_trans检测到缓冲切换), 锁存几何
    //行缓冲读取接口(tx_buffer提供同步读BRAM)
    input      [127:0]  rowbuf_dout  , // 同步读输出(与rowbuf_raddr延迟1拍)
    output     [11:0]   rowbuf_raddr , // 读地址 = {0, band[1:0], 字地址[8:0]} (4槽*512字=2048)
    //输出
    output reg [23:0]   hdmi_data    , // 24bit RGB (与hdmi_data_req_out对齐)
    output reg          hdmi_data_req_out, // 延迟2拍的de
    //几何输出(供tx_buffer同步给读侧取行 + img_trans)
    output reg [10:0]   x_off        , // 黑边左偏移
    output reg [10:0]   disp_w       , // 显示宽(0<disp_w<=1920)
    output reg [27:0]   step_fix     , // 水平缩放定点步进 = W*2^16/disp_w
    output reg [10:0]   disp_h       , // 显示高(0<disp_h<=1080)
    output [10:0]       band_line    , // 当前band行号 0..disp_h-1
    output [11:0]       img_w_lat_o  , // 锁存的源宽(换帧时更新, 供tx读侧取行)
    output [11:0]       src_h_o        // 锁存的源高(换帧时更新, 供tx读侧取行)
);
//==================================================================
// 1. 几何计算 (串行恢复除法, 每次换帧后计算一次, 28+28+28=84拍)
//==================================================================
localparam G_IDLE = 2'd0, G_DIV = 2'd1;
reg  [1:0]  gstate;
reg  [1:0]  gph;       // 0=disp_w=K/H  1=disp_h=K/W  2=step_fix=W*2^16/disp_w
reg  [31:0] g_n;       // 被除数
reg  [11:0] g_d;       // 除数
reg  [31:0] g_q;       // 商 (32bit: 被除数32bit需32拍, 修复: 原28拍丢低4位->商缩水16倍)
reg  [31:0] g_r;       // 余数(移位寄存器)
reg  [4:0]  g_i;       // 迭代计数 0..31
reg  [11:0] g_w;       // 计算用宽(锁存)
reg  [11:0] g_h;       // 计算用高
reg  [31:0] g_k;       // K
reg  [11:0] img_w_lat; // 锁存后的宽(供取模/相位使用, 换帧时更新)
reg  [10:0] y_off;     // 黑边上偏移
// [CDC] img_w/img_h 来自50M域(rd_img), 在148.5M域两级同步后使用, 消除跨时钟亚稳态
reg  [11:0] img_w_s1, img_w_s2, img_h_s1, img_h_s2;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        img_w_s1 <= 12'd0; img_w_s2 <= 12'd0;
        img_h_s1 <= 12'd0; img_h_s2 <= 12'd0;
    end else begin
        img_w_s1 <= img_w;
        img_w_s2 <= img_w_s1;
        img_h_s1 <= img_h;
        img_h_s2 <= img_h_s1;
    end
end
wire [31:0] k_wh = `SCREEN_X * img_h_s2;   // 1920*H (同步后)
wire [31:0] k_hw = `SCREEN_Y * img_w_s2;   // 1080*W (同步后)
// 换帧锁存几何: geom_update 上升沿 (img_trans在缓冲切换时给出)
reg  geom_d1;
wire geom_pulse = geom_update & (~geom_d1);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) geom_d1 <= 1'b0;
    else       geom_d1 <= geom_update;
end
// 除法一步(组合): 左移1位 -> 试减
wire [31:0] r_shift = {g_r[30:0], g_n[31]};
wire [31:0] gd_ext  = {20'd0, g_d};
wire        r_ge    = (r_shift >= gd_ext);
wire [31:0] g_q_full = {g_q[30:0], r_ge}; // 含最新商位的完整商(收尾拍读取用)
wire [31:0] r_new   = r_ge ? (r_shift - gd_ext) : r_shift;
// [FIX-VBLANK] 几何参数先算到 pending, 到"帧起始"才生效;
// 否则换图时新尺寸在屏幕中间就生效 -> 上半屏新图/下半屏旧图
reg [10:0] p_disp_w, p_disp_h, p_xoff, p_yoff;
reg [27:0] p_step;
reg [11:0] p_wlat;
reg        p_valid;
reg        fs_pulse;   // 帧起始单拍 (s_x=0,s_y=0,de)
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        gstate <= G_IDLE; gph <= 2'd0;
        g_n <= 32'd0; g_d <= 12'd0; g_q <= 32'd0; g_r <= 32'd0; g_i <= 5'd0;
        g_w <= 12'd1920; g_h <= 12'd1080; g_k <= 32'd0;
        img_w_lat <= 12'd1920;
        x_off <= 11'd0; disp_w <= 11'd1920; disp_h <= 11'd1080; y_off <= 11'd0;
        step_fix <= 28'd65536;   // 1920*2^16/1920
        p_disp_w <= 11'd1920; p_disp_h <= 11'd1080; p_xoff <= 11'd0; p_yoff <= 11'd0;
        p_step <= 28'd65536; p_wlat <= 12'd1920; p_valid <= 1'b0;
// band_line 由 band_starts 组合得出(assign), 复位由 band_starts<=1 保证为0
    end
    else if(p_valid && fs_pulse) begin
        // [FIX-VBLANK] 只在帧起始切几何, 保证整帧用同一套参数
        disp_w   <= p_disp_w;
        disp_h   <= p_disp_h;
        x_off    <= p_xoff;
        y_off    <= p_yoff;
        step_fix <= p_step;
        img_w_lat<= p_wlat;
        p_valid  <= 1'b0;
    end
    else case (gstate)
        G_IDLE: begin
            // [MODE-FIXED] 固定 1920x1080 全屏 1:1:
            //   源图就是 1920x1080、屏也是 1920x1080, 不需要缩放/居中,
            //   彻底绕开"除法器/几何锁存"这条不可靠路径。
            //   disp_w/disp_h/x_off/y_off/step_fix/img_w_lat 全部保持复位值。
            if(1'b0) begin
                p_valid <= 1'b0;
            end
        end
        G_DIV: begin
            g_r <= r_new;
            g_n <= {g_n[30:0], 1'b0};
            g_q <= {g_q[30:0], r_ge};
            if(g_i == 5'd31) begin
                g_i  <= 5'd0;
                g_q  <= 32'd0; g_r <= 32'd0;
                case (gph)
                2'd0: begin // disp_w = K/H (最小1)
                    p_disp_w <= (g_q_full[10:0] == 11'd0) ? 11'd1 : g_q_full[10:0];
                    g_n <= g_k; g_d <= g_w; gph <= 2'd1;   // 第二除: /W -> disp_h
                end
                2'd1: begin // disp_h = K/W (最小1)
                    p_disp_h <= (g_q_full[10:0] == 11'd0) ? 11'd1 : g_q_full[10:0];
                    g_n <= {g_w, 16'd0}; g_d <= {1'b0, p_disp_w}; gph <= 2'd2; // 第三除: W*2^16/disp_w
                end
                2'd2: begin // step_fix
                    p_step   <= g_q_full[27:0];
                    p_xoff   <= (11'd1920 - p_disp_w) >> 1;
                    p_yoff   <= (11'd1080 - p_disp_h) >> 1;
                    p_valid  <= 1'b1;                 // 等帧起始生效
                    gph      <= 2'd0;
                    gstate   <= G_IDLE;
                end
                endcase
            end
            else
                g_i <= g_i + 1'b1;
        end
        default: gstate <= G_IDLE;
    endcase
end
//==================================================================
// 2. 像素/行计数与band行跟踪
//==================================================================
// [FIX-SY] 行缓冲槽号必须用"源行"而不是"显示行":
//   取行侧按源行 k 写入 slot=k%4; 缩放时一个源行要显示多行(如 240->1080 约 4.5 行),
//   若用显示行选槽, 槽号会与取行侧错开 -> 隔行全黑。
reg [11:0] sy_cur;   // 当前显示行对应的源行号 0..H-1
reg [11:0] sy_acc;   // Bresenham 余数
reg [10:0] s_x;      // 显示列 0..1919
reg [10:0] s_y;      // 显示行 0..1079
reg [10:0] band_starts; // band行起始计数 1..disp_h (当前行 = band_starts-1)
wire [10:0] band_line_c = band_starts - 1'b1;
assign band_line  = band_line_c;
assign img_w_lat_o = img_w_lat;
assign src_h_o     = g_h;
wire in_band = (s_y >= y_off) && (s_y < y_off + disp_h);
wire in_box  = in_band && (s_x >= x_off) && (s_x < x_off + disp_w);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        s_x <= 11'd0; s_y <= 11'd0; band_starts <= 11'd1;
        sy_cur <= 12'd0; sy_acc <= 12'd0;
        fs_pulse <= 1'b0;
    end
    else if(hdmi_data_req) begin
        fs_pulse <= (s_x == 11'd0) && (s_y == 11'd0);
        if(s_x == 11'd1919) begin
            s_x <= 11'd0;
            if(s_y == 11'd1079) s_y <= 11'd0; else s_y <= s_y + 1'b1;
        end
        else
            s_x <= s_x + 1'b1;
        if(in_band && s_x == x_off) begin               // 行首: 推进到本行对应的源行
            if(sy_acc + img_h >= disp_h) begin
                sy_acc <= sy_acc + img_h - disp_h;
                if(sy_cur == img_h - 1'b1) sy_cur <= 12'd0;
                else                       sy_cur <= sy_cur + 1'b1;
            end
            else sy_acc <= sy_acc + img_h;
        end
        if(in_band && s_x == x_off + disp_w - 1) begin   // band行尾才递增, 整行期间 band_line 保持本行号
            if(band_starts == disp_h) band_starts <= 11'd1;
            else                      band_starts <= band_starts + 1'b1;
        end
    end
end
//==================================================================
// 3. 水平最近邻缩放 + 行旋转 + 行缓冲读取
//==================================================================
reg  [27:0] sx_fp;   // 水平相位(定点, 16位小数); 源列 = [27:16]
wire [11:0] sx      = sx_fp[27:16];              // 源像素列 0..W-1
wire [12:0] sx_sum  = {1'b0, sx} + {1'b0, rd_off};
wire [11:0] sx_rot  = (sx_sum >= {1'b0, img_w_lat}) ? (sx_sum - {1'b0, img_w_lat}) : sx_sum[11:0];
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        sx_fp <= 28'd0;
    else if(hdmi_data_req) begin
        if(in_box && s_x == x_off)
            sx_fp <= 28'd0;                          // band行首复位
        else if(in_box)
            sx_fp <= sx_fp + step_fix;               // 每输出像素推进相位
    end
end
// 行缓冲读地址(拍1) 与 in_box 延迟
reg  [11:0] raddr;
reg  [2:0] lane;
reg        in_box_d1, in_box_d2, in_box_d3, in_box_d4, de_d1, de_d2, de_d3, de_d4;
reg  [2:0] lane_d1;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin raddr <= 12'd0; lane <= 3'd0; in_box_d1 <= 1'b0; end
    else if(hdmi_data_req) begin
        raddr   <= in_box ? {1'b0, band_line_c[1:0], sx_rot[11:3]} : 12'd0;
        // [FIX-SLOT] 槽=bit[10:9](跨距512), 字=bit[8:0] -> 4槽*512=2048, 与写侧
        //   {1'b0,data_row[1:0],waddr[8:0]} 完全一致。原 {band_line_c[1:0],sx_rot[11:3]}
        //   槽在 bit[11:10](跨距1024), 槽2/3越界 -> 与槽0/1混叠 -> 2行重复+动态撕裂。
        lane    <= in_box ? sx_rot[2:0] : 3'd0;
        in_box_d1 <= in_box;
    end
end
// [FIX-COL] 行缓冲是推断BRAM同步读: raddr锁存(1拍) + BRAM输出(1拍) = 2拍延迟,
//   lane 必须同样延迟1拍(lane_d1)与 rowbuf_dout(rdw_r) 同拍, 否则 raddr超前1拍
//   配 lane 落后1拍 -> 每个8像素块内像素循环错位(行列错位/行正常)。原 {lane} 直接
//   用会输出 rowbuf[字(T-1)][lane(T-1)]。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) lane_d1 <= 3'd0;
    else       lane_d1 <= lane;
end
assign rowbuf_raddr = raddr;
// 数据链: raddr(1拍) -> BRAM输出rdw_r(1拍) -> px16(1拍) -> hdmi_data(1拍) = 4拍
// de/in_box 链同步扩到 4 级与数据链对齐
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        in_box_d2 <= 1'b0; de_d1 <= 1'b0;
        in_box_d3 <= 1'b0; de_d2 <= 1'b0;
        in_box_d4 <= 1'b0; de_d3 <= 1'b0; de_d4 <= 1'b0;
    end
    else begin
        in_box_d2 <= in_box_d1;
        de_d1     <= hdmi_data_req;
        in_box_d3 <= in_box_d2;
        de_d2     <= de_d1;
        in_box_d4 <= in_box_d3;
        de_d3     <= de_d2;
        de_d4     <= de_d3;
    end
end
// 输出(拍5): 用lane_d1选16bit -> 展开24bit; 黑边输出0; 与de(延迟4拍)对齐
reg [15:0] px16;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        px16 <= 16'd0; hdmi_data <= 24'd0; hdmi_data_req_out <= 1'b0;
    end
    else begin
        // [FIX-LANE] 2026-10-21: 行缓冲 128bit 字内的 8 个像素是"低位=组内最右"打包的
        //   (ddr3_rx_fifo 16bit->128bit), 取像素必须反向:
        //   lane=0 -> dout[127:112], lane=7 -> dout[15:0]。
        //   原写法 dout[lane_d1*16 +: 16] 使每 8 像素一组左右镜像, 表现为:
        //   - 原图/灰度: 文字被切成竖条、笔画错位(背景平滑看不出来)
        //   - 边缘模式: 每个 8px 边界都变成台阶, Sobel 整屏点亮成斜向点阵
        px16 <= rowbuf_dout[(3'd7 - lane_d1)*16 +: 16];
        hdmi_data_req_out <= de_d4;
        if(!in_box_d4)
            hdmi_data <= 24'd0;
        else
            hdmi_data <= {px16[15:11], px16[13:11],
                          px16[10:5],  px16[6:5],
                          px16[4:0],   px16[2:0]};
    end
end
endmodule
