`timescale 1ns/1ps
// --------------------------------------------------------------------
// Copyright (c) 2022 by MicroPhase Technologies Inc. 
// --------------------------------------------------------------------
// ddr3_tx_buffer.v  v2 重写: 任意分辨率自适应缩放显示 (行缓冲方案)
// --------------------------------------------------------------------
// 架构(替代v1的 FIFO+固定1920读):
//   ui域(读侧取行): 按 band_line+1 预取源行 -> 双口BRAM行缓冲(2048x128, 4槽轮转)
//     行号映射: band行L -> 源行 sy=floor(L*H/disp_h) -> DDR3存储行 H-1-sy
//     (修正BMP底部行优先存储; 与rx侧写入方向一致)
//   hdmi域(显示侧): img_scaler 读取行缓冲, 水平最近邻缩放+黑边+行旋转
//   几何(disp_w/disp_h/x_off/step_fix)由 img_scaler 在换帧时刻锁存计算
// 说明:
//   - 行缓冲 = 4 槽 x 512 x 128bit(槽=bit[10:9]), 支持源宽最大4096(行按8像素对齐存储)
//   - 取行速度远高于显示消耗(60帧/s), 每band行提前取好, 显示无等待
//   - hdmi_rst_n 在首行数据写入完成后释放
// --------------------------------------------------------------------
`include "../hdmi/vga_parameter_cfg.v"
module ddr3_tx_buffer  #(
         parameter  DDR3_ADDR_MAX = 512*512-8,
         parameter  WR_MAX        = 896  
     )(
    input             ui_clk              ,
    input             ui_rst              ,
    input             ddr3_busy           ,
    input             buf_sel             ,//双缓冲选择：0=BufferA 1=BufferB（显示缓冲，读侧）
    //原始图像宽高(50M域, 来自rd_bmp; 仅在换帧时刻被img_scaler用于计算新几何)
    input      [11:0] img_w               ,
    input      [11:0] img_h               ,
    //滑动效果: 行旋转偏移(源像素, 148.5M域, 来自img_trans)
    input      [11:0] rd_off              ,
    //*********ddr3读控制信号**************/
    output            ddr3_rd_start            ,  //signals about control
    input             ddr3_rd_addr_req         ,  //读地址请求信号
    output      [28:0]ddr3_rd_addr             ,  
    input             ddr3_rd_data_vld         ,
    input  [127:0]    ddr3_rd_data             ,
    input             ddr3_rd_done             ,
    //************给hdmi显示的模块***********/
    input             hdmi_clk            ,
    input             hdmi_data_req       ,//hdmi请求数据(vga_de)
    output [23:0]     hdmi_data           ,//缩放后像素(与hdmi_data_req_out对齐)
    output            hdmi_data_req_out   ,//延迟2拍的de(供img_trans等)
    output  reg       hdmi_rst_n          ,
    //几何输出(148.5M域, 供img_trans滑动遮罩)
    output [10:0]     x_off               ,
    output [10:0]     disp_w              ,
    output [27:0]     step_fix            ,
    //换帧时刻(来自img_trans: 检测到双缓冲切换) -> 锁存并计算几何
    input             geom_update,
    //本次突发读字数 = 行字数 (一次突发只读1行, 避免跨行覆盖显示行缓冲)
    output [9:0]      ddr3_rd_len
    );
