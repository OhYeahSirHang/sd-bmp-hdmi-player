// --------------------------------------------------------------------
// Copyright (c) 2022 by MicroPhase Technologies Inc. 
// --------------------------------------------------------------------
//
// Permission:
//
//   MicroPhase grants permission to use and modify this code for use
//   in synthesis for all MicroPhase Development Boards.
//   Other use of this code, including the selling 
//   ,duplication, or modification of any portion is strictly prohibited.
//
// Disclaimer:
//
//   This VHDL/Verilog or C/C++ source code is intended as a design reference
//   which illustrates how these types of functions can be implemented.
//   It is the user's responsibility to verify their design for
//   consistency and functionality through the use of formal
//   verification methods.  MicroPhase provides no warranty regarding the use 
//   or functionality of this code.
//
// --------------------------------------------------------------------
//           
//                     MicroPhase Technologies Inc
//                     Shanghai, China
//
//                     web: http://www.microphase.cn/   
//                     email: support@microphase.cn
//
// --------------------------------------------------------------------
// --------------------------------------------------------------------
//   
// Major Functions:   
//
// --------------------------------------------------------------------
// --------------------------------------------------------------------
//
//  Revision History    
//  Date          By            Revision    Change Description
//---------------------------------------------------------------------
// 2022.09.19     Ao Guohua     1.0          Original
//                                                      
// --------------------------------------------------------------------
// --------------------------------------------------------------------
`include "../hdmi/vga_parameter_cfg.v"
module ddr3_rx_buffer #(
        parameter    DDR3_ADDR_MAX=512*512-8,//ddr3地址的最大值
        parameter    BURST_LEN = 64           

 )(
     //数据输入端口
     input               clk                      ,
     input               data_in_vld              ,
     input  [7:0]        data_in                  ,
     // [VID] 视频直通口: 16bit 像素, 1 像素/时钟 (BMP 字节流与视频二选一)
     input               vid_en                   ,//1: 使用 vid_px 直通
     input  [15:0]       vid_px                   ,
     input               vid_px_vld               ,
     input               frame_sync               ,//1: 写地址归零(切换媒体源时)
     //ddr3相关的控制接口
     input               ui_clk                   ,
     input               ui_rst                   ,
     input               ddr3_busy                ,
     input               buf_sel                  ,//双缓冲选择：0=BufferA 1=BufferB（后台缓冲，写侧）
     output              ddr3_wr_start            ,
     input               ddr3_wr_addr_req         ,
     output      [28:0]  ddr3_wr_addr             ,
     input               ddr3_wr_data_req         ,
     output      [127:0] ddr3_wr_data             ,
     input               ddr3_wr_done 
        
    );
localparam   IDLE  =3'b001 ;  //复位的时候处于空闲状态
localparam   ARBIT =3'b010 ;  //判断状态，等待写入信号
localparam   WRITE =3'b100 ;  //写状态，写入数据
reg  [2:0]      state      ;
reg  [1:0]      shift_cnt  ; //移位的计数器
reg             shift_vld  ; //移位数据有效
reg  [23:0]     shift_data ; //移位的数据
wire [15:0]     din        ; 
wire            full       ;
wire            empty      ;
wire [6 : 0]    rd_data_count;
wire [9 : 0]    wr_data_count;
wire            wr_rst_busy;
wire            rd_rst_busy;
reg  [11:0]     h_addr     ;//图像的行地址
reg  [16:0]     v_addr     ;//图像的列地址
//***************shift_cnt******************
always@(posedge clk or posedge wr_rst_busy)begin
  if(wr_rst_busy)                         
        shift_cnt<='d0;                      
  else if(data_in_vld)begin
          if(shift_cnt=='d2)
              shift_cnt<='d0;
          else 
              shift_cnt<=shift_cnt+1'b1;
  end 
  else 
       shift_cnt<=shift_cnt;                                                        
end
//***************wr_rst_busy******************
always@(posedge clk or posedge wr_rst_busy)begin
  if(wr_rst_busy)
     shift_vld<=1'b0;
  else if(data_in_vld)begin
           if(shift_cnt=='d2)
               shift_vld<=1'b1;
           else
                shift_vld<=1'b0;               
  end
  else 
        shift_vld<=1'b0;    
end   
//**************shift_data*********************
always@(posedge clk or posedge wr_rst_busy)begin
  if(wr_rst_busy)                           
        shift_data<='d0;                       
  else if(data_in_vld)begin                     
            shift_data<={data_in,shift_data[23:8]};                      
   end                                 
  else  begin                          
            shift_data<=shift_data;                      
  end                                  
end
assign din={shift_data[23:19],shift_data[15:10],shift_data[7:3]};
// [VID] 视频直通: 绕过 3 字节移位, 直接写 16bit 像素
wire [15:0] din_mux = vid_en ? vid_px     : din;
wire        vld_mux = vid_en ? vid_px_vld : shift_vld;

// 媒体/源切换 flush: frame_sync 只清 h/v 时, FIFO 里旧源像素会在 h=0
// 继续写, 导致新图片整块右移。frame_sync 后复位 FIFO 31 个 ui_clk。
reg [4:0] flush_cnt;
always @(posedge ui_clk or posedge ui_rst) begin
    if(ui_rst)            flush_cnt <= 5'd0;
    else if(frame_sync)   flush_cnt <= 5'd31;
    else if(flush_cnt!=0) flush_cnt <= flush_cnt - 1'b1;
end
wire fifo_rst = ui_rst | frame_sync | (flush_cnt != 5'd0);

ddr3_rx_fifo ddr3_rx_fifo (
  .rst   (fifo_rst),                      // input wire rst
  .wr_clk(clk),                // input wire wr_clk
  .rd_clk(ui_clk),                // input wire rd_clk
  .din   (din_mux),                      // input wire [15 : 0] din
  .wr_en (vld_mux),                  // input wire wr_en
  .rd_en (ddr3_wr_data_req),                  // input wire rd_en
  .dout  (ddr3_wr_data),                    // output wire [127 : 0] dout
  .full  (full),                    // output wire full
  .empty (empty),                  // output wire empty
  .rd_data_count(rd_data_count),  // output wire [6 : 0] rd_data_count
  .wr_data_count(wr_data_count),  // output wire [9 : 0] wr_data_count
  .wr_rst_busy(wr_rst_busy),      // output wire wr_rst_busy
  .rd_rst_busy(rd_rst_busy)      // output wire rd_rst_busy
);
//finite state machine 
always @(posedge ui_clk or posedge rd_rst_busy) begin
    if(rd_rst_busy)
        state<=IDLE;
    else 
     case (state)
        IDLE:begin
               state<=ARBIT;
        end
        ARBIT: 
            begin
                if(ddr3_wr_start)
                     state<=WRITE;
                else 
                     state<=ARBIT;
            end
        WRITE:
            begin
                 if(ddr3_wr_done)
                    state<=ARBIT;
                 else 
                      state<=WRITE;
            end
        default:  state<=ARBIT;
     endcase       
end
//当fifo中有64个数的时候，产生wr_start信号，
//当fifo在First Word Fall Through模式下rd_data_count显示的数据个数要比fifo中实际的数据个数要少两个 
//当rd_data_count为62的时候，fifo中实际可读个数为64
assign ddr3_wr_start=state==ARBIT&&ddr3_busy==1'b0&&rd_data_count>=BURST_LEN-2;
//h_addr
always @(posedge ui_clk or posedge rd_rst_busy) begin
    if(rd_rst_busy)
        h_addr<='d0;
    else if(frame_sync)
        h_addr<='d0;
    else if(ddr3_wr_addr_req)begin
            if(h_addr==`SCREEN_X-8)
                  h_addr<='d0;
            else 
                  h_addr<=h_addr+'d8;
    end 
    else h_addr<=h_addr;     
end
//v_addr
always @(posedge ui_clk or posedge rd_rst_busy) begin
    if(rd_rst_busy)
        v_addr<='d0;
    else if(frame_sync)
        v_addr<='d0;
    else if(ddr3_wr_addr_req&&h_addr==`SCREEN_X-8)begin
            if(v_addr==`SCREEN_Y-1)
                 v_addr<='d0;
            else 
                 v_addr<=v_addr+'d1;
    end
    else 
           v_addr<=v_addr; 
end
//ddr3_wr_addr
//双缓冲地址：把buf_sel插入v_addr的bit11空闲位，Buffer B天然偏移2^11*2^12=8M个128bit字(约134MB)
//Buffer A地址范围:0~4.19M  Buffer B地址范围:8M~12.19M，完全隔离互不重叠
assign ddr3_wr_addr={v_addr[16:12],buf_sel,v_addr[10:0],h_addr[11:0]};
endmodule
