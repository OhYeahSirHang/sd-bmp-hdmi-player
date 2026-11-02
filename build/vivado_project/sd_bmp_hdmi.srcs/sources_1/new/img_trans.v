`timescale 1ns/1ps
// --------------------------------------------------------------------
// img_trans.v  v3: 图片切换过渡效果模块 (运行时4选)
// --------------------------------------------------------------------
// 位置: ddr3_tx_buffer(或 img_scaler) 与 img_process 之间
// 作用: 按KEY切图时, 新图在后台缓冲加载完成后, 播放 2s 过渡动画
//        (旧图消失 1s -> VSYNC原子换帧 -> 新图出现 1s)
// --------------------------------------------------------------------
// ★★★★★ 过渡效果(运行时选择, 来自 key_menu 的 effect_sel) ★★★★★
//   effect_sel: 0=淡入淡出  1=切入(左右滑动)  2=随机线条  3=溶解
//   菜单"效果"行循环选择, 无需改代码换效果
// --------------------------------------------------------------------
// 说明:
//   - 淡入淡出: 纯像素亮度渐变, 不依赖DDR3地址
//   - 切入: 旧图向左滑出, 新图从右滑入 (需 ddr3_tx_buffer 行旋转 rd_off)
//   - 随机线条: 随机竖线逐帧增多遮住旧图/显露新图 (LFSR伪随机, 纯位运算)
//   - 溶解: 逐像素随机抖动, 旧图渐溶黑场、新图渐显 (同上, 随机源含y)
//   - 过渡期间再次按KEY: 动画播完当前这张后自动接下一张(排队)
//   - 上电第一张图片直接显示, 不播放过渡(从黑场直接出现)
// --------------------------------------------------------------------
module img_trans (
    input              clk         , // 148.5MHz 像素时钟
    input              rst_n       ,
    input              vsync       , // 场同步(148.5M域, 用于按帧推进动画)
    // ---- 数据流(与 data_req 同拍有效) ----
    input              data_req    , // 原 vga_de (像素有效)
    input      [23:0]  data_in     , // 来自 tx_buffer / scaler 的像素
    output reg [23:0]  data_out    , // 过渡后像素 -> img_process
    output reg         data_out_req, // 与 data_out 对齐的像素有效(延迟1拍)
    // ---- 与 rd_img(50M域)的握手 ----
    input              frame_ready , // 1: 新一帧已完整写入后台缓冲 (50M域)
    input              disp_buf_sel, // 显示缓冲选择 (50M域, 检测换帧)
    input              media_sel   , // 0=图片 1=视频 (50M域, 切换时清过渡状态)
    output             swap_allow  , // 1: 允许rd_img在VSYNC切换双缓冲
    // ---- 效果选择 (50M域, key_menu) ----
    input      [3:0]   effect_sel  , // 0淡入 1切入 2随机线条 3溶解 4百叶窗 5中心扩散 6上下合拢 7棋盘格
    // ---- 滑动/切入效果需要 ----
    input      [11:0]  img_w       , // 当前图片宽度(源像素, 自适应)
    input      [10:0]  x_off       , // 黑边左偏移(来自img_scaler, 同148.5M域)
    input      [10:0]  disp_w      , // 显示宽(0<disp_w<=1920, 来自img_scaler)
    input      [27:0]  step_fix    , // 水平缩放定点步进 = W*2^16/disp_w (img_scaler)
    output     [11:0]  rd_off      , // 行旋转偏移(源像素) -> ddr3_tx_buffer/img_scaler
    output             geom_update , // 1: 检测到缓冲切换(换帧), 通知img_scaler锁存几何
    // ---- 辅助(供观察/仿真) ----
    output      [1:0]  trans_state   // 0=空闲 1=旧图退出 2=等换帧 3=新图进入
);
//==================================================================
// 参数
//==================================================================
parameter [5:0]  TRANS_FRAMES = 6'd60;    // 每相帧数 (60fps => 1s/相, 共2s), TB可覆盖缩短
localparam [10:0] SLIDE_STEP   = 11'd32;   // 切入每帧屏幕像素数 (1920/60)
localparam [10:0] SCREEN_X     = 11'd1920; // 屏幕宽
localparam [15:0] ALPHA_MUL    = 16'd1111; // 65536/59, 用于无除法线性渐变
//==================================================================
// VSYNC 上升沿检测 (148.5M域)
//==================================================================
reg vsync_d1, vsync_d2;
wire vsync_rise = vsync_d1 & (~vsync_d2);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin vsync_d1 <= 1'b1; vsync_d2 <= 1'b1; end
    else       begin vsync_d1 <= vsync; vsync_d2 <= vsync_d1; end
end
//==================================================================
// 媒体切换同步 (50M -> 148.5M); 切换时硬清过渡状态, 避免 rd_off 残留
//==================================================================
reg media_s1, media_s2;
wire media_chg_148;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin media_s1 <= 1'b0; media_s2 <= 1'b0; end
    else       begin media_s1 <= media_sel; media_s2 <= media_s1; end
end
assign media_chg_148 = media_s1 ^ media_s2;

//==================================================================
// 跨时钟同步 (50M -> 148.5M)
//==================================================================
reg frame_ready_s1, frame_ready_s2;
reg buf_sel_s1,     buf_sel_s2;
reg [11:0] img_w_s1, img_w_s2;
    reg [3:0]  eff_s1,   eff_s2;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        frame_ready_s1 <= 1'b0; frame_ready_s2 <= 1'b0;
        buf_sel_s1     <= 1'b0; buf_sel_s2     <= 1'b0;
        img_w_s1       <= 12'd1920; img_w_s2 <= 12'd1920;
        eff_s1         <= 4'd0; eff_s2 <= 4'd0;
    end
    else begin
        frame_ready_s1 <= frame_ready; frame_ready_s2 <= frame_ready_s1;
        buf_sel_s1     <= disp_buf_sel; buf_sel_s2     <= buf_sel_s1;
        img_w_s1       <= img_w;        img_w_s2       <= img_w_s1;
        eff_s1         <= effect_sel;   eff_s2         <= eff_s1;
    end
end
wire frame_ready_sync = frame_ready_s2;
wire buf_sel_sync     = buf_sel_s2;
// 效果在过渡开始时锁存(中途按键不改当前动画)
reg [3:0] eff_run;
//==================================================================
// 状态机
//==================================================================
localparam [1:0] S_IDLE      = 2'd0;
localparam [1:0] S_PH1_OUT   = 2'd1; // 旧图退出 (淡出/左滑/线条遮罩/溶解)
localparam [1:0] S_WAIT_SWAP = 2'd2; // 允许换帧, 等VSYNC原子切换
localparam [1:0] S_PH2_IN    = 2'd3; // 新图进入 (淡入/右滑/线条显露/溶解)
reg [1:0] state;
reg [5:0] frame_cnt;   // 相内帧计数 0..TRANS_FRAMES-1
reg       swap_allow_r;
reg       first_done;  // 上电第一张图是否已显示
reg       buf_sel_prev;

assign swap_allow  = swap_allow_r;
assign trans_state = state;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state        <= S_IDLE;
        frame_cnt    <= 6'd0;
        swap_allow_r <= 1'b1;   // 复位后默认允许直接换帧
        first_done   <= 1'b0;
        buf_sel_prev <= 1'b0;
        eff_run      <= 4'd0;
    end
    else if(media_chg_148) begin
        // 媒体切换: 直接显示新源, 不跑过渡, 且清掉可能残留的滑动偏移
        state        <= S_IDLE;
        frame_cnt    <= 6'd0;
        swap_allow_r <= 1'b1;
        first_done   <= 1'b0;
        buf_sel_prev <= buf_sel_sync;
        eff_run      <= 4'd0;
    end
    else begin
        buf_sel_prev <= buf_sel_sync;
        case (state)
        //-----------------------------------------------------------
        S_IDLE: begin
            swap_allow_r <= 1'b0;
            if(frame_ready_sync) begin
                if(!first_done) begin
                    // 上电第一张: 直接换帧, 跳过旧画面退出相
                    swap_allow_r <= 1'b1;
                    eff_run      <= eff_s2;
                    state        <= S_WAIT_SWAP;
                end
                else begin
                    eff_run   <= eff_s2;   // 锁存本次过渡效果
                    state     <= S_PH1_OUT;
                    frame_cnt <= 6'd0;
                end
            end
        end
        //-----------------------------------------------------------
        S_PH1_OUT: begin // 旧图退出
            swap_allow_r <= 1'b0;
            if(vsync_rise) begin
                if(frame_cnt == TRANS_FRAMES - 1'b1) begin
                    swap_allow_r <= 1'b1;   // 允许换帧
                    state        <= S_WAIT_SWAP;
                end
                else
                    frame_cnt <= frame_cnt + 1'b1;
            end
        end
        //-----------------------------------------------------------
        S_WAIT_SWAP: begin // 等 rd_img 在 VSYNC 完成原子切换
            swap_allow_r <= 1'b1;
            if(buf_sel_sync != buf_sel_prev) begin // 检测到已换帧
                swap_allow_r <= 1'b0;
                first_done   <= 1'b1;
                state        <= S_PH2_IN;
                frame_cnt    <= 6'd0;
            end
        end
        //-----------------------------------------------------------
        S_PH2_IN: begin // 新图进入
            swap_allow_r <= 1'b0;
            if(vsync_rise) begin
                if(frame_cnt == TRANS_FRAMES - 1'b1)
                    state <= S_IDLE;
                else
                    frame_cnt <= frame_cnt + 1'b1;
            end
        end
        //-----------------------------------------------------------
        default: state <= S_IDLE;
        endcase
    end
end
//==================================================================
// 效果参数计算 (每帧更新)
//==================================================================
// 屏幕偏移: 帧号 * 步进 (0..1888) —— 切入效果
wire [10:0] eff_off = frame_cnt * SLIDE_STEP;
reg [27:0] rd_off_fp;    // 滑动偏移定点累加器(16位小数, 每帧 += step_fix)
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        rd_off_fp <= 28'd0;
    else if(media_chg_148)
        rd_off_fp <= 28'd0;
    else if(vsync_rise) begin
        if(eff_run == 4'd1 && (state == S_PH1_OUT || state == S_PH2_IN))
            rd_off_fp <= rd_off_fp + step_fix;
        else
            rd_off_fp <= 28'd0;
    end
end
assign rd_off = rd_off_fp[27:16];   // 仅切入需要; 其他效果为0
// 换帧时刻: 检测到双缓冲切换 -> 通知img_scaler锁存并计算几何(新图参数)
assign geom_update = (state == S_WAIT_SWAP) && (buf_sel_sync != buf_sel_prev);
// 淡入淡出 alpha (0..255) —— 每帧一次, 小乘法避免DSP级联长路径
wire [10:0] fade_p1 = (frame_cnt + 6'd1) * 6'd17; // 11bit, 2~3ns
reg [7:0] alpha;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        alpha <= 8'd255;
    else begin
        if(eff_run == 4'd0) begin // 淡入淡出
            if(state == S_PH1_OUT)
                alpha <= 8'd255 - fade_p1[9:2];  // 淡出: 255 -> 0
            else if(state == S_PH2_IN)
                alpha <= fade_p1[9:2];           // 淡入: 0 -> 255
            else
                alpha <= 8'd255;
        end
        else alpha <= 8'd255; // 其他效果: 不调亮度
    end
end
//==================================================================
// 像素/行计数
//==================================================================
reg [10:0] x_cnt;
reg [10:0] y_cnt;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x_cnt <= 11'd0; y_cnt <= 11'd0;
    end
    else if(data_req) begin
        if(x_cnt == SCREEN_X - 1'b1) begin
            x_cnt <= 11'd0;
            if(y_cnt == 11'd1079) y_cnt <= 11'd0;
            else                  y_cnt <= y_cnt + 1'b1;
        end
        else x_cnt <= x_cnt + 1'b1;
    end
end
//==================================================================
// 随机线条/溶解 伪随机源 (10bit LFSR, 每帧更新; 纯位运算, 快)
//==================================================================
reg [9:0] seed;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        seed <= 10'd1;
    else if(vsync_rise && (state == S_PH1_OUT || state == S_PH2_IN))
        seed <= {seed[8:0], seed[9] ^ seed[6]};   // 10bit LFSR x^10+x^7+1
end
wire [10:0] x_box     = x_cnt - x_off;
wire [10:0] y_box     = y_cnt - (11'd1080 - disp_w); // 仅占位, 实际用y_cnt
// 随机线条: 随机值只依赖x -> 竖线条
wire [9:0] rnd_line = {x_box[8], x_box[2], x_box[6], x_box[0], x_box[9],
                       x_box[4], x_box[7], x_box[1], x_box[5], x_box[3]} ^ seed;
// 溶解: 随机值依赖x,y -> 逐像素颗粒
wire [9:0] rnd_diss = {x_box[9], y_cnt[6], x_box[3], y_cnt[9], x_box[0],
                       y_cnt[2], x_box[5], y_cnt[4], x_box[7], y_cnt[1]} ^ seed;
wire [9:0] rnd      = (eff_run == 4'd2) ? rnd_line : rnd_diss;
// 阈值: 帧号*17 (60帧 -> 0..1020), PH1遮旧图 / PH2显新图
wire [9:0] t_ph     = fade_p1[9:0];   // (frame_cnt+1)*17
wire        in_box_x  = (x_cnt >= x_off) && (x_cnt < x_off + disp_w);
//------------------------------------------------------------------
// 新增 4 种几何遮罩 (2026-10-28): 百叶窗/中心扩散/上下合拢/棋盘格
//   与随机类一样, 用 t_ph(0..1020) 作为推进阈值; PH1 遮旧图, PH2 显新图
//------------------------------------------------------------------
wire [10:0] dx_c  = (x_cnt > 11'd960) ? (x_cnt - 11'd960) : (11'd960 - x_cnt);
wire [10:0] dy_c  = (y_cnt > 11'd540) ? (y_cnt - 11'd540) : (11'd540 - y_cnt);
wire [5:0]  blk   = {x_box[9:6] ^ y_cnt[9:6], x_box[5:4]};      // 块伪随机值
wire        m_blind   = (x_box[5:0]  < t_ph[9:4]);              // 百叶窗: 竖条逐渐变宽
wire        m_iris    = ((dx_c >> 2) + (dy_c >> 2) < t_ph[9:2]); // 中心扩散(曼哈顿半径)
wire        m_curtain = (y_cnt < t_ph[9:1]) || (y_cnt > (11'd1079 - t_ph[9:1])); // 上下合拢
wire        m_checker = (blk < t_ph[9:4]);                      // 棋盘格: 块逐格翻转
wire        in_phase  = (state == S_PH1_OUT || state == S_PH2_IN);
// 遮罩打一拍: 只影响过渡边缘 1 像素, 但把 x_cnt/y_cnt -> 比较 -> 输出 的长路径切断
reg mask_eff;
always @(posedge clk) begin
    mask_eff <=
        (in_phase && (eff_run == 4'd2 || eff_run == 4'd3) && (rnd < t_ph)) ||
        (in_phase && in_box_x && (
            (eff_run == 4'd4 && m_blind)   ||
            (eff_run == 4'd5 && m_iris)    ||
            (eff_run == 4'd6 && m_curtain) ||
            (eff_run == 4'd7 && m_checker)
        ));
end
//==================================================================
// 像素输出: 切入遮罩 + 随机遮罩 + 亮度渐变
//==================================================================
wire [10:0] off_clamp = (eff_off > disp_w) ? disp_w : eff_off;
wire slide_black =
    (eff_run == 4'd1) && in_box_x && (
        ((state == S_PH1_OUT) && (x_box >= disp_w - off_clamp)) ||
        ((state == S_PH2_IN ) && (x_box <  disp_w - off_clamp))
    );
// 亮度渐变乘法 (与data_req同拍组合, 下一拍寄存; 用DSP缩短148.5M路径)
(* use_dsp="yes" *) wire [15:0] mul_r = data_in[23:16] * alpha;
(* use_dsp="yes" *) wire [15:0] mul_g = data_in[15:8]  * alpha;
(* use_dsp="yes" *) wire [15:0] mul_b = data_in[7:0]   * alpha;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        data_out     <= 24'd0;
        data_out_req <= 1'b0;
    end
    else begin
        data_out_req <= data_req;
        if(slide_black || mask_eff)
            data_out <= 24'h000000;                 // 遮罩黑场
        else if(alpha == 8'd255)
            data_out <= data_in;                    // 不衰减(直通)
        else
            data_out <= {mul_r[15:8], mul_g[15:8], mul_b[15:8]}; // 淡入淡出
    end
end
endmodule