localparam IDLE        = 3'b001 ; //复位的时候处于空状态
localparam ARBIT       = 3'b010 ; //判断是否从ddr3中读出数据
localparam READ        = 3'b100 ; //从ddr3中读出数据
reg            [2:0]    state  ;
//缩放器/几何相关wire (由img_scaler驱动; x_off/disp_w/step_fix直接接输出端口)
wire [11:0] rowbuf_raddr ;
wire [10:0] disp_h       ;
wire [10:0] band_line    ;
wire [11:0] img_w_lat_o  ;
wire [11:0] src_h_o      ;
//==================================================================
// ui_clk 域: 同步 (img_w/img_h来自50M域; band_line/disp_h来自148.5M域)
//==================================================================
// 同步源 = img_scaler 的锁存几何(显示中图片的实际宽高/显示高, 换帧时更新)
// 注意: 不能直接用rd_bmp的img_w/img_h —— 新图加载时其宽高已变, 但旧图仍在显示
reg [11:0] w_u1, w_u2;
reg [11:0] h_u1, h_u2;
reg [10:0] bl_s1, bl_s2;
reg [10:0] dh_s1, dh_s2;
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst) begin
        w_u1 <= 12'd1920; w_u2 <= 12'd1920;
        h_u1 <= 12'd1080; h_u2 <= 12'd1080;
        bl_s1 <= 11'd0;   bl_s2 <= 11'd0;
        dh_s1 <= 11'd1080; dh_s2 <= 11'd1080;
    end
    else begin
        w_u1 <= img_w_lat_o; w_u2 <= w_u1;
        h_u1 <= src_h_o;     h_u2 <= h_u1;
        bl_s1 <= band_line;  bl_s2 <= bl_s1;
        dh_s1 <= disp_h;     dh_s2 <= dh_s1;
    end
end
// [FIX-GEO] 几何变化检测: 新图宽高锁存后, 取行/行缓冲必须从行0重新开始,
//   否则会沿用上一张图的 row_words/data_row 相位 -> 行错位、画面撕裂。
reg  [11:0] w_u2_d, h_u2_d;
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst) begin w_u2_d <= 12'd0; h_u2_d <= 12'd0; end
    else       begin w_u2_d <= w_u2;  h_u2_d <= h_u2;  end
end
wire geo_chg = (w_u2 != w_u2_d) || (h_u2 != h_u2_d);

