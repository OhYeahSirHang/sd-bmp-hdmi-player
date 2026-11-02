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
// 2022.08.22     Ao Guohua     1.0          Original
//                                                      
// --------------------------------------------------------------------
// --------------------------------------------------------------------
module sd_wr(
        input        clk      ,
        input        rst_n    ,
        //sd卡接口
        output reg   sd_cs_n  ,
        input        sd_miso  ,
        output  reg  sd_mosi  ,
        //用户接口
        input           sd_wr_start    ,//一次写数据开始
         output  reg     sd_wr_data_req ,//请求写数据
         input  [31:0]   sd_wr_sec_addr ,
         input  [7:0]    sd_wr_data     ,
         output          sd_wr_busy     ,
         output  reg     sd_wr_done   
      );
  localparam  HEAD_BYTE = 8'hfe;
  //状态定义
  localparam  IDLE    =7'b0000001; 
  localparam  WR_CMD42=7'b0000010;
  localparam  WR_WAIT =7'b0000100;
  localparam  WR_PRE  =7'b0001000;
  localparam  WR_DATA =7'b0010000;
  localparam  WR_CRC  =7'b0100000;
  localparam  WR_BUSY =7'b1000000;
  reg [6:0]     state ; 
  //reg define 
  reg          ack_done      ;//接受的使能信号，接受完成产生一个高电平
  reg          ack_flag      ;
  reg [5:0]    ack_bit_cnt   ;
  reg [7:0]    ack_data      ;
  reg          sd_miso_d     ;
  wire  [47:0] cmd42         ;//构成命令CMD42
  reg          detect_flag   ;
  reg  [4:0]   detect_cnt    ;
  reg  [5:0]   cmd_bit_cnt   ;
  reg  [8:0]   wr_data_cnt   ;
  reg  [2:0]   wait_cnt      ;
  reg  [7:0]   r_sd_wr_data     ;
  reg  [31:0]  r_sd_wr_sec_addr;
  //***************r_sd_wr_sec_addr********************
  always@(posedge clk or negedge rst_n)begin
    if(!rst_n)                         
          r_sd_wr_sec_addr<='d0;                      
    else if(sd_wr_start)                            
          r_sd_wr_sec_addr<=sd_wr_sec_addr;  
    else 
          r_sd_wr_sec_addr<=r_sd_wr_sec_addr ;                  
  end
  /******************************************/
  assign cmd42={8'h58,r_sd_wr_sec_addr,8'hff};  
  //用来接受数据
  //ack_flag
  always @(posedge clk or negedge rst_n ) begin
      if(!rst_n)
          ack_flag<=1'b0;
      else if(sd_miso==1'b0&&state==WR_CMD42)
               ack_flag<=1'b1;
      else if(ack_bit_cnt=='d7)
                ack_flag<=1'b0;
  end
  //ack_bit_cnt
  always @(posedge clk or negedge rst_n ) begin
      if(!rst_n)
          ack_bit_cnt<='d0;
      else if(sd_miso==1'b0||ack_flag)begin
              if(ack_bit_cnt=='d7)
                  ack_bit_cnt<='d0;
              else 
                  ack_bit_cnt<=ack_bit_cnt+1'b1;
      end
      else 
            ack_bit_cnt<='d0;      
  end
  //ack_data 
  always @(posedge clk or negedge rst_n ) begin
      if(!rst_n)
          ack_data<='d0;
      else if(sd_miso==1'b0||ack_flag)
               ack_data<={ack_data[6:0],sd_miso};
      else 
            ack_data<=ack_data;   
  end
  //ack_done
  always @(posedge clk or negedge rst_n ) begin
      if(!rst_n)
          ack_done<=1'b0;
      else if(ack_bit_cnt=='d7)
               ack_done<=1'b1;
      else ack_done<=1'b0;    
  end
  //sd_miso_d
  always @(posedge clk or negedge rst_n) begin
      if(!rst_n)
          sd_miso_d<=1'b0;
      else 
          sd_miso_d<=sd_miso;     
  end
 //***********finite state machine*******
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)   
       state<=IDLE;
   else begin
         case (state)
             IDLE: begin
                    if(sd_wr_start)
                        state<=WR_CMD42;
                     else
                         state<=IDLE;
                end 
             WR_CMD42:begin
                     if(ack_done)
                         if(ack_data[7:0]==8'h00)
                              state<=WR_WAIT;
                         else 
                              state<=IDLE;      
                     else  
                              state<=WR_CMD42;
                               
             end
             WR_WAIT:begin
                    if(wait_cnt=='d5)  
                         state<=WR_PRE;
                    else 
                         state<=WR_WAIT;   
             end
             WR_PRE:begin
                    if(cmd_bit_cnt=='d7)
                         state<=WR_DATA;  
                    else 
                         state<=WR_PRE;        
             end 
             WR_DATA:begin
                   if(wr_data_cnt=='d511&&cmd_bit_cnt=='d7)
                           state<=WR_CRC;
                   else 
                           state<=WR_DATA;
             end
             WR_CRC:begin
                   if(cmd_bit_cnt=='d15)
                         state<=WR_BUSY;
                   else
                         state<=WR_CRC; 
             end
             WR_BUSY:begin
                   if(detect_cnt=='d7)
                        state<=IDLE;
                   else 
                        state<=WR_BUSY;  
             end
             default:begin
                    state<=IDLE;
             end     
         endcase
   end    
 end
 //sd_mosi
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n) begin
         sd_mosi    <=1'b1;
         sd_cs_n    <=1'b1;
         cmd_bit_cnt<='d0;
         wr_data_cnt<='d0;
         detect_cnt<='d0;
         detect_flag<=1'b0;
         sd_wr_done<=1'b0;
         wait_cnt<='d0;
   end
   else begin
         case (state)
             IDLE:begin
                 sd_mosi    <=1'b1;
                 sd_cs_n    <=1'b1;
                 cmd_bit_cnt<='d0;
                 wr_data_cnt<='d0;
                 sd_wr_done<=1'b0;
                 wait_cnt<='d0;
             end 
             WR_CMD42:begin
                 if(cmd_bit_cnt<='d47)begin
                       sd_cs_n     <=1'b0; 
                       sd_mosi     <=cmd42[47-cmd_bit_cnt];
                       cmd_bit_cnt <=cmd_bit_cnt+1'b1;  
                  end 
                  else begin
                       if(ack_done)begin
                          sd_cs_n   <=1'b0;  
                          sd_mosi   <=1'b1;
                          cmd_bit_cnt<='d0;
 
                       end
                      else begin
                           sd_cs_n    <=1'b0   ;  
                           sd_mosi    <=1'b1   ;
                           cmd_bit_cnt<=cmd_bit_cnt;
                      end          
                  end          
             end
             WR_WAIT:begin
                     wait_cnt<=wait_cnt+1'b1;
             end
             WR_PRE:begin
                 if(cmd_bit_cnt<'d7)begin
                       sd_cs_n     <=1'b0; 
                       sd_mosi     <=HEAD_BYTE[7-cmd_bit_cnt];
                       cmd_bit_cnt <=cmd_bit_cnt+1'b1; 
                  end if(cmd_bit_cnt=='d7) begin
                         sd_cs_n     <=1'b0; 
                         sd_mosi     <=HEAD_BYTE[7-cmd_bit_cnt];
                         cmd_bit_cnt <=0;
                  end      
             end
             WR_DATA:begin
                  if (cmd_bit_cnt<=7)begin
                       sd_cs_n     <=1'b0; 
                       sd_mosi     <=r_sd_wr_data[7-cmd_bit_cnt];
                       if(cmd_bit_cnt==7)begin
                              cmd_bit_cnt <='d0;
                       end
                       else   
                             cmd_bit_cnt <=cmd_bit_cnt+1'b1;
                  end 
                  if(cmd_bit_cnt=='d7)
                         wr_data_cnt<=wr_data_cnt+1'b1;
                  else 
                          wr_data_cnt<=wr_data_cnt;  
             end
            WR_CRC:begin
                 if (cmd_bit_cnt<='d15) begin
                      sd_mosi  <=1'b1;
                     if(cmd_bit_cnt=='d15)
                          cmd_bit_cnt='d0;
                     else 
                          cmd_bit_cnt<=cmd_bit_cnt+1'b1;     
                 end      
            end
            WR_BUSY:begin
                 if(sd_miso==1'b1&&sd_miso_d==1'b0) 
                       detect_flag<=1'b1;
                 else  if(detect_flag&&sd_miso_d==1'b1)begin
                          if(detect_cnt=='d7)begin
                              sd_wr_done<=1'b1;
                              detect_flag<=1'b0;
                              detect_cnt<='d0;
                          end
                          else 
                             detect_cnt<=detect_cnt+1'b1;  
                 end
                 else   begin
                           detect_flag<=1'b0;
                           detect_cnt<='d0;
                 end   
            end
             default: begin
                       sd_mosi    <=1'b1;
                       sd_cs_n    <=1'b1;
                       cmd_bit_cnt<='d0;
                       wr_data_cnt<='d0;
                       detect_cnt <='d0;
                       detect_flag<=1'b0;
             end
         endcase
   end
 end
 always @(*) begin
       if(!rst_n) 
           sd_wr_data_req=1'b0;
       else if(state==WR_PRE&&cmd_bit_cnt=='d7)
                 sd_wr_data_req=1'b1;
       else if(state==WR_DATA&&cmd_bit_cnt=='d7&&wr_data_cnt!=511)
                   sd_wr_data_req=1'b1;
       else sd_wr_data_req = 1'b0; 
 end
 //***************r_sd_wr_data********************
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)                         
        r_sd_wr_data<='d0;                      
   else if(sd_wr_data_req)                             
             r_sd_wr_data<=sd_wr_data;
   else  r_sd_wr_data<=r_sd_wr_data;                     
 end
 assign sd_wr_busy=state!=IDLE;
 endmodule