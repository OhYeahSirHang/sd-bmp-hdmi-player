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
module sd_init #(
    parameter   SYS_FRENCY =50_000_000, //系统时钟频率
    parameter   INIT_FRENCY =250_000     //SD卡初始化时钟设置为25k

)
(
        input        clk        ,
        input        rst_n      ,

          output       sd_clk     ,//用来初始SD卡的时钟,
          output reg   sd_cs_n    ,
          input        sd_miso    ,
          output  reg  sd_mosi    ,
  
          output     init_done             
      );
 //模块内部参数定义
 //将SD卡置于空闲状态，由于命令号及参数为固定值,CRC也为固定值,CRC = 8'h95,
 //值得注意的是FPGA接受到SD卡的回复的时候8个周期后需要拉高CS_N,然后再接受其他的命令
 localparam CMD0 =   {8'h40,8'h00,8'h00,8'h00,8'h00,8'h95};
 //查询协议类型命令，发送主设备的电压范围，用来区分Micro SD卡的版本类型，只有SD 2.0以后的卡才有这种类型
 localparam  CMD8  = {8'h48,8'h00,8'h00,8'h01,8'haa,8'h87};
 //告诉SD卡接下来的命令是应用相关命令，而非标准命令, 不需要CRC
 localparam  CMD55 = {8'h77,8'h00,8'h00,8'h00,8'h00,8'hff};  
 //发送操作寄存器(OCR)内容, 不需要CRC
 localparam  ACMD41= {8'h69,8'h40,8'h00,8'h00,8'h00,8'hff};
 //时钟分频的系统，初始化的时候需要降低时钟的频率
 localparam DIV_CNT_MAX=SYS_FRENCY/INIT_FRENCY/2 -1;
 //上电至少等待74个同步时钟周期,在等待上电稳定期间,sd_cs = 1,sd_sd_mosi = 1
 localparam POWER_ON_NUM=5000;
 //发送软件复位命令时等待SD卡返回的最大时间,T = 100ms; 100_000us/4us = 25000
 //将这个值设置为50_000 
 localparam OVER_TIME_NUM=50_000;
 //状态定义
 localparam IDLE       = 6'b000_001; //上电的默认状态
 localparam SEND_CMD0  = 6'b000_010; //发送CMD0命令后等待应答
 localparam SEND_CMD8  = 6'b000_100; //发送CMD8命令后等待应答
 localparam SEND_CMD55 = 6'b001_000; //发送CMD55并且等待应答
 localparam SEND_ACMD41= 6'b010_000; //发送ACMD41并的能带应答
 localparam INIT_DONE  = 6'b100_000; //初始化完成
 reg [15:0] over_time_cnt ;
 reg [15:0] div_cnt       ;
 reg        div_clk       ;
 wire       div_clk_180deg;//将div_clk翻转180度用来抓取sd_miso输入的数据
 reg [5:0]  state         ;
 reg [15:0] power_on_cnt  ;
 reg [5:0]  cmd_bit_cnt   ;
 
reg        ack_done      ;//接受的使能信号，接受完成产生一个高电平
reg        ack_flag      ;
reg [5:0]  ack_bit_cnt   ;
reg [47:0] ack_data      ;//从机发给主机的数据，这里采用6个字节，SD的应答中最多5个字节，剩下一个字节用来做NOP，不操作
                          //SD卡的有的命令接受后需要等待8个bit才进行后面的操作，这里统一将接受应答统一等待8bit
assign init_done=state==INIT_DONE;
/**************用clk产生初始化使用的时钟***********/
//**************div_cnt***********************
always@(posedge clk or negedge rst_n)begin
  if(!rst_n)                           
        div_cnt<='d0;                       
  else if(div_cnt==DIV_CNT_MAX)                  
            div_cnt<='d0;                                            
  else                           
            div_cnt<=div_cnt+1'b1;                                                      
end
//**************div_clk***********************
always@(posedge clk or negedge rst_n)begin
  if(!rst_n)                           
        div_clk<='d0;                       
  else if(div_cnt==DIV_CNT_MAX)begin                     
            div_clk<=~div_clk;                      
   end                                 
  else  begin                          
            div_clk<=div_clk;                              
  end                                  
end
//sd的spi的时钟极性和相位极性都是1，即是在sd_clk的下降沿数据变化，在sd_clk的上升沿抓取数据，
//在这里用~div_clk作sd_clk，我们在div_clk的上升沿变化数据，相当于在sd_clk的下降沿变化数据
//sd_clk  
assign sd_clk=~div_clk;
//***********
//power_cnt
always @(posedge div_clk or negedge rst_n ) begin
     if(!rst_n) 
         power_on_cnt<='d0;
     else if(state==IDLE)begin
                if(power_on_cnt==POWER_ON_NUM)
                      power_on_cnt<='d0; 
                else 
                      power_on_cnt<=power_on_cnt+1'b1;
     end
     else 
             power_on_cnt<='d0;            
