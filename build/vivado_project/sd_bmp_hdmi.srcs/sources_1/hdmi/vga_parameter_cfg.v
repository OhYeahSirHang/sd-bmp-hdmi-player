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
// 2023.02.16     Ao Guohua     1.0          Original
//                                                      
// --------------------------------------------------------------------
// --------------------------------------------------------------------
//`define  vga_480x272_60HZ
////`define vga_1024x768_60Hz
`define vga_1920x1080_60Hz
`ifdef vga_480x272_60HZ 

	   `define       H_TOTAL 	        12'd525    //一行所需要的总的周期
	   `define       H_SYNC        	        12'd41     //行同步信号
	   `define       H_START 	        12'd43    //H_START=Hor Sync Time +H Back Porch +H Left Border
	   `define       H_END 		        12'd523   //数据有效位结束的值 
	   `define       V_TOTAL 	        12'd286    //场计数的总的值
	   `define       V_SYNC		        12'd10     //场同步信号
	   `define       V_START 	        12'd12     //场数据有效的开始
	   `define       V_END 		        12'd284   //场数据有效的结束
	   `define       SCREEN_X               12'd480     //屏幕的长度   //方块的长度
	   `define       SCREEN_Y               12'd272     //屏幕的宽度   //方块的宽度
           `define       SQUARE_X               12'd150      
	   `define       SQUARE_Y               12'd150      
`elsif vga_1024x768_60Hz
        `define          H_TOTAL                12'd1344           //一行总共需要计数的值
        `define          H_SYNC                 12'd136            //行同步计数值
        `define          H_START                12'd296            //行图像数据有效开始计数值
        `define          H_END                  12'd1320           //行图像数据有效结束计数值
        `define          V_TOTAL                12'd806            //场总共需要计数的值
        `define          V_SYNC                 12'd6              //场同步计数值
        `define          V_START                12'd35             //场图像数据有效开始计数值
        `define          V_END                  12'd803             //场图像数据有效结束计数值

        `define          SCREEN_X               12'd1024           //屏幕的长度
        `define          SCREEN_Y               12'd768            //屏幕的宽度
        `define          SQUARE_X               12'd256            //方块的长度
        `define          SQUARE_Y               12'd256            //方块的宽度
`elsif vga_1920x1080_60Hz
        `define         H_TOTAL                  12'd2200         //一行所需要的总的周期
        `define         H_SYNC                   12'd44           //行同步信号
        `define         H_START                  12'd192           //H_START=Hor Sync Time +H Back Porch +H Left Border                                   //数据有效信号开始的值
        `define         H_END                    12'd2112         //数据有效位结束的值 
        `define         V_TOTAL                  12'd1125         //场计数的总的值
        `define         V_SYNC                   12'd5            //场同步信号
        `define         V_START                  12'd41           //场数据有效的开始
        `define         V_END                    12'd1121         //场数据有效的结束
        
        `define         SCREEN_X                 12'd1920           //屏幕的长度
        `define         SCREEN_Y                 12'd1080           //屏幕的宽度
        `define         SQUARE_X                 12'd512            //方块的长度
        `define         SQUARE_Y                 12'd512             //方块的宽度
`endif 
 
