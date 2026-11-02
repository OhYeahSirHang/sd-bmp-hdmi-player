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
// 2023.02.24     Ao Guohua     1.0          Original
//                                                      
// --------------------------------------------------------------------
// --------------------------------------------------------------------
module hdmi_driver(
     input           clk1x          ,
	 input           clk5x          ,
     input           rst_n          ,
     output          hdmi_data_req  , 
     input  [23:0]   hdmi_data      , //{R,G,B}
     input           de_in          , //图像处理后对齐的数据有效信号（替代内部vga_de送编码器）
     output [11:0]   h_addr         , //数据横坐标地址
     output [11:0]   v_addr         ,//数据纵坐标
     output          vsync_out      , //场同步输出（双缓冲原子切换用）
     //hdmi的差分对输出
     output          hdmi_tx_clk_n  ,
	 output          hdmi_tx_clk_p  ,
	 output          hdmi_tx_chn_r_n,
	 output          hdmi_tx_chn_r_p,
     output          hdmi_tx_chn_g_n,
     output          hdmi_tx_chn_g_p,
	 output          hdmi_tx_chn_b_n,
	 output          hdmi_tx_chn_b_p

    );
wire          vga_hs  ;
wire          vga_vs  ;
wire          vga_vs_out ; //vga_driver输出的场同步
wire          vga_de  ;
wire          vga_clk ;
wire  [23:0]  vga_data; //{R,G,B}
wire  [7:0]   image_r ; 
wire  [7:0]   image_g ;
wire  [7:0]   image_b ;
assign {image_r,image_g,image_b}=vga_data;
vga_driver u_vga_driver(
    .clk_in       ( clk1x       ),
    .rst_n        ( rst_n        ),
    .rd_data_req  ( hdmi_data_req  ),
    .rd_data      ( hdmi_data      ),
    .h_addr       ( h_addr       ),
    .v_addr       ( v_addr       ),
    .vga_hs       ( vga_hs       ),
    .vga_vs       ( vga_vs       ),
    .vga_de       ( vga_de       ),
    .vga_clk      ( vga_clk      ),
    .vga_data     ( vga_data     ),
    .vsync_out    ( vga_vs_out   )
);

assign vsync_out = vga_vs_out;

hdmi_trans u_hdmi_trans(
    .clk1x           ( clk1x           ),
    .clk5x           ( clk5x           ),
    .rst             ( !rst_n            ),
    .image_r         ( image_r         ),
    .image_g         ( image_g         ),
    .image_b         ( image_b         ),
    .hsync           ( vga_hs           ),
    .vsync           ( vga_vs           ),
    .de              ( de_in           ),
    .hdmi_tx_clk_n   ( hdmi_tx_clk_n   ),
    .hdmi_tx_clk_p   ( hdmi_tx_clk_p   ),
    .hdmi_tx_chn_r_n ( hdmi_tx_chn_r_n ),
    .hdmi_tx_chn_r_p ( hdmi_tx_chn_r_p ),
    .hdmi_tx_chn_g_n ( hdmi_tx_chn_g_n ),
    .hdmi_tx_chn_g_p ( hdmi_tx_chn_g_p ),
    .hdmi_tx_chn_b_n ( hdmi_tx_chn_b_n ),
    .hdmi_tx_chn_b_p  ( hdmi_tx_chn_b_p  )
);

endmodule