wire [11:0] w8_ui    = (w_u2 + 12'd7) & 12'hFF8; // 行宽按8像素对齐
wire [9:0]  row_words_raw = {1'b0, w8_ui[11:3]};
wire [9:0]  row_words = (row_words_raw == 10'd0) ? 10'd240 : row_words_raw;  // [FIX-LEN]
assign ddr3_rd_len = row_words;                  // 一次突发只读1行
//取行目标: band行+1 (帧末不回绕, 由wrap_pending门控等待帧边界再取下一帧首行)
wire [10:0] fetch_target = (bl_s2 == dh_s2 - 1'b1) ? (dh_s2 - 1'b1) : bl_s2 + 1'b1;
//帧边界检测(ui域): band_line回绕 (bl_s1为较新一拍的同步值)
wire frame_wrap_ui = (bl_s1 < bl_s2);
// [FIX-GEO-START 回退] 首帧启动不使用 geom_update 门控:
//   原门控等待 img_trans 的 geom_update, 但 img_trans 的 rst_n = hdmi_rst_n,
//   hdmi_rst_n 又由取行器首行写完(first_done)产生 -> 循环依赖 -> 上板永久黑屏。
//   恢复原始"复位后立即取行": 首帧按复位默认几何(1920x1080)取垃圾行并先释放 hdmi_rst_n;
//   随后 img_trans 出复位、首帧写完翻转 buf_sel -> geom_update -> 缩放器锁存真实几何 ->
//   w_u2/h_u2 变化 -> geo_chg -> 取行器复位从行0重取 -> 行缓冲被正确数据覆盖, 画面自愈。
//   (仿真验证: 首帧垃圾为瞬态, 最终画面正确)
//==================================================================
// 读侧取行 (Bresenham 行映射 sy = floor(L*H/disp_h))
//==================================================================
reg  [10:0] fetch_line;   // 下一个要取的行 0..disp_h-1
reg  [15:0] f_acc;        // Bresenham累加器(余数)
reg  [10:0] sy_fetch;     // fetch_line 对应的源行 0..H-1
reg  [11:0] h_addr;       // 行内列地址 0..w8-8 步进8
reg  [10:0] row_vaddr;    // 当前取行的DDR3行地址 = H-1-sy_fetch
reg  [9:0]  cmd_waddr;    // 行内命令(字)计数 0..row_words-1
//Bresenham 推进(行末命令时使用, 组合计算下一行)
wire [15:0] f_acc_n  = f_acc + h_u2;
wire        sy_up    = (f_acc_n >= dh_s2);
wire [15:0] f_acc_nw = sy_up ? (f_acc_n - dh_s2) : f_acc_n;
wire [10:0] sy_new   = (fetch_line == dh_s2 - 1'b1) ? 11'd0
                     : (sy_up ? sy_fetch + 1'b1 : sy_fetch);
wire [10:0] fetch_new = (fetch_line == dh_s2 - 1'b1) ? 11'd0 : fetch_line + 1'b1;
//换帧(缓冲切换)重同步: 切图时旧缓冲的在途数据先排空, 再从新图行0重新取
reg  buf_sel_d1;
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst) buf_sel_d1 <= 1'b0;
    else       buf_sel_d1 <= buf_sel;
end
wire buf_sel_chg = buf_sel_d1 ^ buf_sel;   // ui域换帧沿
reg        swap_drain;    // 1: 排空在途旧数据(暂停发新命令)
reg [7:0]  drain_cnt;
wire       swap_reset = swap_drain && (drain_cnt == 8'd128); // 排空完成, 复位取行/写侧

// [FIX-VSYNC] 换帧/换几何只在"显示帧边界"生效:
//   buf_sel 直接改会让同一帧上半屏读A、下半屏读B -> 一屏两张图
reg        buf_sel_l;      // 本帧实际使用的缓冲
reg        swap_pend;      // 有待切换的换帧
reg        geo_pend;       // 有待切换的几何
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst) begin
        buf_sel_l <= 1'b1;  // 与 rd_img 复位值(disp_buf_sel=1) 一致
        swap_pend <= 1'b0;
        geo_pend  <= 1'b0;
    end
    else begin
        if(buf_sel_chg) swap_pend <= 1'b1;
        if(geo_chg)     geo_pend  <= 1'b1;
        if(frame_wrap_ui) begin
            buf_sel_l <= buf_sel;      // 帧边界: 原子切换缓冲
            swap_pend <= 1'b0;
            geo_pend  <= 1'b0;
        end
    end
end
wire resync = frame_wrap_ui && (swap_pend || geo_pend);   // 帧边界重同步
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst) begin
        swap_drain <= 1'b0; drain_cnt <= 8'd0;
    end
    else if(buf_sel_chg) begin
        swap_drain <= 1'b1; drain_cnt <= 8'd0;
    end
    else if(swap_drain) begin
        if(drain_cnt == 8'd128) swap_drain <= 1'b0;
        else                    drain_cnt <= drain_cnt + 1'b1;
    end
end
//取行暂停标记: 末行取完后暂停, 等下一帧开始再取(避免覆盖显示中的缓冲)
reg  wrap_pending;
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst)
        wrap_pending <= 1'b0;
    else if(ddr3_rd_addr_req && h_addr == w8_ui - 12'd8 && fetch_line == dh_s2 - 1'b1)
        wrap_pending <= 1'b1;   // 末行取完
    else if(frame_wrap_ui)
        wrap_pending <= 1'b0;   // 帧边界: 可以取下一帧首行了
    else if(resync)
        wrap_pending <= 1'b0;   // 帧边界重同步
end
// [FIX-WDOG] 突发超时看门狗: READ 超过 4095 拍未 done 则强制退出
reg [11:0] rd_to;
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst)                rd_to <= 12'd0;
    else if(state != READ)    rd_to <= 12'd0;
    else if(rd_to != 12'hFFF) rd_to <= rd_to + 1'b1;
end
wire rd_timeout = (state == READ) && (rd_to == 12'hFFF);

//需要取行: 换帧排空期间暂停; 否则已取行数落后目标(含启动时预取前两行)
wire need_read = !wrap_pending && (fetch_line <= fetch_target);
//状态机(每突发64字, 一次ddr3_rd_done后回到ARBIT)
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst)
       state<=IDLE;
    else
     case (state)
       IDLE  :begin
             state <= ARBIT; 
       end
       ARBIT :
          begin
               if(ddr3_rd_start)
                   state<= READ;
               else 
                    state<= ARBIT;
           end
       READ:
           begin
                if(ddr3_rd_done || rd_timeout)   // [FIX-WDOG]
                    state<= ARBIT;
                else 
                    state<= READ;
           end
        default:state<=ARBIT; 
    endcase
end
//ddr3_rd_start: 需要取行时持续发起突发
assign ddr3_rd_start=(state==ARBIT)&&(ddr3_busy==1'b0)&&need_read;
//取行寻址: 每命令(字)步进8; 行末命令推进fetch_line/sy_fetch并换行
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst) begin
        h_addr <= 12'd0; cmd_waddr <= 10'd0;
        fetch_line <= 11'd0; f_acc <= 16'd0; sy_fetch <= 11'd0;
        row_vaddr <= 11'd1079;   // 默认1080-1-0
    end
    else if(resync) begin                   // [FIX-VSYNC] 帧边界重同步
        h_addr <= 12'd0; cmd_waddr <= 10'd0;
        fetch_line <= 11'd0; f_acc <= 16'd0; sy_fetch <= 11'd0;
        row_vaddr <= h_u2 - 1'b1;
    end
    else if(ddr3_rd_addr_req) begin
        if(h_addr == w8_ui - 12'd8) begin       // 行末(最后一个字)
            h_addr <= 12'd0;
            cmd_waddr <= 10'd0;
            fetch_line <= fetch_new;
            sy_fetch   <= sy_new;
            f_acc      <= (fetch_line == dh_s2 - 1'b1) ? 16'd0 : f_acc_nw;
            row_vaddr  <= h_u2 - 1'b1 - {1'b0, sy_new};  // 下一行存储行 = H-1-sy
        end
        else begin
            h_addr <= h_addr + 12'd8;
            cmd_waddr <= cmd_waddr + 1'b1;
        end
    end
end
assign ddr3_rd_addr={5'd0,buf_sel_l,row_vaddr[10:0],h_addr[11:0]};  // [FIX-VSYNC] 用帧内锁存值
//==================================================================
// 行缓冲写入 (ui域): 128bit/字, 双缓冲 = data_row奇偶
//==================================================================
(* ram_style="block" *) reg [127:0] rowbuf [0:2047];   // 4 槽(每槽 512 字), 共 4*512=2048
reg [9:0]  waddr;      // 行内字地址 (0..row_words-1 <= 511)
reg [10:0] data_row;   // 数据侧行号(选缓冲, 0..disp_h-1)
// [FIX-SLOT] 槽位必须放 bit[10:9]、字地址放 bit[8:0] (槽跨距=512, 4槽正好 0..2047)。
//   原写法 {data_row[1:0], waddr} 把槽放 bit[11:10](跨距1024), 槽2/3地址 2048..4095
//   超出 rowbuf[0:2047] -> 综合后地址高位被丢弃, 槽2/3 与 槽0/1 混叠,
//   预取行会覆盖正在显示的行 -> 2行重复 + 动态撕裂花屏。必须与 img_scaler 读侧一致。
// 存储器写入块: 无复位(否则BRAM无法推断) —— 复位只作用于waddr/data_row
always @(posedge ui_clk) begin
    if(ddr3_rd_data_vld)
        rowbuf[{1'b0, data_row[1:0], waddr[8:0]}] <= ddr3_rd_data;
end
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst) begin
        waddr <= 10'd0; data_row <= 11'd0;
    end
    else if(resync) begin               // [FIX-VSYNC] 帧边界重同步
        waddr <= 10'd0; data_row <= 11'd0;
    end
    else if(ddr3_rd_data_vld) begin
        if(waddr == row_words - 1'b1) begin
            waddr <= 10'd0;
            if(data_row == dh_s2 - 1'b1) data_row <= 11'd0;
            else                         data_row <= data_row + 1'b1;
        end
        else
            waddr <= waddr + 1'b1;
    end
end
//首行数据写完后释放hdmi复位(同步到148.5M域)
reg  first_done;
reg  rst_s1, rst_s2;
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst) first_done <= 1'b0;
    else if(ddr3_rd_data_vld && waddr == row_words - 1'b1 && data_row == 11'd0)
        first_done <= 1'b1;
end
always @(posedge hdmi_clk) begin
    rst_s1 <= first_done;
    rst_s2 <= rst_s1;
end
always @(posedge hdmi_clk)
    hdmi_rst_n <= rst_s2;   // 首行数据写完后释放(0->1)
//==================================================================
// hdmi域: img_w/img_h同步 + 行缓冲读 + 缩放器
//==================================================================
// 原始宽高同步到148.5M域(供img_scaler在换帧时刻计算新几何; 平时不用)
reg [11:0] w_h1, w_h2;
reg [11:0] h_h1, h_h2;
always @(posedge hdmi_clk) begin
    w_h1 <= img_w; w_h2 <= w_h1;
    h_h1 <= img_h; h_h2 <= h_h1;
end
//行缓冲同步读(148.5M域, 简单双口: 写ui_clk/读hdmi_clk)
reg [127:0] rdw_r;
always @(posedge hdmi_clk)
    rdw_r <= rowbuf[rowbuf_raddr];
img_scaler u_img_scaler(
    .clk            ( hdmi_clk          ),
    .rst_n          ( hdmi_rst_n        ),
    .hdmi_data_req  ( hdmi_data_req     ),
    .img_w          ( w_h2              ),
    .img_h          ( h_h2              ),
    .rd_off         ( rd_off            ),
    .geom_update    ( geom_update       ),
    .rowbuf_dout    ( rdw_r             ),
    .rowbuf_raddr   ( rowbuf_raddr      ),
    .hdmi_data      ( hdmi_data         ),
    .hdmi_data_req_out ( hdmi_data_req_out ),
    .x_off          ( x_off             ),
    .disp_w         ( disp_w            ),
    .step_fix       ( step_fix          ),
    .disp_h         ( disp_h            ),
    .band_line      ( band_line         ),
    .img_w_lat_o    ( img_w_lat_o       ),
    .src_h_o        ( src_h_o           )
);

// ====================================================================
// [DEBUG] ILA 探针 (仅当 synth_design -verilog_define DEBUG_ILA 时插入)
//   打包 128bit:
//   [28:0] ddr3_rd_addr  [29] rd_start [30] rd_done [31] busy
//   [42:32] fetch_line   [53:43] sy_fetch [64:54] row_vaddr [75:65] data_row
//   [85:76] waddr        [86] need_read [87] wrap_pending
//   [98:88] bl_s2        [109:99] h_u2   [121:110] w_u2
//   [122] swap_reset     [123] geo_chg   [124] rd_data_vld  [127:125] state
// ====================================================================
`ifdef DEBUG_ILA
// 64bit 探针(几何诊断版):
//  [11:0] w_u2  [23:12] h_u2  [34:24] fetch_line  [45:35] sy_fetch
//  [56:46] row_vaddr  [57] need_read  [58] ddr3_busy
//  [59] rd_start  [60] rd_done  [63:61] state
wire [63:0] dbg_probe = {
    w_u2[11:0], h_u2[11:0], fetch_line[10:0], sy_fetch[10:0],
    row_vaddr[10:0], need_read, ddr3_busy,
    ddr3_rd_start, ddr3_rd_done, state[2:0]
};
(* mark_debug = "true", keep = "true" *) wire [63:0] dbg_probe_md = dbg_probe;
`endif

endmodule