end
//over_time_cnt
always @(posedge div_clk or negedge rst_n ) begin
     if(!rst_n) 
         over_time_cnt<='d0;
      else if(state==SEND_CMD0)
               over_time_cnt<=over_time_cnt+1'b1;
       else 
            over_time_cnt<='d0;    
  end
  /*******************finite state machine*******************/
  always @(posedge div_clk or negedge rst_n ) begin
      if(!rst_n)
          state<=IDLE;
      else begin
            case (state)
              IDLE:begin
                  if(power_on_cnt==POWER_ON_NUM)
                      state<=SEND_CMD0;
                  else
                       state<=IDLE;    
              end 
              SEND_CMD0:begin
                   if(ack_done==1'b1)begin
                          if(ack_data[47:40]==8'h01)
                              state<=SEND_CMD8;
                          else 
                              state<=IDLE;
                   end   
                   else if(over_time_cnt==OVER_TIME_NUM) 
                          state<=IDLE;          
                  else  state<=SEND_CMD0;                         
              end
              SEND_CMD8:begin
                  if(ack_done)begin
                     if(ack_data[19:16]==4'b0001)
                           state<=SEND_CMD55;
                     else 
                           state<=SEND_CMD0;
                  end
                  else 
                        state<=SEND_CMD8;   
              end
            SEND_CMD55:begin
                  if(ack_done)begin
                       if(ack_data[47:40]==8'h01)
                          state<=SEND_ACMD41;
                       else 
                           state<=SEND_CMD8;
                  end   
                  else 
                         state<=SEND_CMD55;   
            end
            SEND_ACMD41:begin
                  if (ack_done) begin
                       if(ack_data[47:40]==8'h00)
                           state<=INIT_DONE;
                       else 
                           state<=SEND_CMD55;
                  end
                  else 
                        state<=SEND_ACMD41;
            end 
            INIT_DONE:
                   state<=INIT_DONE;  
                
              default: state<=IDLE;
            endcase
      end
  end
  //通过task来减小代码的重复率
  task  send_cmd;
   input [47:0] cmd;
           begin
             if(cmd_bit_cnt<='d47)begin
                       sd_cs_n     <=   1'b0;
                       sd_mosi     <=cmd[47-cmd_bit_cnt];
                       cmd_bit_cnt <=cmd_bit_cnt+1'b1;  
                  end 
                  else begin
                       if(ack_done)begin
                          sd_cs_n   <= 0;
                          sd_mosi   <= 1'b1;
                          cmd_bit_cnt<='d0;
                       end
                      else begin
                           sd_cs_n   <=   1'b0    ;
                           sd_mosi    <=  1'b1    ;
                           cmd_bit_cnt<=cmd_bit_cnt;
                      end          
                  end          
           end
  endtask
  //根据状态给出输出
  always @(posedge div_clk or negedge rst_n ) begin
      if(!rst_n)begin
          sd_cs_n     <=   1'b1;
          sd_mosi     <=   1'b1;
          cmd_bit_cnt <=   'd0;    
      end
      else begin
           case (state)
              IDLE:begin
                  sd_cs_n   <=   1'b1;
                  sd_mosi   <=   1'b1;
                  cmd_bit_cnt <=   'd0;    
              end 
              SEND_CMD0:  send_cmd (CMD0 );
              SEND_CMD8:  send_cmd (CMD8 );
              SEND_CMD55: send_cmd (CMD55);
              SEND_ACMD41:send_cmd (ACMD41);
              INIT_DONE:begin
                     sd_cs_n   <=    1'b1;
                     sd_mosi   <=    1'b1;
                     cmd_bit_cnt <=   'd0; 
              end
              default:begin
                    sd_cs_n    <=    1'b1;
                    sd_mosi     <=   1'b1;
                    cmd_bit_cnt <=   'd0; 
              end 
           endcase
      end
         
  end
  //ack_flag
  always @(posedge div_clk or negedge rst_n ) begin
      if(!rst_n)
          ack_flag<=1'b0;
      else if(sd_miso==1'b0)
               ack_flag<=1'b1;
      else if(ack_bit_cnt=='d47)
                ack_flag<=1'b0;
  end
  //ack_bit_cnt
  always @(posedge div_clk or negedge rst_n ) begin
      if(!rst_n)
          ack_bit_cnt<='d0;
      else if(sd_miso==1'b0||ack_flag)begin
              if(ack_bit_cnt=='d47)
                  ack_bit_cnt<='d0;
              else 
                  ack_bit_cnt<=ack_bit_cnt+1'b1;
      end
      else 
            ack_bit_cnt<='d0;      
  end
  //ack_data 
  always @(posedge div_clk or negedge rst_n ) begin
      if(!rst_n)
          ack_data<='d0;
      else if(sd_miso==1'b0||ack_flag)
               ack_data<={ack_data[46:0],sd_miso};
      else 
            ack_data<=ack_data;   
  end
  //ack_done
  always @(posedge div_clk or negedge rst_n ) begin
      if(!rst_n)
          ack_done<=1'b0;
      else if(ack_bit_cnt=='d47)
              ack_done<=1'b1;
      else  ack_done<=1'b0;    
  end
  endmodule