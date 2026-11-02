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
// 2022.08.24     Ao Guohua     1.0          Original
//                                                      
// --------------------------------------------------------------------
// --------------------------------------------------------------------
module sd_ctrl  #(parameter   SYS_FRENCY  =50_000_000,//系统时钟频率
                  parameter   INIT_FRENCY =250_000    //SD卡初始化时钟设置为250k
                 )(
        input           clk  ,
        input           rst_n    ,

        output          sd_clk     ,
        output reg      sd_cs_n    ,
        input           sd_miso    ,
        output  reg     sd_mosi    ,
        
        output           init_done  , //初始化完成
        //写的应用接口
        input              sd_wr_start         ,    //一次写数据开始
        output             sd_wr_data_req      ,//请求写数据
        input  [31:0]      sd_wr_sec_addr      ,
        input  [7:0]       sd_wr_data          ,
        output             sd_wr_done          ,
        //用户接口  
         input             sd_rd_start         ,
         input   [31:0]    sd_rd_sec_addr      ,
         input             sd_rd_multi         , // 1=视频 CMD18 多块读
         input   [15:0]    sd_rd_blk_cnt       , // 多块读的 512B 块数
         output            sd_rd_data_valid    ,
         output  [7:0]     sd_rd_data          ,
         output            sd_rd_done          ,
         output            sd_busy        
          
    );
wire        init_clk         ;
wire        init_sd_cs_n     ;
wire        init_sd_mosi     ;
wire        wr_sd_cs_n       ;
wire        wr_sd_mosi       ;
wire        rd_sd_cs_n       ;
wire        rd_sd_mosi       ;
wire        sd_wr_busy       ;
wire        sd_rd_busy       ;

// ------------------------------------------------------------------
// SD 读时钟与位使能
//   单块/BMP/探测: sd_clk = ~clk (50MHz), tx/rx_en 每个 clk 都有效
//   多块视频    : sd_clk_r 每 clk 翻转 -> 25MHz,
//                 tx_en 在下降沿, rx_en 在上升沿
//   25MHz 数据率 3.125MB/s, 低于 1080p 生成消耗, 不会冲垮 4 行缓冲。
// ------------------------------------------------------------------
reg  sd_clk_r;
wire sd_tx_en;
wire sd_rx_en;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        sd_clk_r <= 1'b0;
    else if(!init_done)
        sd_clk_r <= 1'b0;
    else if(sd_rd_multi)
        sd_clk_r <= ~sd_clk_r;
    else
        sd_clk_r <= 1'b0;
end

assign sd_tx_en = init_done && (sd_rd_multi ?  sd_clk_r : 1'b1);
assign sd_rx_en = init_done && (sd_rd_multi ? ~sd_clk_r : 1'b1);

sd_init #(
    .SYS_FRENCY  (SYS_FRENCY ), //系统时钟频率
    .INIT_FRENCY (INIT_FRENCY)  //SD卡初始化时钟设置为250k

)sd_init
(
        .clk    (clk),
        .rst_n      (rst_n  ),

        .sd_clk     (init_clk),   //用来初始SD卡的时钟
        .sd_cs_n    (init_sd_cs_n),
        .sd_miso    (sd_miso),
        .sd_mosi    (init_sd_mosi),
        .init_done  (init_done)           
    );
sd_wr  sd_wr(
        .clk       (clk),
        .rst_n     (rst_n),
        //sd卡接口
        .sd_cs_n  (wr_sd_cs_n),
        .sd_miso  (sd_miso),
        .sd_mosi  (wr_sd_mosi),
        //用户接口
        .sd_wr_start    (sd_wr_start)  ,    //一次写数据开始
        .sd_wr_data_req (sd_wr_data_req)  ,//请求写数据
        .sd_wr_sec_addr (sd_wr_sec_addr)  ,
        .sd_wr_data     (sd_wr_data)  ,
        .sd_wr_busy     (sd_wr_busy)  ,
        .sd_wr_done     (sd_wr_done) 
    );

sd_rd  sd_rd(
       .clk             (clk),
       .rst_n           (rst_n),
       //sd卡接口
       .sd_cs_n          (rd_sd_cs_n),
       .sd_miso          (sd_miso),
       .sd_mosi          (rd_sd_mosi),
       //用户接口  
       .sd_rd_start          (sd_rd_start ),
       .sd_rd_sec_addr       (sd_rd_sec_addr  ),
       .sd_rd_multi          (sd_rd_multi   ),
       .sd_rd_blk_cnt        (sd_rd_blk_cnt ),
       .sd_tx_en             (sd_tx_en      ),
       .sd_rx_en             (sd_rx_en      ),
       .sd_rd_data_valid     (sd_rd_data_valid),
       .sd_rd_data           (sd_rd_data ),
       .sd_rd_busy           (sd_rd_busy ),
       .sd_rd_done           (sd_rd_done)                
    );
assign   sd_busy=sd_wr_busy|sd_rd_busy;
always @(*) begin
 if(rst_n==1'b0)begin
          sd_cs_n =1'b1;
          sd_mosi =1'b1;
 end   
 else  if(init_done==1'b0)begin
            sd_cs_n =init_sd_cs_n;
            sd_mosi =init_sd_mosi;
    end
 else if(sd_wr_busy)begin
            sd_cs_n =wr_sd_cs_n   ;
            sd_mosi =wr_sd_mosi   ;
    end
else if(sd_rd_busy)begin
             sd_cs_n =rd_sd_cs_n   ;
             sd_mosi =rd_sd_mosi   ;  
    end 
else begin
            sd_cs_n =1'b1  ;
            sd_mosi =1'b1  ;  
end
        
end
assign sd_clk = (init_done==1'b0) ? init_clk :
                (sd_rd_multi      ? sd_clk_r : ~clk); //数据在下降沿输出
endmodule
