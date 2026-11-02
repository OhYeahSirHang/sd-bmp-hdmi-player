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
// 2022.09.03     Ao Guohua     1.0          Original
//                                                      
// --------------------------------------------------------------------
// --------------------------------------------------------------------
//////////////////////////////////////////////////////////////////////////////////
`include "vga_parameter_cfg.v"
module vga_driver
(
            input           clk_in,
            input           rst_n ,
            output          rd_data_req  , 
            input  [23:0]   rd_data, //{R,G,B}
            output [11:0]   h_addr , //数据横坐标地址
            output [11:0]   v_addr , //数据纵坐标
            
            output  reg     vga_hs ,
            output  reg     vga_vs ,
            output  reg     vga_de ,
            output          vga_clk,
            output [23:0]   vga_data,  //{R,G,B}
            output          vsync_out  //场同步信号输出（用于双缓冲原子切换）
    );
//=======================================================
//  Signal declarations
//=======================================================
reg [11:0]	cnt_h;//行计数器
reg [11:0]	cnt_v;//场计数器
//vga_clk
assign vga_clk=clk_in;    
//cnt_h 行计数器
always @(posedge vga_clk or negedge rst_n) begin
    if(rst_n==1'b0)
        cnt_h<=12'd0;
    else if(cnt_h==`H_TOTAL-1'b1)
            cnt_h<=12'd0;
    else   cnt_h<=cnt_h+1'b1;
end
//cnt_v 列计数器
always @(posedge vga_clk or negedge rst_n) begin
    if(rst_n==1'b0)
        cnt_v<=12'd0;
    else if(cnt_v==`V_TOTAL-1'b1&&cnt_h==`H_TOTAL-1'b1)
            cnt_v<=12'd0;
    else if(cnt_h==`H_TOTAL- 1'b1) 
            cnt_v<=cnt_v+1'b1;
    else   cnt_v<=cnt_v;
end
//vga_hs 行同步信号
always @(posedge vga_clk or negedge rst_n) begin
    if(rst_n==1'b0)
        vga_hs<=1'b1;
    else if(cnt_h==`H_TOTAL- 1'b1)
            vga_hs<=1'b1;
    else if(cnt_h==`H_SYNC- 1'b1)
            vga_hs<=1'b0;
    else  vga_hs<=vga_hs;
end
//vga_vs 列同步信号
always @(posedge vga_clk or negedge rst_n) begin
    if(rst_n==1'b0)
        vga_vs<=1'b1;
    else if(cnt_v==`V_TOTAL- 1'b1&&cnt_h==`H_TOTAL- 1'b1)
            vga_vs<=1'b1;
    else if(cnt_v==`V_SYNC- 1'b1&&cnt_h==`H_TOTAL- 1'b1)
            vga_vs<=1'b0;
    else    vga_vs<=vga_vs;
end
//vga_de 数据有效信号
always @(posedge vga_clk or negedge rst_n) begin
    if(rst_n==1'b0)
        vga_de<=1'b0;
    else if(cnt_v>`V_START- 1'b1&&cnt_v <=`V_END- 1'b1)begin
                if(cnt_h==`H_START- 1'b1)
                       vga_de<=1'b1;
                else if(cnt_h==`H_END- 1'b1)
                      vga_de<=1'b0;
                else  vga_de<=vga_de;
    end
    else  vga_de<=1'b0;
end
assign h_addr=vga_de?(cnt_h-`H_START):'d0;
assign v_addr=vga_de?(cnt_v-`V_START):'d0;
assign rd_data_req     = vga_de   ;
assign vga_data  = rd_data  ;
assign vsync_out = vga_vs   ;
endmodule
