`timescale 1ns/1ps
// --------------------------------------------------------------------
// img_process.v  v3: DDR3读出之后、HDMI编码之前 的实时图像处理模块
//   模式: 0=原图直通 1=灰度 2=Sobel边缘(白线黑底) 3=边缘彩色叠加(边缘保原色)
//         4=负片 5=黑白 6=红调 7=冷调 8=浮雕 9=色阶 10=线稿 11=锐化 12=模糊
//         13=复古 14=紫调 15=绿调 16=中值滤波(3x3灰度) 17=Canny近似(双阈值)
// 多图层 OSD (全部在像素时钟域, 文本渲染两级流水保证时序):
//   L1 左上角: 图片参数  "BMP 1920x1080 #03" (类型/分辨率/编号, ASCII, 放大2倍)
//   L2 右上角: 功能菜单 4行, 左对齐, 选中行蓝底高亮 (KEY1选行/KEY2取值)
//              图片[下一张] / 模式[原图|灰度|边缘|彩色叠加]
//              颜色[黑白红蓝绿] / 效果[淡入淡出|切入|随机线条|溶解]
//   L3 正下方: 中文字幕(默认"智能图片播放器"+Logo), 5色可换(控制正下方字幕)
//   L4 顶部滚动字幕: 保留 v2 跑马灯, 默认关闭(ENABLE_TOP_MARQUEE=0, 打开需
//              把其Y移到菜单下方避免重叠), 文本与速度仍可在设置区改
// 图层优先级: 菜单 > 中文字幕 > 参数 > 顶部字幕 > 图像
// 流水线: 图像通路 4拍(mode_out) + OSD文本 2拍 => 输出比 data_req 晚6拍,
//         data_out 与 de_out 严格对齐
//
// ==================== 修改指南 (代码易改区) ====================
// 1. 正下方中文字幕: 改 CN_TEXT 表(函数cn_sub_char) + CN_CH_NUM + CN_X/CN_Y
// 2. 字幕颜色: 改 COLOR_TABLE (color_sel 0..4 = 黑/白/红/蓝/绿)
// 3. 菜单位置: 改 MENU_X / MENU_Y / MENU_ROW_H / MENU_W
// 4. 参数位置: 改 P_X / P_Y
// ==============================================================
`include "../hdmi/vga_parameter_cfg.v"
module img_process(
    input            clk        , //像素时钟 148.5MHz
    input            rst_n      ,
    input            data_req   , //像素有效(原vga_de)
    input  [23:0]    data_in    , //{R,G,B} RGB888
    input  [4:0]     mode       , //0..14原15种 + 15中值 + 16Canny近似 (菜单控制)
    input  [7:0]     img_num    , //当前图片编号(50M域)
    input  [1:0]     img_type   , //1=BMP 2=JPEG (50M域)
    input  [11:0]    img_w      , //当前图宽 (50M域)
    input  [11:0]    img_h      , //当前图高 (50M域)
    input            menu_show  , //1: 显示右上角菜单 (50M域)
    input  [2:0]     menu_row   , //当前选中行 0=媒体 1=图片 2=模式 3=颜色 4=效果
    input            media_sel  , //0=图片 1=视频 (媒体行显示用)
    input  [3:0]     vid_fps_t  , //视频实测帧率 十位
    input  [3:0]     vid_fps_o  , //视频实测帧率 个位
    input  [2:0]     color_sel  , //字幕颜色 0=黑 1=白 2=红 3=蓝 4=绿
    input  [3:0]     effect_sel , //0淡入淡出 1切入 2随机线条 3溶解 4百叶窗 5中心扩散 6上下合拢 7棋盘格
    output reg [23:0] data_out  , //处理+OSD 后
    output reg         de_out     //与data_out对齐的数据有效
);
//==========================================================
// 参数
//==========================================================
// [FIX-TH] 565 输入下台阶更粗: 128 会让 565 量化色带整片点亮(斜向点纹)。
//   192 = 保留真实轮廓 + 45° 色带等值线(目标效果); 384/512 = 只要真实轮廓, 背景全黑,
//   改动这一处即可, 不需动其他逻辑。
localparam SOBEL_TH   = 12'd192;    //Sobel幅值阈值 (模式2边缘)
localparam CANNY_TH_HI = 12'd256;   //Canny近似 强边缘阈值 (模式16, >SOBEL_TH取"纯"轮廓)
localparam CANNY_TH_LO = 12'd96;    //Canny近似 弱边缘阈值 (强白/弱灰/黑底)
//---------- 左上角 图片参数 (ASCII) ----------
// 诊断版: 字号放大2倍(16->32宽/32->64高), 便于实板拍清 img_w/img_h 数值
localparam P_X      = 11'd16;       //参数区左X
localparam P_Y      = 11'd16;       //参数区顶Y
localparam P_CHAR_W = 11'd32;       //8*放大倍数(诊断: 2x)
localparam P_CHAR_H = 11'd64;       //16*放大倍数(诊断: 2x)
localparam P_CH_NUM = 11'd17;       //"BMP 1920x1080 #03" 17字符
localparam P_W      = P_CH_NUM * P_CHAR_W;
//---------- 右上角 菜单 ----------
localparam MENU_X     = 11'd1680;   //菜单区左X (1920-16-224)
localparam MENU_Y     = 11'd16;     //菜单区顶Y
localparam MENU_W     = 11'd224;    //菜单区宽
localparam MENU_ROW_H = 11'd36;     //行高(32文字+4间隔)
localparam MENU_NUM   = 11'd5;      //行数(媒体/图片/模式/颜色/效果)
localparam [23:0] MENU_BAR = 24'h0066CC; //选中行高亮底色
localparam [23:0] MENU_TXT = 24'hFFFFFF; //菜单文字颜色
//---------- 正下方 中文字幕 ----------
localparam CN_CHAR_W = 11'd32;      //16*放大倍数
localparam CN_CHAR_H = 11'd32;      //16*放大倍数
localparam CN_CH_NUM = 11'd8;       //字幕字符个数(7汉字+1Logo)
localparam CN_TEXT_W = CN_CH_NUM * CN_CHAR_W;
localparam CN_Y      = `SCREEN_Y - 11'd16 - CN_CHAR_H; // 底部距边16
localparam CN_X      = (`SCREEN_X - CN_TEXT_W) >> 1;   // 水平居中
//字幕颜色表: color_sel 0..4 = 黑/白/红/蓝/绿 (改这里)
localparam [23:0] CN_COLOR0 = 24'h000000; // 黑
localparam [23:0] CN_COLOR1 = 24'hFFFFFF; // 白
localparam [23:0] CN_COLOR2 = 24'hFF0000; // 红
localparam [23:0] CN_COLOR3 = 24'h0000FF; // 蓝
localparam [23:0] CN_COLOR4 = 24'h00FF00; // 绿
//---------- 顶部滚动字幕 (默认关闭) ----------
localparam ENABLE_TOP_MARQUEE = 1'b0;  // 1=打开(v2跑马灯) 0=关闭
//==========================================================
// 输入域像素坐标与行号 (与 data_req 同拍, 供灰度/Sobel流水线)
//==========================================================
reg [10:0] x_cnt; //列 0~1919
reg [10:0] y_cnt; //行 0~1079
wire       eol_in = data_req && (x_cnt == 11'd1919); //行末
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin x_cnt <= 11'd0; y_cnt <= 11'd0; end
    else if(data_req) begin
        if(x_cnt == 11'd1919) begin x_cnt <= 11'd0; y_cnt <= y_cnt + 1'b1; end
        else x_cnt <= x_cnt + 1'b1;
    end
end
//==========================================================
// 输出域像素坐标 (与 de0 同拍, 供OSD文本层)
//==========================================================
reg [3:0] de_shift;
reg       de0; //图像通路第4级输出有效
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin de_shift <= 4'd0; de0 <= 1'b0; end
    else begin
        de_shift <= {de_shift[2:0], data_req};
        de0      <= de_shift[3];
    end
end
reg [10:0] osd_x; //列 0~1919
reg [10:0] osd_y; //行 0~1079 (末行必须回绕, 否则字幕/菜单每帧位置漂移)
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin osd_x <= 11'd0; osd_y <= 11'd0; end
    else if(de0) begin
        if(osd_x == 11'd1919) begin
            osd_x <= 11'd0;
            osd_y <= (osd_y == 11'd1079) ? 11'd0 : osd_y + 1'b1;
        end
        else osd_x <= osd_x + 1'b1;
    end
end
//==========================================================
// 灰度计算与一级流水 (拍0)
//==========================================================
wire [15:0] y_sum = 16'd77 * data_in[23:16] + 16'd150 * data_in[15:8] + 16'd29 * data_in[7:0];
reg  [7:0]  gray_r ; //灰度打拍
reg  [10:0] addr_r ; //列地址打拍(写RAM与发起读共用)
reg         req_r  ;
reg         eol_r  ;
reg         col_ge2_r; //x_cnt>=2(窗口左邻完整)
reg  [10:0] y_d1   ;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        gray_r <= 'd0; addr_r <= 'd0; req_r <= 1'b0; eol_r <= 1'b0;
        col_ge2_r <= 1'b0; y_d1 <= 'd0;
    end
    else begin
        gray_r     <= y_sum[15:8];
        addr_r     <= x_cnt;
        req_r      <= data_req;
        eol_r      <= eol_in;
        col_ge2_r  <= (x_cnt >= 11'd2);
        y_d1       <= y_cnt;
    end
end
//==========================================================
// 行缓冲: 3个 2048x8bit BRAM 轮转, 存灰度
//==========================================================
(* ram_style = "block" *) reg [7:0] line_buf0 [0:2047];
(* ram_style = "block" *) reg [7:0] line_buf1 [0:2047];
(* ram_style = "block" *) reg [7:0] line_buf2 [0:2047];
reg [1:0] wr_sel ;
reg [1:0] rd1_sel;
reg [1:0] rd2_sel;
always @(posedge clk) begin
    if(req_r && wr_sel == 2'd0) line_buf0[addr_r] <= gray_r;
    if(req_r && wr_sel == 2'd1) line_buf1[addr_r] <= gray_r;
    if(req_r && wr_sel == 2'd2) line_buf2[addr_r] <= gray_r;
end
// [FIX-LANE 之后的窗口取值] 行缓冲读地址与写侧同址 addr_r
//   (曾试 [WIN-REVERT]/[EDGE-XSHIFT] 调整窗口列, 均无效: 点纹的真正原因是
//    128bit 字内 8 个像素的左右镜像, 已在 img_scaler.v 的 [FIX-LANE] 修正)
reg [7:0] r1_raw;
reg [7:0] r2_raw;
always @(posedge clk) begin
    case(rd1_sel)
        2'd0: r1_raw <= line_buf0[addr_r];
        2'd1: r1_raw <= line_buf1[addr_r];
        2'd2: r1_raw <= line_buf2[addr_r];
        default: ;
    endcase
end
always @(posedge clk) begin
    case(rd2_sel)
        2'd0: r2_raw <= line_buf0[addr_r];
        2'd1: r2_raw <= line_buf1[addr_r];
        2'd2: r2_raw <= line_buf2[addr_r];
        default: ;
    endcase
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin wr_sel <= 2'd0; rd1_sel <= 2'd2; rd2_sel <= 2'd1; end
    else if(eol_r) begin
        wr_sel  <= (wr_sel  == 2'd2) ? 2'd0 : wr_sel  + 1'b1;
        rd1_sel <= (rd1_sel == 2'd2) ? 2'd0 : rd1_sel + 1'b1;
        rd2_sel <= (rd2_sel == 2'd2) ? 2'd0 : rd2_sel + 1'b1;
    end
end
//==========================================================
// 3x3窗口 (与读数据同列: r1_raw/r2_raw=读T的addr, gray_r_d2=T的灰度)
//==========================================================
reg [7:0] cur_p0, cur_p1, cur_p2;
reg [7:0] r1_p0,  r1_p1,  r1_p2;
reg [7:0] r2_p0,  r2_p1,  r2_p2;
reg       req_r_d1;
reg       req_r_d2;
reg       col_ge2_d1;
reg       col_ge2_d2;
reg [10:0] y_d2;
reg [7:0] gray_r_d1;
reg [7:0] gray_r_d2;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cur_p0<=8'd0; cur_p1<=8'd0; cur_p2<=8'd0;
        r1_p0<=8'd0;  r1_p1<=8'd0;  r1_p2<=8'd0;
        r2_p0<=8'd0;  r2_p1<=8'd0;  r2_p2<=8'd0;
        req_r_d1<=1'b0; req_r_d2<=1'b0; col_ge2_d1<=1'b0; y_d2<=11'd0;
        gray_r_d1<=8'd0; gray_r_d2<=8'd0;
    end
    else begin
        req_r_d1  <= req_r;
        req_r_d2  <= req_r_d1;
        col_ge2_d1<= col_ge2_r;
        col_ge2_d2<= col_ge2_d1;
        y_d2      <= y_d1;
        gray_r_d1 <= gray_r;
        gray_r_d2 <= gray_r_d1;
        if(req_r_d2) begin
            cur_p0 <= cur_p1; cur_p1 <= cur_p2; cur_p2 <= gray_r_d2;
            r1_p0  <= r1_p1;  r1_p1  <= r1_p2;  r1_p2  <= r1_raw;
            r2_p0  <= r2_p1;  r2_p1  <= r2_p2;  r2_p2  <= r2_raw;
        end
    end
end
//==========================================================
// Sobel 计算
//==========================================================
wire [10:0] gx = (r2_p2 + {r1_p2,1'b0} + cur_p2) - (r2_p0 + {r1_p0,1'b0} + cur_p0);
wire [10:0] gy = (r2_p0 + {r2_p1,1'b0} + r2_p2) - (cur_p0 + {cur_p1,1'b0} + cur_p2);
wire        valid_win = col_ge2_d2 && (y_d2 >= 11'd2);
reg [10:0] gx_r, gy_r;
reg        valid_win_r;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin gx_r <= 11'd0; gy_r <= 11'd0; valid_win_r <= 1'b0; end
    else begin
        gx_r <= gx; gy_r <= gy; valid_win_r <= valid_win;
    end
end
wire [11:0] mag = (gx_r[10] ? (~gx_r + 12'd1) : gx_r) + (gy_r[10] ? (~gy_r + 12'd1) : gy_r);
reg         edge_o;
reg         canny_hi_o;  //Canny近似: 强边缘 (mag>Canny_HI)
reg         canny_lo_o;  //Canny近似: 弱边缘 (mag>Canny_LO)
reg  [7:0]  gray_o;
reg  [23:0] data_in_d1;
reg  [23:0] data_in_d2;
reg  [23:0] data_in_d3;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        edge_o <= 1'b0; canny_hi_o <= 1'b0; canny_lo_o <= 1'b0;
        gray_o <= 8'd0;
        data_in_d1 <= 24'd0; data_in_d2 <= 24'd0; data_in_d3 <= 24'd0;
    end
    else begin
        edge_o      <= (mag > SOBEL_TH) && valid_win_r;
        canny_hi_o  <= (mag > CANNY_TH_HI) && valid_win_r;
        canny_lo_o  <= (mag > CANNY_TH_LO) && valid_win_r;
        gray_o      <= cur_p0;
        data_in_d1  <= data_in;
        data_in_d2  <= data_in_d1;
        data_in_d3  <= data_in_d2;
    end
end
//==========================================================
// 模式选择 (拍4, 与 de0 对齐; 模式为50M域需两级同步)
//==========================================================
reg [4:0] mode_s1;
reg [4:0] mode_s2;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin mode_s1 <= 5'd0; mode_s2 <= 5'd0; end
    else begin
        mode_s1 <= mode;
        mode_s2 <= mode_s1;
    end
end
//==================================================================
// 15 种图像模式 (v3.2: 在原 10 种基础上新增 锐化/模糊/复古/紫调/绿调)
//==================================================================
wire [7:0] mr = data_in_d3[23:16];
wire [7:0] mg = data_in_d3[15:8];
wire [7:0] mb = data_in_d3[7:0];
// 红调(暖): R*1.25 / G*0.875 / B*0.75
wire [7:0] warm_r = (mr > 8'd204) ? 8'd255 : (mr + (mr >> 2));
wire [7:0] warm_g = mg - (mg >> 3);
wire [7:0] warm_b = mb - (mb >> 2);
// 冷调: R*0.75 / G*0.9375 / B*1.25
wire [7:0] cool_r = mr - (mr >> 2);
wire [7:0] cool_g = mg - (mg >> 4);
wire [7:0] cool_b = (mb > 8'd204) ? 8'd255 : (mb + (mb >> 2));
// 浮雕: 128 - gy/4 (灰度浮雕)
wire signed [11:0] emb_s = 12'sd128 - ($signed(gy_r) >>> 2);
wire [7:0] emboss = (emb_s < 12'sd0) ? 8'd0 : (emb_s > 12'sd255) ? 8'd255 : emb_s[7:0];
// ---- 新增 5 种 ----
// 锐化: 5*center - (up+down+left+right), center=r1_p1 ; [BAL] 加法树, 压 148.5M 关键路径
wire [11:0] sh_c  = {4'b0, r1_p1} + {2'b0, r1_p1, 2'b0};          // center*5
wire [11:0] sh_a  = {4'b0, r2_p1} + {4'b0, cur_p1};               // up + down
wire [11:0] sh_b  = {4'b0, r1_p0} + {4'b0, r1_p2};                // left + right
wire signed [11:0] shp_s = $signed(sh_c) - $signed(sh_a) - $signed(sh_b);
wire [7:0] sharp = (shp_s < 12'sd0) ? 8'd0 : (shp_s > 12'sd255) ? 8'd255 : shp_s[7:0];
// 模糊: 8 邻域平均 ; [BAL] 三级加法树
wire [10:0] bs1 = {3'b0, r2_p0} + {3'b0, r2_p1};
wire [10:0] bs2 = {3'b0, r2_p2} + {3'b0, r1_p0};
wire [10:0] bs3 = {3'b0, r1_p2} + {3'b0, cur_p0};
wire [10:0] bs4 = {3'b0, cur_p1} + {3'b0, cur_p2};
wire [10:0] bs12 = bs1 + bs2;
wire [10:0] bs34 = bs3 + bs4;
wire [10:0] blur_sum = bs12 + bs34;
wire [7:0] blur = blur_sum[10:3];
// [PIPE] 锐化/模糊结果打一拍: 只用于模式 10/11, 落后 1 像素不可见,
//   但把 r1_p* -> 加法树 -> 15 选 1 -> img_d1 的长路径从关键路径上移走。
reg [7:0] sharp_r, blur_r;
always @(posedge clk) begin
    sharp_r <= sharp;
    blur_r  <= blur;
end
//==========================================================
// 中值滤波 (模式15): 3x3 灰度中值, 19比较器排序网络, 两级流水
//   s1(拍2-3): 每行3值排序 -> 拍3寄存 row*_r
//   s2(拍3-4): 列合并 lo/mid/hi -> 拍4寄存 col*_r
//   s3(拍4-5): 中值=median(col_lo,col_mid,col_hi) (组合, mode_out直读, 与de0对齐)
//   边界(窗口不全): valid_win_r=0 时输出灰度原图, 避免0填充伪影
//==========================================================
// 行0 = r2_p*(上上行)  行1 = r1_p*(中间行=窗口中心行)  行2 = cur_p*(当前行)
wire [7:0] t0_ab_mn = (r2_p0 < r2_p1) ? r2_p0 : r2_p1;
wire [7:0] t0_ab_mx = (r2_p0 < r2_p1) ? r2_p1 : r2_p0;
wire [7:0] row0_lo  = (t0_ab_mn < r2_p2) ? t0_ab_mn : r2_p2;
wire [7:0] row0_hi  = (t0_ab_mx > r2_p2) ? t0_ab_mx : r2_p2;
wire [7:0] row0_up  = (t0_ab_mn > r2_p2) ? t0_ab_mn : r2_p2;
wire [7:0] row0_mid = (t0_ab_mx < row0_up) ? t0_ab_mx : row0_up;
wire [7:0] t1_ab_mn = (r1_p0 < r1_p1) ? r1_p0 : r1_p1;
wire [7:0] t1_ab_mx = (r1_p0 < r1_p1) ? r1_p1 : r1_p0;
wire [7:0] row1_lo  = (t1_ab_mn < r1_p2) ? t1_ab_mn : r1_p2;
wire [7:0] row1_hi  = (t1_ab_mx > r1_p2) ? t1_ab_mx : r1_p2;
wire [7:0] row1_up  = (t1_ab_mn > r1_p2) ? t1_ab_mn : r1_p2;
wire [7:0] row1_mid = (t1_ab_mx < row1_up) ? t1_ab_mx : row1_up;
wire [7:0] t2_ab_mn = (cur_p0 < cur_p1) ? cur_p0 : cur_p1;
wire [7:0] t2_ab_mx = (cur_p0 < cur_p1) ? cur_p1 : cur_p0;
wire [7:0] row2_lo  = (t2_ab_mn < cur_p2) ? t2_ab_mn : cur_p2;
wire [7:0] row2_hi  = (t2_ab_mx > cur_p2) ? t2_ab_mx : cur_p2;
wire [7:0] row2_up  = (t2_ab_mn > cur_p2) ? t2_ab_mn : cur_p2;
wire [7:0] row2_mid = (t2_ab_mx < row2_up) ? t2_ab_mx : row2_up;
reg [7:0] row0_lo_r, row0_mid_r, row0_hi_r;
reg [7:0] row1_lo_r, row1_mid_r, row1_hi_r;
reg [7:0] row2_lo_r, row2_mid_r, row2_hi_r;
always @(posedge clk) begin
    row0_lo_r <= row0_lo; row0_mid_r <= row0_mid; row0_hi_r <= row0_hi;
    row1_lo_r <= row1_lo; row1_mid_r <= row1_mid; row1_hi_r <= row1_hi;
    row2_lo_r <= row2_lo; row2_mid_r <= row2_mid; row2_hi_r <= row2_hi;
end
// 列合并: col_lo = max(3行lo), col_mid = median(3行mid), col_hi = min(3行hi)
wire [7:0] c_ab_mn = (row0_lo_r < row1_lo_r) ? row0_lo_r : row1_lo_r;
wire [7:0] col_lo  = (c_ab_mn < row2_lo_r) ? row2_lo_r : c_ab_mn;
wire [7:0] c1_up   = (row0_mid_r > row1_mid_r) ? row0_mid_r : row1_mid_r;
wire [7:0] c2_up   = (row1_mid_r > row2_mid_r) ? row1_mid_r : row2_mid_r;
wire [7:0] c3_up   = (row0_mid_r > row2_mid_r) ? row0_mid_r : row2_mid_r;
wire [7:0] c_ab_mx = (c1_up < c2_up) ? c1_up : c2_up;
wire [7:0] col_mid = (c_ab_mx < c3_up) ? c_ab_mx : c3_up;
wire [7:0] d_ab_mx = (row0_hi_r > row1_hi_r) ? row1_hi_r : row0_hi_r;
wire [7:0] col_hi  = (d_ab_mx > row2_hi_r) ? row2_hi_r : d_ab_mx;
reg [7:0] col_lo_r, col_mid_r, col_hi_r;
always @(posedge clk) begin
    col_lo_r <= col_lo; col_mid_r <= col_mid; col_hi_r <= col_hi;
end
// s3: 最终中值 = median(col_lo, col_mid, col_hi)
wire [7:0] m_ab_mx = (col_lo_r > col_mid_r) ? col_lo_r : col_mid_r;
wire [7:0] m_bc_mx = (col_mid_r > col_hi_r) ? col_mid_r : col_hi_r;
wire [7:0] m_ac_mx = (col_lo_r > col_hi_r) ? col_lo_r : col_hi_r;
wire [7:0] med_ab  = (m_ab_mx < m_bc_mx) ? m_ab_mx : m_bc_mx;
wire [7:0] med     = (med_ab < m_ac_mx) ? med_ab : m_ac_mx;
// 复古(sepia): R*1.06 / G*0.97 / B*0.75 (基于灰度)
wire [7:0] sep_r = (gray_o > 8'd235) ? 8'd255 : (gray_o + (gray_o >> 4));
wire [7:0] sep_g = gray_o - (gray_o >> 5);
wire [7:0] sep_b = gray_o - (gray_o >> 2);
// 紫调: R*1.25 / G*0.875 / B*1.25
wire [7:0] pur_r = (mr > 8'd204) ? 8'd255 : (mr + (mr >> 2));
wire [7:0] pur_g = mg - (mg >> 3);
wire [7:0] pur_b = (mb > 8'd204) ? 8'd255 : (mb + (mb >> 2));
// 绿调: R*0.75 / G*1.25 / B*0.875
wire [7:0] grn_r = mr - (mr >> 2);
wire [7:0] grn_g = (mg > 8'd204) ? 8'd255 : (mg + (mg >> 2));
wire [7:0] grn_b = mb - (mb >> 3);
reg [23:0] mode_out;
always @(*) begin
    case (mode_s2)
    4'd0:  mode_out = data_in_d3;                                        // 原图直通
    4'd1:  mode_out = {gray_o, gray_o, gray_o};                          // 灰度
    4'd2:  mode_out = edge_o ? 24'hFFFFFF : 24'h000000;                  // 边缘(白线黑底)
    4'd3:  mode_out = ~data_in_d3;                                       // 负片
    4'd4:  mode_out = gray_o[7] ? 24'hFFFFFF : 24'h000000;               // 黑白(阈值128)
    4'd5:  mode_out = {warm_r, warm_g, warm_b};                          // 红调
    4'd6:  mode_out = {cool_r, cool_g, cool_b};                          // 冷调
    4'd7:  mode_out = {emboss, emboss, emboss};                          // 浮雕
    4'd8:  mode_out = {{mr[7:5],5'd0}, {mg[7:5],5'd0}, {mb[7:5],5'd0}};  // 色阶(8级)
    4'd9:  mode_out = edge_o ? 24'h000000 : 24'hFFFFFF;                  // 线稿(白底黑线)
    4'd10: mode_out = {sharp_r, sharp_r, sharp_r};                             // 锐化
    4'd11: mode_out = {blur_r, blur_r, blur_r};                                // 模糊
    4'd12: mode_out = {sep_r, sep_g, sep_b};                             // 复古
    4'd13: mode_out = {pur_r, pur_g, pur_b};                             // 紫调
    5'd15: mode_out = valid_win_r ? {med, med, med} : {gray_o, gray_o, gray_o}; // 中值滤波(3x3灰度去噪)
    5'd16: mode_out = canny_hi_o ? 24'hFFFFFF : (canny_lo_o ? 24'h808080 : 24'h000000); // Canny近似(强白/弱灰/黑底)
    default: mode_out = {grn_r, grn_g, grn_b};                           // 绿调
    endcase
end
//50M域参数同步
reg [7:0]  img_num_s1, img_num_s2;
reg [1:0]  img_type_s1, img_type_s2;
reg [11:0] img_w_s1, img_w_s2;
reg [11:0] img_h_s1, img_h_s2;
reg        menu_show_s1, menu_show_s2;
reg [2:0]  menu_row_s1, menu_row_s2;
reg [2:0]  color_s1, color_s2;
reg        media_s1, media_s2;
reg [3:0]  ft_s1, ft_s2, fo_s1, fo_s2;
reg [3:0]  effect_s1, effect_s2;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        img_num_s1<=8'd0; img_num_s2<=8'd1;
        img_type_s1<=2'd1; img_type_s2<=2'd1;
        img_w_s1<=12'd1920; img_w_s2<=12'd1920;
        img_h_s1<=12'd1080; img_h_s2<=12'd1080;
        menu_show_s1<=1'b0; menu_show_s2<=1'b0;
        menu_row_s1<=3'd0; menu_row_s2<=3'd0;
        color_s1<=3'd0; color_s2<=3'd1;
        media_s1<=1'b0; media_s2<=1'b0;
        ft_s1<=4'd0; ft_s2<=4'd0; fo_s1<=4'd0; fo_s2<=4'd0;
        effect_s1<=4'd0; effect_s2<=4'd0;
    end
    else begin
        img_num_s1 <= img_num;    img_num_s2 <= img_num_s1;
        img_type_s1<= img_type;   img_type_s2<= img_type_s1;
        img_w_s1   <= img_w;      img_w_s2   <= img_w_s1;
        img_h_s1   <= img_h;      img_h_s2   <= img_h_s1;
        menu_show_s1<= menu_show; menu_show_s2<= menu_show_s1;
        menu_row_s1 <= menu_row;  menu_row_s2 <= menu_row_s1;
        color_s1    <= color_sel; color_s2    <= color_s1;
        media_s1    <= media_sel; media_s2    <= media_s1;
        ft_s1       <= vid_fps_t; ft_s2       <= ft_s1;
        fo_s1       <= vid_fps_o; fo_s2       <= fo_s1;
        effect_s1   <= effect_sel;effect_s2   <= effect_s1;
    end
end
//==========================================================
// S0a 拍: 像素坐标/区域初判 (组合, 与 de0 同拍) + 寄存
//==========================================================
wire [10:0] p_dx0  = osd_x - P_X;
wire [10:0] p_dy0  = osd_y - P_Y;
wire        in_p   = (osd_x >= P_X) && (osd_x < P_X + P_W) &&
                     (osd_y >= P_Y) && (osd_y < P_Y + P_CHAR_H);
wire        in_m   = menu_show_s2 && (osd_x >= MENU_X) && (osd_x < MENU_X + MENU_W) &&
                     (osd_y >= MENU_Y) && (osd_y < MENU_Y + MENU_ROW_H * MENU_NUM);
wire        in_c   = (osd_x >= CN_X) && (osd_x < CN_X + CN_TEXT_W) &&
                     (osd_y >= CN_Y) && (osd_y < CN_Y + CN_CHAR_H);
reg [10:0] osd_xa, osd_ya;
reg        in_pa, in_ma, in_ca;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        osd_xa <= 11'd0; osd_ya <= 11'd0;
        in_pa <= 1'b0; in_ma <= 1'b0; in_ca <= 1'b0;
    end
    else begin
        osd_xa <= osd_x; osd_ya <= osd_y;
        in_pa  <= in_p;  in_ma  <= in_m; in_ca <= in_c;
    end
end
//==========================================================
// S0b 拍: 文本层坐标计算 (用 S0a 寄存值, 组合深度减半)
//==========================================================
//----- 左上参数区 -----
wire [10:0] p_dx   = osd_xa - P_X;
wire [10:0] p_dy   = osd_ya - P_Y;
// [FIX-OSD-P] 参数层 2 倍字号后字符步进是 32px, 字符序号必须取 dx/32(bit[8:5]),
//   原来仍用 1 倍字号的 dx/16(bit[8:4]) -> 每个 32px 单元被拆成两个 16px 槽,
//   前半画第 2k 字第 0~3 列、后半画第 2k+1 字第 4~7 列, 文字被切成半字。
wire [4:0]  p_ci   = p_dx[8:5];      // 字符序号 = dx/32
wire [3:0]  p_fxp  = p_dx[4:2];      // 字模列 = (dx%32)/4 (0..7)
wire [3:0]  p_fy   = p_dy[5:2];      // 字模行 = (dy%64)/4
//----- 右上菜单区 -----
wire [10:0] m_dy   = osd_ya - MENU_Y;
wire [2:0]  m_row  = (m_dy >= 11'd144) ? 3'd4 : (m_dy >= 11'd108) ? 3'd3 :
                     (m_dy >= 11'd72)  ? 3'd2 : (m_dy >= 11'd36)  ? 3'd1 : 3'd0;
wire [10:0] m_dx   = osd_xa - MENU_X;
wire [3:0]  m_slot = m_dx[8:4];      // 16px槽号
wire [10:0] m_dy_r = m_dy - ({m_row, 5'd0}) - ({m_row, 2'd0}); // dy - row*36 (row*32+row*4)
wire [3:0]  m_fy   = m_dy_r >> 1;    // 行内 y/2 (0..15)
wire        m_in_txt = in_ma && (m_dy_r < 11'd32) && (m_slot < m_row_len(m_row, mode_s2, effect_s2));
wire        bar_on  = in_ma && (m_row == menu_row_s2) && (m_dy_r < 11'd32);
//----- 正下方中文字幕区 -----
wire [10:0] c_dx   = osd_xa - CN_X;
wire [10:0] c_dy   = osd_ya - CN_Y;
wire [3:0]  c_ci   = c_dx[8:5];      // 字符序号 = dx/32
wire [3:0]  c_fxp  = c_dx[4:1];      // 字模列 = (dx%32)/2 (0..15)
wire [3:0]  c_fy   = c_dy[4:1];      // 字模行 = dy/2
// 参数区数字拆位预计算 (w/h/num 为帧级慢速信号, 提前寄存避免每拍组合除法;
// 同步链输出先打一拍(s2d)再进入除法, 打断 img_*_s2->除法 的长路径)
reg [11:0] img_w_s2d, img_h_s2d;
reg [7:0]  img_num_s2d;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        img_w_s2d <= 12'd0; img_h_s2d <= 12'd0; img_num_s2d <= 8'd0;
    end
    else begin
        img_w_s2d  <= img_w_s2;
        img_h_s2d  <= img_h_s2;
        img_num_s2d<= img_num_s2;
    end
end
reg [3:0] pwk, pwh, pwt, pwo, phk, phh, pht, pho, pnt, pno;
// 第1级: 千位比较 + 取余 + 编号拆位
reg [11:0] w_r1000, h_r1000, w_r100, h_r100;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        pwk<=4'd0; phk<=4'd0; pnt<=4'd0; pno<=4'd0;
        w_r1000<=12'd0; h_r1000<=12'd0; w_r100<=12'd0; h_r100<=12'd0;
    end
    else begin
        pwk <= digit_k(img_w_s2d); phk <= digit_k(img_h_s2d);
        w_r1000 <= img_w_s2d % 12'd1000; h_r1000 <= img_h_s2d % 12'd1000;
        w_r100  <= img_w_s2d % 12'd100;  h_r100  <= img_h_s2d % 12'd100;
        pnt <= img_num_s2d / 4'd10; pno <= img_num_s2d % 4'd10;
    end
end
// 第2级: 百/十/个位 (除法拆半, 每级逻辑减半)
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        pwh<=4'd0; pwt<=4'd0; pwo<=4'd0; phh<=4'd0; pht<=4'd0; pho<=4'd0;
    end
    else begin
        pwh <= w_r1000 / 12'd100; phh <= h_r1000 / 12'd100;
        pwt <= w_r100  / 12'd10;  pht <= h_r100  / 12'd10;
        pwo <= w_r100  % 12'd10;  pho <= h_r100  % 12'd10;
    end
end
//==========================================================
// S0c 拍: 汇总本像素的文本特征 -> r1 (互斥区域, 直接三选一)
//==========================================================
wire        lyr_in    = in_pa | m_in_txt | in_ca;
wire        lyr_is_cn = m_in_txt | in_ca;            // 菜单/中文字幕为中文, 参数为ASCII
wire        lyr_cnsub = in_ca;                       // 仅正下方字幕用 color_sel 颜色
wire [7:0]  lyr_code  = in_pa ? p_char(p_ci, img_type_s2, media_s2, ft_s2, fo_s2, pwk, pwh, pwt, pwo,
                                       phk, phh, pht, pho, pnt, pno) :
                        m_in_txt ? m_char(m_row, m_slot, mode_s2, color_s2, effect_s2, media_s2) :
                        in_ca   ? cn_sub_char(c_ci) : 8'h20;
wire [3:0]  lyr_fxp   = in_pa ? p_fxp : (m_in_txt ? m_fxp(m_dx, m_slot) : c_fxp);
wire [3:0]  lyr_fy    = in_pa ? p_fy  : (m_in_txt ? m_fy : c_fy);
wire [2:0]  lyr_color = color_s2;   // 正下方字幕颜色
reg         r1_vld, r1_is_cn, r1_cnsub, r1_bar;
reg  [7:0]  r1_code;
reg  [3:0]  r1_fxp, r1_fy;
reg  [2:0]  r1_color;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        r1_vld <= 1'b0; r1_is_cn <= 1'b0; r1_cnsub <= 1'b0; r1_bar <= 1'b0;
        r1_code <= 8'h20; r1_fxp <= 4'd0; r1_fy <= 4'd0; r1_color <= 3'd1;
    end
    else begin
        r1_vld  <= lyr_in;
        r1_is_cn<= lyr_is_cn;
        r1_cnsub<= lyr_cnsub;
        r1_bar  <= bar_on;
        r1_code <= lyr_code;
        r1_fxp  <= lyr_fxp;
        r1_fy   <= lyr_fy;
        r1_color<= lyr_color;
    end
end
//==========================================================
// S1 拍: 字模查找 (两个ROM, 同拍读, 再打一拍)
//==========================================================
wire [15:0] cn_font_c;
wire [7:0]  ascii_font_c;
cn_font_rom u_cn_font(
    .code ( r1_code   ),
    .row  ( r1_fy     ),
    .data ( cn_font_c )
);
ascii_font_rom u_ascii_font(
    .ch   ( r1_code   ),
    .row  ( r1_fy     ),
    .data ( ascii_font_c )
);
reg [15:0] f_cn_r;
reg [7:0]  f_ascii_r;
reg        r2_vld, r2_is_cn, r2_cnsub, r2_bar;
reg [3:0]  r2_fxp;
reg [2:0]  r2_color;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        f_cn_r <= 16'd0; f_ascii_r <= 8'd0;
        r2_vld <= 1'b0; r2_is_cn <= 1'b0; r2_cnsub <= 1'b0; r2_bar <= 1'b0;
        r2_fxp <= 4'd0; r2_color <= 3'd1;
    end
    else begin
        f_cn_r    <= cn_font_c;
        f_ascii_r <= ascii_font_c;
        r2_vld    <= r1_vld;
        r2_is_cn  <= r1_is_cn;
        r2_cnsub  <= r1_cnsub;
        r2_bar    <= r1_bar;
        r2_fxp    <= r1_fxp;
        r2_color  <= r1_color;
    end
end
//==========================================================
// S2 拍: 像素判定 + 颜色选择 + 最终输出 (与图像第6级对齐)
//==========================================================
wire        f_px_on = r2_vld &&
                      (r2_is_cn ? ((f_cn_r    & (16'h8000 >> r2_fxp)) != 16'd0)
                                : ((f_ascii_r & (8'h80   >> r2_fxp[2:0])) != 8'd0));
wire [23:0] txt_color = (r2_color==3'd0) ? CN_COLOR0 :
                        (r2_color==3'd1) ? CN_COLOR1 :
                        (r2_color==3'd2) ? CN_COLOR2 :
                        (r2_color==3'd3) ? CN_COLOR3 : CN_COLOR4;
// 图像通路补3拍 (OSD 文本通路 S0a+S0b+S1=3级, 对齐 S2 合成)
reg [23:0] img_d1, img_d2, img_d3;
reg        de1, de2, de3;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        img_d1 <= 24'd0; img_d2 <= 24'd0; img_d3 <= 24'd0;
        de1 <= 1'b0; de2 <= 1'b0; de3 <= 1'b0;
    end
    else begin
        img_d1 <= mode_out;
        img_d2 <= img_d1;
        img_d3 <= img_d2;
        de1    <= de0;
        de2    <= de1;
        de3    <= de2;
    end
end
// 顶部滚动字幕(默认关闭): 保留 v2 功能
wire [23:0] top_marquee_out;
top_marquee #(.ENABLE(ENABLE_TOP_MARQUEE)) u_marquee(
    .clk(clk), .rst_n(rst_n),
    .de0(de2), .osd_x(osd_xa), .osd_y(osd_ya),
    .img_in(img_d3), .out(top_marquee_out)
);
// 选中行高亮: 25% 色块 + 75% 背景图 半透明混合 (每通道 (bar + img*3)>>2)
wire [7:0] bar_mix_r = (MENU_BAR[23:16] + {img_d3[23:16], 1'b0} + img_d3[23:16]) >> 2;
wire [7:0] bar_mix_g = (MENU_BAR[15:8]  + {img_d3[15:8],  1'b0} + img_d3[15:8])  >> 2;
wire [7:0] bar_mix_b = (MENU_BAR[7:0]   + {img_d3[7:0],   1'b0} + img_d3[7:0])   >> 2;
wire [23:0] bar_mix   = {bar_mix_r, bar_mix_g, bar_mix_b};
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        data_out <= 24'd0;
        de_out   <= 1'b0;
    end
    else begin
        de_out   <= de3;
        if(f_px_on)                       data_out <= (r2_cnsub) ? txt_color : MENU_TXT; // 文字置顶
        else if(r2_bar)                   data_out <= bar_mix;   // 选中行: 半透明高亮, 背景可见
        else                              data_out <= top_marquee_out;
    end
end
//==========================================================
// 菜单行长度: 标签2字(2槽)+空格(1槽)+取值(值字数*2槽)
//==========================================================
function [3:0] m_row_len;
    input [2:0] row;
    input [4:0] m_mode;
    input [3:0] m_eff;
    begin
        case (row)
        3'd0: m_row_len = 4'd9;   // 媒体
        3'd1: m_row_len = 4'd11;  // 图片
        3'd2: m_row_len = 4'd9;   // 模式
        3'd3: m_row_len = 4'd7;   // 颜色
        3'd4: case (m_eff)
              4'd0, 4'd2, 4'd5, 4'd6: m_row_len = 4'd13;  // 4 字
              4'd4, 4'd7:            m_row_len = 4'd11;  // 3 字
              default:               m_row_len = 4'd9;   // 2 字
              endcase
        default: m_row_len = 4'd0;
        endcase
    end
endfunction
//==========================================================
// 菜单字符槽 -> 字模列 (0..15): 中文占2槽, 从槽首计算
//==========================================================
//==========================================================
// 菜单字符槽 -> 字模列 (0..15)
//   [FIX-OSD-M] 汉字占 2 个 16px 槽: 标签从槽 0 开始(偶), 取值从槽 5 开始(奇)。
//   原写法 start=(slot&~1)*16 只对"从偶槽开始"的标签成立; 取值从奇槽 5 开始时,
//   槽5 取到 fxp=8..15(右半)、槽6 取到 0..7(左半) -> 每个取值汉字左右两半互换。
//   修正: 先算该字所在的起始槽(标签 0/2, 取值 5/7/9...), 再乘 16。
//==========================================================
function [3:0] m_fxp;
    input [10:0] dx;
    input [3:0]  slot;
    reg   [10:0] start;
    reg   [3:0]  cs;
    begin
        if (slot >= 4'd5) cs = slot - {3'b0, ((slot - 4'd5) & 4'd1)};  // 5,6->5 ; 7,8->7 ; 9,10->9
        else              cs = slot - {3'b0, (slot & 4'd1)};           // 0,1->0 ; 2,3->2
        start = {cs, 4'b0};                                           // cs*16
        m_fxp = (dx - start) >> 1;
    end
endfunction
//==========================================================
// 左上参数区字符表: "BMP 1920x1080 #03" 17字符 (ASCII)
//==========================================================
function [7:0] p_char;
    input [4:0]  pos;
    input [1:0]  typ;
    input        med;        // 1 = 视频
    input [3:0]  ft, fo;     // 实测 fps 十位/个位
    input [3:0]  w_k, w_h, w_t, w_o;
    input [3:0]  h_k, h_h, h_t, h_o;
    input [3:0]  n_t, n_o;
    begin
        if(med) begin
            // 'DV1 320x240 15FPS' (17 字符, 与图片行等长)
            case (pos)
            5'd0:  p_char = 8'h44;   // 'D'
            5'd1:  p_char = 8'h56;   // 'V'
            5'd2:  p_char = 8'h31;   // '1'
            5'd3:  p_char = 8'h20;
            5'd4:  p_char = 8'h33;   // '3'
            5'd5:  p_char = 8'h32;   // '2'
            5'd6:  p_char = 8'h30;   // '0'
            5'd7:  p_char = 8'h78;   // 'x'
            5'd8:  p_char = 8'h32;   // '2'
            5'd9:  p_char = 8'h34;   // '4'
            5'd10: p_char = 8'h30;   // '0'
            5'd11: p_char = 8'h20;
            5'd12: p_char = 8'h30 + ft;  // fps 十位
            5'd13: p_char = 8'h30 + fo;  // fps 个位
            5'd14: p_char = 8'h46;   // 'F'
            5'd15: p_char = 8'h50;   // 'P'
            5'd16: p_char = 8'h53;   // 'S'
            default: p_char = 8'h20;
            endcase
        end
        else begin
            case (pos)
            5'd0:  p_char = (typ==2'd2) ? 8'h4A : 8'h42;  // 'J' / 'B'
            5'd1:  p_char = (typ==2'd2) ? 8'h50 : 8'h4D;  // 'P' / 'M'
            5'd2:  p_char = (typ==2'd2) ? 8'h47 : 8'h50;  // 'G' / 'P'
            5'd3:  p_char = 8'h20;
            5'd4:  p_char = 8'h30 + w_k;
            5'd5:  p_char = 8'h30 + w_h;
            5'd6:  p_char = 8'h30 + w_t;
            5'd7:  p_char = 8'h30 + w_o;
            5'd8:  p_char = 8'h78;   // 'x'
            5'd9:  p_char = 8'h30 + h_k;
            5'd10: p_char = 8'h30 + h_h;
            5'd11: p_char = 8'h30 + h_t;
            5'd12: p_char = 8'h30 + h_o;
            5'd13: p_char = 8'h20;
            5'd14: p_char = 8'h23;   // '#'
            5'd15: p_char = 8'h30 + n_t;
            5'd16: p_char = 8'h30 + n_o;
            default: p_char = 8'h20;
            endcase
        end
    end
endfunction
//12bit十进制拆位 (w/h <= 4095)
function [3:0] digit_k; input [11:0] v; begin
    digit_k = (v >= 12'd1000) ? ((v >= 12'd2000) ? ((v >= 12'd3000) ? ((v >= 12'd4000) ? 4'd4 : 4'd3) : 4'd2) : 4'd1) : 4'd0;
end endfunction
function [3:0] digit_h; input [11:0] v; begin
    digit_h = ((v % 12'd1000) / 12'd100);
end endfunction
function [3:0] digit_t; input [11:0] v; begin
    digit_t = ((v % 12'd100) / 12'd10);
end endfunction
function [3:0] digit_o; input [11:0] v; begin
    digit_o = (v % 12'd10);
end endfunction
//==========================================================
// 菜单字符表: 返回 (槽号 -> 内码); 槽0/1/2/3=标签, 4=空格, 5起=取值
//==========================================================
function [7:0] m_char;
    input [2:0] row;
    input [3:0] slot;
    input [4:0] m_mode;
    input [2:0] m_color;
    input [3:0] m_eff;
    input       m_media;
    reg  [3:0] vi;
    begin
        vi = (slot - 4'd5) >> 1;   // 取值字序号 (槽5起每字2槽)
        case (row)
        3'd0: begin // 媒体: 媒 体 空格 图/片 或 视/频
            case (slot)
            4'd0, 4'd1: m_char = 8'hBD;   // 媒
            4'd2, 4'd3: m_char = 8'hC0;   // 体
            4'd4:       m_char = 8'h20;   // ' '
            4'd5, 4'd6: m_char = m_media ? 8'hBE : 8'h80;   // 视/图
            4'd7, 4'd8: m_char = m_media ? 8'hBF : 8'h81;   // 频/片
            default:    m_char = 8'h20;
            endcase
        end
        3'd1: begin // 图片: 图 片 空格 下 一 张
            case (slot)
            4'd0, 4'd1: m_char = m_media ? 8'hBE : 8'h80;   // 视 / 图
            4'd2, 4'd3: m_char = m_media ? 8'hBF : 8'h81;   // 频 / 片
            4'd4:       m_char = 8'h20;   // ' '
            4'd5, 4'd6: m_char = 8'h9F;   // 下
            4'd7, 4'd8: m_char = 8'hA0;   // 一
            4'd9, 4'd10:m_char = 8'hA1;   // 张
            default:    m_char = 8'h20;
            endcase
        end
        3'd2: begin // 模式: 模 式 空格 + 取值
            case (slot)
            4'd0, 4'd1: m_char = 8'h82;   // 模
            4'd2, 4'd3: m_char = 8'h83;   // 式
            4'd4:       m_char = 8'h20;   // ' '
            default:    m_char = m_mode_val(m_mode, vi);
            endcase
        end
        3'd3: begin // 颜色: 颜 色 空格 + 黑/白/红/蓝/绿
            case (slot)
            4'd0, 4'd1: m_char = 8'h84;   // 颜
            4'd2, 4'd3: m_char = 8'h85;   // 色
            4'd4:       m_char = 8'h20;   // ' '
            4'd5, 4'd6: m_char = m_color_val(m_color);
            default:    m_char = 8'h20;
            endcase
        end
        3'd4: begin // 效果: 效 果 空格 + 取值
            case (slot)
            4'd0, 4'd1: m_char = 8'h86;   // 效
            4'd2, 4'd3: m_char = 8'h87;   // 果
            4'd4:       m_char = 8'h20;   // ' '
            default:    m_char = m_effect_val(m_eff, vi);
            endcase
        end
        default: m_char = 8'h20;
        endcase
    end
endfunction
//模式取值(17种): 原图/灰度/边缘/负片/黑白/红调/冷调/浮雕/色阶/线稿/锐化/模糊/复古/紫调/绿调/中值/坎尼
function [7:0] m_mode_val;
    input [4:0] m_mode;
    input [3:0] vi;
    begin
        case (m_mode)
        4'd0:  m_mode_val = (vi==4'd0) ? 8'h88 : 8'h80;   // 原 图
        4'd1:  m_mode_val = (vi==4'd0) ? 8'h89 : 8'h8A;   // 灰 度
        4'd2:  m_mode_val = (vi==4'd0) ? 8'h8B : 8'h8C;   // 边 缘
        4'd3:  m_mode_val = (vi==4'd0) ? 8'hB0 : 8'h81;   // 负 片
        4'd4:  m_mode_val = (vi==4'd0) ? 8'h90 : 8'h91;   // 黑 白
        4'd5:  m_mode_val = (vi==4'd0) ? 8'h92 : 8'hB1;   // 红 调
        4'd6:  m_mode_val = (vi==4'd0) ? 8'hB2 : 8'hB1;   // 冷 调
        4'd7:  m_mode_val = (vi==4'd0) ? 8'hB3 : 8'hB4;   // 浮 雕
        4'd8:  m_mode_val = (vi==4'd0) ? 8'h85 : 8'hB5;   // 色 阶
        4'd9:  m_mode_val = (vi==4'd0) ? 8'h9B : 8'hB6;   // 线 稿
        4'd10: m_mode_val = (vi==4'd0) ? 8'hB7 : 8'hB8;   // 锐 化
        4'd11: m_mode_val = (vi==4'd0) ? 8'h82 : 8'hB9;   // 模 糊
        4'd12: m_mode_val = (vi==4'd0) ? 8'hBA : 8'hBB;   // 复 古
        4'd13: m_mode_val = (vi==4'd0) ? 8'hBC : 8'hB1;   // 紫 调
        5'd15: m_mode_val = (vi==4'd0) ? 8'hC4 : 8'hCE;   // 中 值
        5'd16: m_mode_val = (vi==4'd0) ? 8'hCF : 8'hD0;   // 坎 尼
        default: m_mode_val = (vi==4'd0) ? 8'h94 : 8'hB1; // 绿 调
        endcase
    end
endfunction
//颜色取值: 黑/白/红/蓝/绿
function [7:0] m_color_val;
    input [2:0] m_color;
    begin
        case (m_color)
        3'd0: m_color_val = 8'h90;   // 黑
        3'd1: m_color_val = 8'h91;   // 白
        3'd2: m_color_val = 8'h92;   // 红
        3'd3: m_color_val = 8'h93;   // 蓝
        default: m_color_val = 8'h94; // 绿
        endcase
    end
endfunction
//效果取值: 淡入淡出/切入/随机线条/溶解
function [7:0] m_effect_val;
    input [3:0] e;
    input [3:0] vi;
    begin
        case (e)
        4'd0: begin            // 淡入淡出
            case (vi)
            4'd0: m_effect_val = 8'h95;   // 淡
            4'd1: m_effect_val = 8'h96;   // 入
            4'd2: m_effect_val = 8'h95;   // 淡
            4'd3: m_effect_val = 8'h97;   // 出
            default: m_effect_val = 8'h20;
            endcase
        end
        4'd1: begin            // 切入
            m_effect_val = (vi==4'd0) ? 8'h98 : 8'h96;   // 切 入
        end
        4'd2: begin            // 随机线条
            case (vi)
            4'd0: m_effect_val = 8'h99;   // 随
            4'd1: m_effect_val = 8'h9A;   // 机
            4'd2: m_effect_val = 8'h9B;   // 线
            4'd3: m_effect_val = 8'h9C;   // 条
            default: m_effect_val = 8'h20;
            endcase
        end
        4'd3: begin            // 溶解
            m_effect_val = (vi==4'd0) ? 8'h9D : 8'h9E;   // 溶 解
        end
        4'd4: begin            // 百叶窗
            case (vi)
            4'd0: m_effect_val = 8'hC1;   // 百
            4'd1: m_effect_val = 8'hC2;   // 叶
            4'd2: m_effect_val = 8'hC3;   // 窗
            default: m_effect_val = 8'h20;
            endcase
        end
        4'd5: begin            // 中心扩散
            case (vi)
            4'd0: m_effect_val = 8'hC4;   // 中
            4'd1: m_effect_val = 8'hC5;   // 心
            4'd2: m_effect_val = 8'hC6;   // 扩
            4'd3: m_effect_val = 8'hC7;   // 散
            default: m_effect_val = 8'h20;
            endcase
        end
        4'd6: begin            // 上下合拢
            case (vi)
            4'd0: m_effect_val = 8'hC8;   // 上
            4'd1: m_effect_val = 8'h9F;   // 下
            4'd2: m_effect_val = 8'hC9;   // 合
            4'd3: m_effect_val = 8'hCA;   // 拢
            default: m_effect_val = 8'h20;
            endcase
        end
        default: begin         // 7 棋盘格
            case (vi)
            4'd0: m_effect_val = 8'hCB;   // 棋
            4'd1: m_effect_val = 8'hCC;   // 盘
            4'd2: m_effect_val = 8'hCD;   // 格
            default: m_effect_val = 8'h20;
            endcase
        end
        endcase
    end
endfunction
//==========================================================
// 正下方中文字幕字符表: 智能图片播放器 + Logo (改这里)
//==========================================================
function [7:0] cn_sub_char;
    input [3:0] idx;
    begin
        case (idx)
        4'd0: cn_sub_char = 8'hA2;   // 智
        4'd1: cn_sub_char = 8'hA3;   // 能
        4'd2: cn_sub_char = 8'h80;   // 图
        4'd3: cn_sub_char = 8'h81;   // 片
        4'd4: cn_sub_char = 8'hA4;   // 播
        4'd5: cn_sub_char = 8'hA5;   // 放
        4'd6: cn_sub_char = 8'hA6;   // 器
        4'd7: cn_sub_char = 8'hAE;   // Logo
        default: cn_sub_char = 8'h20;
        endcase
    end
endfunction
endmodule

// --------------------------------------------------------------------
// top_marquee: v2 顶部跑马灯字幕 (独立模块, 默认关闭)
// --------------------------------------------------------------------
module top_marquee #(
    parameter ENABLE = 1'b0
)(
    input             clk      ,
    input             rst_n    ,
    input             de0      ,
    input      [10:0] osd_x    ,
    input      [10:0] osd_y    ,
    input      [23:0] img_in   ,
    output reg [23:0] out
);
// ===== 字幕文本内容设置区 (改这里) =====
function [7:0] sub_text_char;
    input [5:0] idx;
    begin
        case (idx)
            6'd00: sub_text_char = 8'h46; // 'F'
            6'd01: sub_text_char = 8'h50; // 'P'
            6'd02: sub_text_char = 8'h47; // 'G'
            6'd03: sub_text_char = 8'h41; // 'A'
            6'd04: sub_text_char = 8'h2D; // '-'
            6'd05: sub_text_char = 8'h49; // 'I'
            6'd06: sub_text_char = 8'h4D; // 'M'
            6'd07: sub_text_char = 8'h47; // 'G'
            6'd08: sub_text_char = 8'h2D; // '-'
            6'd09: sub_text_char = 8'h50; // 'P'
            6'd10: sub_text_char = 8'h4C; // 'L'
            6'd11: sub_text_char = 8'h41; // 'A'
            6'd12: sub_text_char = 8'h59; // 'Y'
            6'd13: sub_text_char = 8'h45; // 'E'
            6'd14: sub_text_char = 8'h52; // 'R'
            6'd15: sub_text_char = 8'h20; // ' '
            6'd16: sub_text_char = 8'h32; // '2'
            6'd17: sub_text_char = 8'h30; // '0'
            6'd18: sub_text_char = 8'h32; // '2'
            6'd19: sub_text_char = 8'h36; // '6'
            6'd20: sub_text_char = 8'h20; // ' '
            6'd21: sub_text_char = 8'h80; // '♥'
            default: sub_text_char = 8'h20;
        endcase
    end
endfunction
localparam SUB_CH_NUM = 22;
// ===== 字幕文本内容设置区结束 =====
localparam SUB_CHAR_W  = 11'd16;
localparam SUB_CHAR_H  = 11'd32;
localparam SUB_Y       = 11'd16;
localparam signed [12:0] SUB_SPEED = 13'd2;
localparam [23:0] SUB_COLOR = 24'hFFFFFF;
localparam signed [12:0] SUB_TEXT_W = SUB_CH_NUM * SUB_CHAR_W;

reg signed [12:0] sub_pos;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        sub_pos <= -SUB_TEXT_W;
    else if(de0 && osd_x == 11'd1919 && osd_y == 11'd1079) begin
        if(sub_pos >= 13'sd1920) sub_pos <= -SUB_TEXT_W;
        else                     sub_pos <= sub_pos + SUB_SPEED;
    end
end
wire signed [12:0] sub_dx = $signed({2'b00, osd_x}) - sub_pos;
wire [5:0]  sub_ci = sub_dx[12:4];
wire [3:0]  sub_fx = sub_dx[3:1];
wire [3:0]  sub_fy = (osd_y - SUB_Y) >> 1;
wire        sub_in = (osd_y >= SUB_Y) && (osd_y < SUB_Y + SUB_CHAR_H) &&
                     (sub_dx >= 0) && (sub_dx < SUB_TEXT_W) && (sub_ci < SUB_CH_NUM);
reg [5:0] sub_ci_r;
reg [3:0] sub_fy_r;
reg [3:0] sub_fx_r;
reg       sub_in_r;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin sub_ci_r <= 6'd0; sub_fy_r <= 4'd0; sub_fx_r <= 4'd0; sub_in_r <= 1'b0; end
    else begin
        sub_ci_r <= sub_ci;
        sub_fy_r <= sub_fy;
        sub_fx_r <= sub_fx;
        sub_in_r <= sub_in;
    end
end
wire [7:0] sub_ch_r = sub_text_char(sub_ci_r);
wire [7:0] sub_font_comb;
ascii_font_rom u_ascii_font(
    .ch   (sub_ch_r      ),
    .row  (sub_fy_r      ),
    .data (sub_font_comb )
);
reg [7:0] sub_font_r;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) sub_font_r <= 8'd0;
    else       sub_font_r <= sub_font_comb;
end
wire sub_px = sub_in_r && (sub_fx_r < 4'd8) &&
              ((sub_font_r & (8'h80 >> sub_fx_r)) != 8'd0);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) out <= 24'd0;
    else if(!ENABLE) out <= img_in;
    else             out <= sub_px ? SUB_COLOR : img_in;
end
endmodule
