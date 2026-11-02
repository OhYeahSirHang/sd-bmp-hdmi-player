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
module hdmi_trans(
		input clk1x,
		input clk5x,
		input rst,
		input [7:0]image_r,
		input [7:0]image_g,
		input [7:0]image_b,
		input hsync,
		input vsync,
		input de,
		
		output hdmi_tx_clk_n,
		output hdmi_tx_clk_p,
		
		output hdmi_tx_chn_r_n,
		output hdmi_tx_chn_r_p,
		
		output hdmi_tx_chn_g_n,
		output hdmi_tx_chn_g_p,
		
		output hdmi_tx_chn_b_n,
		output hdmi_tx_chn_b_p
			
    );
	
	wire [9:0] encode_chn_r;
	wire [9:0] encode_chn_g;
	wire [9:0] encode_chn_b;
encode encode_inst_r(
  .clkin	(clk1x),    // pixel clock input
  .rstin	(rst),    // async. reset input (active high)
  .din		(image_r),      // data inputs: expect registered
  .c0		(1'b0),       // c0 input
  .c1		(1'b0),       // c1 input
  .de		(de),       // de input
  .dout     (encode_chn_r) // data outputs
);

encode encode_inst_g(
  .clkin	(clk1x),    // pixel clock input
  .rstin	(rst),    // async. reset input (active high)
  .din		(image_g),      // data inputs: expect registered
  .c0		(1'b0),       // c0 input
  .c1		(1'b0),       // c1 input
  .de		(de),       // de input
  .dout     (encode_chn_g) // data outputs
);

encode encode_inst_b(
  .clkin	(clk1x),    // pixel clock input
  .rstin	(rst),    // async. reset input (active high)
  .din		(image_b),      // data inputs: expect registered
  .c0		(hsync),       // c0 input
  .c1		(vsync),       // c1 input
  .de		(de),       // de input
  .dout     (encode_chn_b) // data outputs
);	
//把并行数据转化为串行数据
parallel_to_serial  parallel_to_serial_chn_r(
		.clk1x		(clk1x),
		.clk5x		(clk5x),
		.rst		(rst),
		.din		(encode_chn_r),
		.dout_p		(hdmi_tx_chn_r_p),
		.dout_n     (hdmi_tx_chn_r_n)
    );
	
parallel_to_serial  parallel_to_serial_chn_g(
		.clk1x		(clk1x),
		.clk5x		(clk5x),
		.rst		(rst),
		.din		(encode_chn_g),
		.dout_p		(hdmi_tx_chn_g_p),
		.dout_n     (hdmi_tx_chn_g_n)
    );
	
parallel_to_serial  parallel_to_serial_chn_b(
		.clk1x		(clk1x),
		.clk5x		(clk5x),
		.rst		(rst),
		.din		(encode_chn_b),
		.dout_p		(hdmi_tx_chn_b_p),
		.dout_n     (hdmi_tx_chn_b_n)
    );	
   
parallel_to_serial inst_parallel_to_serial_clk
		(
			.clk1x  (clk1x),
			.clk5x  (clk5x),
			.rst    (rst),
			.din    (10'b11111_00000), //用于产生所需要的时钟信号，刚好和clk_1x相对应,这就是相当于视频本身的时钟
			.dout_p (hdmi_tx_clk_p),
			.dout_n (hdmi_tx_clk_n)
		);

endmodule
