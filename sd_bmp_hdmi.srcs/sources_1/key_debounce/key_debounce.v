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
// 2022.09.06     Ao Guohua     1.0          Original
//                                                      
// --------------------------------------------------------------------
// --------------------------------------------------------------------
module key_debounce(
       input       clk         , //50M的时钟输入  
       input       rst_n       ,
       input       key_in      ,
       output      key_down    ,  //按键按下产生一个高电平吗脉冲
       output      key_up         //按键松开产生一个高电平
       
    );
 localparam   IDLE    =4'b0001,//空闲状态
              FILTER0 =4'b0010,//按下按键的抖动状态
              DOWN    =4'b0100,//按键被按下的状态
              FILTER1 =4'b1000;//松开按键的抖动状态
  localparam   CNT_20MS =20_000_000/20-1 ; //20ms计数的最大值
  reg [31:0]   cnt     ;   //计数器
  reg [1:0]    key_filter; //用两个信号消除亚稳态
  reg [1:0]    key_in_d;   //用来消除亚稳态的寄存器
  reg [3:0]    state   ;
  wire         nedge   ;   //下降沿信号
  wire         pedge   ;   //上升沿信号
  wire         end_cnt ;   //时间达到20ms 
  //消除亚稳态
  always@(posedge clk or negedge rst_n)begin
    if(!rst_n)
         key_filter<=2'b11;
    else 
         key_filter<={key_filter[0],key_in};
  end
  //用两个寄存器对信号延时来识别上下降沿
  always @(posedge clk or negedge rst_n) begin
      if(!rst_n)
         key_in_d<=2'b11;
      else
         key_in_d<={key_in_d[0],key_filter[1]};
  end
  //下降沿检测 
  assign nedge=(!key_in_d[0])&key_in_d[1];
  
  //上升沿检测 
  assign pedge=key_in_d[0]&(!key_in_d[1]);
  
  //计数器
  always @(posedge clk or negedge rst_n) begin
     if(!rst_n)
          cnt<='d0;
      else if(state==FILTER0)begin
              if(end_cnt|pedge)
                  cnt<='d0;
              else 
                   cnt<=cnt+1'b1;
      end
      else if(state==FILTER1)begin
             if(end_cnt|nedge)
                   cnt<='d0;
             else 
                  cnt<=cnt+1'b1;   
      end
      else cnt<='d0;
  end
  assign end_cnt=cnt==CNT_20MS;
  //FSM
  always @(posedge clk or negedge rst_n) begin
      if(!rst_n)
          state<=IDLE;
      else begin
            case (state)
                IDLE:begin
                        if(nedge)
                           state<=FILTER0;
                        else
                           state<=IDLE; 
                     end 
                FILTER0:begin
                          if(end_cnt)//表明低电平稳定了20ms
                              state<=DOWN;
                          else state<=FILTER0;       
                end
                DOWN:begin
                        if(pedge)//上升沿到来
                              state<=FILTER1; 
                        else 
                              state<=DOWN;           
                end
                FILTER1:begin
                       if(end_cnt)//表明高电平稳定了20ms，一次按键完成
                           state<=IDLE;
                       else 
                          state<=FILTER1; 
                end
                default: state<=IDLE; 
            endcase
      end
  end   
 assign  key_down= state==FILTER0&&end_cnt;
 assign  key_up  = state==FILTER1&&end_cnt;
 endmodule