// --------------------------------------------------------------------
// rd_bmp.v (双缓冲修订版)
// 功能:
//   1. 扫描SD卡找BMP图片('BM'+1920x1080校验), 输出像素数据
//   2. 双缓冲控制: 写侧永远写后台缓冲(wr_buf_sel), 读侧永远读显示缓冲(disp_buf_sel)
//   3. 一帧写完进入WAIT_VSYNC, 在VSYNC上升沿原子切换两个缓冲 -> 画面无撕裂
//   4. 上电自动加载第一张, WAIT_KEY状态等待按键(key_down)切换下一张
//   5. 已明确去除5秒自动轮播
//   6. img_num输出当前图片编号(找到新图时+1, 供OSD显示)
// 说明: sd_rd_sec_addr 在 sd_rd_done(上一块读完)即更新, 早于RDAD_DATA_START
//      一拍、早于sd_rd采样两拍(40ns@50M), 建立时间充裕, 无竞争
// --------------------------------------------------------------------
module rd_bmp #(
   parameter [31:0] CATALOG_END = 32'h0003_2000   // 100MB, 与原 STOP_ADDR 一致
)(
   input               clk 		   ,//系统时钟50M	
   input               rst_n 	   ,//系统复位信号
   input	  	      key_down	   ,//短按: 切换下一张图片
   input               vsync       ,//场同步信号(148.5M域, 用于原子切换双缓冲)
   output	  reg       find_led    ,//led在闪烁时表示正在查找BMP, led常亮表示已找到
   input               init_done   ,//sd卡初始化完成
   output              wr_buf_sel  ,//后台缓冲选择: 0=BufferA 1=BufferB (写侧)
   output              disp_buf_sel,//显示缓冲选择: 0=BufferA 1=BufferB (读侧)
   output reg  [7:0]   img_num     ,//当前图片编号(1开始)
   output              frame_ready ,//1: 新一帧已完整写入后台缓冲(等待换帧) -> img_trans
   input               swap_allow  ,//1: 允许在VSYNC原子切换双缓冲(来自img_trans, 148.5M域)
   //读取sd卡数据的接口             
   output              sd_rd_start         ,
   output reg   [31:0] sd_rd_sec_addr      ,
    input               sd_rd_data_valid    ,
    input        [7:0]  sd_rd_data          ,
    input               sd_rd_done          ,
    input               sd_busy             ,   
    //输出的图像数据信息
    output  [7:0]      img_data             ,
    output             img_data_vld
);
//状态定义
localparam IDLE            = 8'b0000_0001;//空状态
localparam FIND_HEAD_START = 8'b0000_0010;//产生找帧头开始信号
localparam FIND_HEAD       = 8'b0000_0100;//寻找图像数据开始的帧头
localparam RDAD_DATA_START = 8'b0000_1000;//产生读取数据的开始信号
localparam READ_DATA       = 8'b0001_0000;//读取图像的数据
localparam FRAME_DONE      = 8'b0010_0000;//一帧读取完成(等待进入VSYNC同步)
localparam WAIT_VSYNC      = 8'b0100_0000;//等待VSYNC上升沿, 原子切换双缓冲
localparam WAIT_KEY        = 8'b1000_0000;//等待按键切换下一张
//寻址100MB的终止扇形区域 100*2^20/512 =100*2^11=0x32000
localparam STOP_ADDR      =32'h0003_2000;
//BMP图片总大小: 54 + 1920*1080*(24/8) = 6220854
localparam  HEAD_LEN        =          54               ;//文件头和信息头的长度
localparam	BMP_TYPE 	    = 	  16'h424d          ;
localparam	IMG_WIDTH 	    = 	  32'd1920          ;
localparam	IMG_HEIGHT 	    = 	  32'd1080	        ;
localparam	IMG_DATA_LEN    = IMG_WIDTH * IMG_HEIGHT * 3;
localparam	BLOCK_LEN	    =	        512		        ;
reg [15:0]  bmp_type  ;
reg [31:0]  img_width ;
reg [31:0]  img_height;
reg [7:0]   state     ;
reg [9:0]   block_cnt ;//用于计数读出的512个数据
reg         find_img  ;//识别文件头和信息头找到bmp图片
reg         img_flag  ;//表明是图像数据输出
reg  [31:0] img_cnt   ;
reg  [31:0] led_cnt   ;
// 图片索引表: 启动时扫前 CATALOG_END 个扇区, 记录每张 BMP 头扇区
reg  [31:0] img_sec [0:15];
reg  [4:0]  img_total;
reg  [4:0]  cur_idx;
reg         catalog_mode;
reg         load_sec;
reg  [31:0] load_sec_val;
reg         img_num_set;
reg  [7:0]  img_num_val;
//vsync三级同步与上升沿检测(148.5M->50M跨时钟)
reg  [2:0]  vsync_sync;
wire        vsync_rise = vsync_sync[2] & (~vsync_sync[1]);
reg  wr_buf_sel_r  ;
reg  disp_buf_sel_r;
//swap_allow(148.5M域)两级同步到50M; 复位默认允许(兼容无过渡直切)
reg [1:0] swap_allow_sync;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)         swap_allow_sync <= 2'b11;
    else               swap_allow_sync <= {swap_allow_sync[0], swap_allow};
end
wire swap_allow_50m = swap_allow_sync[1];
assign img_data_vld=img_flag?sd_rd_data_valid:1'b0;
assign img_data    =img_flag?sd_rd_data:'d0;
assign wr_buf_sel  =wr_buf_sel_r;
assign disp_buf_sel=disp_buf_sel_r;
//新一帧已完整写入后台缓冲, 等待VSYNC+允许信号后换帧 (供img_trans启动过渡)
assign frame_ready = (state == WAIT_VSYNC);
//vsync同步
always@(posedge clk or negedge rst_n)begin
  if(!rst_n)
       vsync_sync<=3'd0;
  else
       vsync_sync<={vsync_sync[1:0],vsync};
end
//**************state***********************
always@(posedge clk or negedge rst_n)begin
  if(!rst_n) begin
        state<=IDLE;
        catalog_mode<=1'b1;
        load_sec<=1'b0;
        load_sec_val<=32'd0;
        img_total<=5'd0;
        cur_idx<=5'd0;
        img_num_set<=1'b0;
        img_num_val<=8'd0;
  end
  else begin
        load_sec    <= 1'b0;
        img_num_set <= 1'b0;
        case (state)
        IDLE:begin
            if(init_done)
                state<=FIND_HEAD_START;
            else 
                state<=IDLE;
        end 
        FIND_HEAD_START:begin
            if(sd_rd_start)
                state<=FIND_HEAD;
            else
                state<=FIND_HEAD_START;
        end
        FIND_HEAD:begin
            if(sd_rd_done)begin
                 if(catalog_mode) begin
                     // 枚举阶段: 记录合法 BMP 头扇区, 继续扫到 CATALOG_END
                     if(find_img) begin
                         if(img_total < 5'd16)
                             img_sec[img_total] <= sd_rd_sec_addr;   // 当前仍是头扇区
                         if(img_total < 5'd16)
                             img_total <= img_total + 1'b1;
                     end
                     if((sd_rd_sec_addr + 32'd1) >= CATALOG_END) begin
                         catalog_mode <= 1'b0;
                         if(img_total > 5'd0) begin
                             load_sec      <= 1'b1;
                             load_sec_val  <= img_sec[0];
                             cur_idx       <= 5'd0;
                             img_num_set   <= 1'b1;
                             img_num_val   <= 8'd0;
                         end
                         state <= IDLE;   // 多等一拍, 让 load_sec 先把地址装好
                     end
                     else begin
                         state <= FIND_HEAD_START;
                     end
                 end
                 else begin
                     if(find_img)
                         state<=RDAD_DATA_START;
                     else
                         state<=FIND_HEAD_START;
                 end
            end
            else
                 state<=FIND_HEAD;
        end
        RDAD_DATA_START:begin
              if(sd_rd_start)
                  state<=READ_DATA;
              else 
                  state<=RDAD_DATA_START;        
        end  
        READ_DATA:begin
              if(sd_rd_done)begin
                if(img_cnt==IMG_DATA_LEN)  
                    state<=FRAME_DONE;
                else 
                    state<=RDAD_DATA_START; 
              end
              else 
                   state<=READ_DATA;
        end
        FRAME_DONE:begin
                state<=WAIT_VSYNC;
        end
        WAIT_VSYNC:begin
            // 关键修复: 状态推进条件必须与双缓冲切换条件一致(vsync_rise && swap_allow_50m),
            // 否则 vsync 到来时过渡未允许(swap_allow=0)会误进 WAIT_KEY 但缓冲没切,
            // 导致 img_trans 永远等不到换帧(图不换/图1图1/循环中断)
            if(vsync_rise && swap_allow_50m)begin
                //VSYNC上升沿原子切换: 显示缓冲与后台缓冲同时翻转
                state<=WAIT_KEY;
            end
            else 
                state<=WAIT_VSYNC;
        end
        WAIT_KEY:begin
            if(key_down) begin
                if(img_total != 5'd0) begin
                    // 索引表直接跳下一张; 最后一张 -> 第 0 张
                    load_sec      <= 1'b1;
                    load_sec_val  <= img_sec[(cur_idx + 5'd1 >= img_total) ? 5'd0 : (cur_idx + 5'd1)];
                    cur_idx       <= (cur_idx + 5'd1 >= img_total) ? 5'd0 : (cur_idx + 5'd1);
                    img_num_set   <= 1'b1;
                    img_num_val   <= {3'd0, ((cur_idx + 5'd1 >= img_total) ? 5'd0 : (cur_idx + 5'd1))};
                    state         <= IDLE;
                end
                else
                    state <= IDLE;   // 没有索引, 退回顺序扫描
            end
            else
                state<=WAIT_KEY;
        end
    default: state<=IDLE;
  endcase
  end
end
 assign sd_rd_start=(state==FIND_HEAD_START||state==RDAD_DATA_START)&&sd_busy==1'b0;
 //***************block_cnt*****************
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)                           
         block_cnt<='d0;                       
   else if(sd_rd_done)
             block_cnt<='d0;   
   else if(sd_rd_data_valid)begin    
             if(block_cnt==BLOCK_LEN-1)     
                  block_cnt<='d0;
             else                 
                  block_cnt<= block_cnt+1'b1; 
   end                                                      
   else                            
              block_cnt<=block_cnt;                                                       
 end
 //在FIND_HEAD状态抓取数据，来判断是否为BMP的数据区域
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)begin
        bmp_type    <='d0;
        img_width   <='d0;
        img_height  <='d0;
   end                                                      
   else if(sd_rd_data_valid&&state==FIND_HEAD)begin                     
             case (block_cnt)
                 'd0: bmp_type[15:8]    <=sd_rd_data;
                 'd1: bmp_type[7:0]     <=sd_rd_data;
                 'd18:img_width[7:0]    <=sd_rd_data; 
                 'd19:img_width[15:8]   <=sd_rd_data;
                 'd20:img_width[23:16]  <=sd_rd_data;
                 'd21:img_width[31:24]  <=sd_rd_data;
                 'd22:img_height[7:0]   <=sd_rd_data; 
                 'd23:img_height[15:8]  <=sd_rd_data;
                 'd24:img_height[23:16] <=sd_rd_data;
                 'd25:img_height[31:24] <=sd_rd_data;
                 default: begin
                     bmp_type    <=  bmp_type  ; 
                     img_width   <=  img_width ;
                     img_height  <=  img_height;
                 end
             endcase                      
   end
   else if(sd_rd_done)begin
             bmp_type    <='d0;
             img_width   <='d0;
             img_height  <='d0;
   end    
 end
 //***************find_img********************
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)                         
         find_img<=1'b0;                      
   else if(sd_rd_done)   
            find_img<=1'b0;
   else if(bmp_type==BMP_TYPE&&img_width==IMG_WIDTH&&img_height==IMG_HEIGHT)
            find_img<=1'b1;
   else  find_img<=find_img;                                                           
 end
 //*************img_flag**********************
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)                         
         img_flag<='d0;                      
   else if(find_img==1'b1&&block_cnt==HEAD_LEN&&state==FIND_HEAD&&!catalog_mode)                              
             img_flag<=1'b1;
   else if(sd_rd_data_valid&&img_cnt==IMG_DATA_LEN-1)  
             img_flag<=1'b0;
   else    img_flag<=img_flag;                          
 end
 //**************img_cnt********************
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)                           
         img_cnt<='d0;                       
   else if(img_flag&&sd_rd_data_valid)
             img_cnt<=img_cnt+1'b1;   
   else if(state==FRAME_DONE)
            img_cnt<='d0; 
   else  
         img_cnt<=img_cnt;               
 end
 //***************sd_rd_sec_addr********************
 //在sd_rd_done(上一块读完)即更新下一扇区地址, 早于RDAD_DATA_START一拍、
 //早于sd_rd模块采样两拍(40ns@50M), 建立时间充裕, 不存在竞争
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)                         
         sd_rd_sec_addr<='d0;                      
   else if(load_sec)
         sd_rd_sec_addr<=load_sec_val;
   else if(sd_rd_done)begin
           if(sd_rd_sec_addr==STOP_ADDR)
                sd_rd_sec_addr<='d0; 
           else
                sd_rd_sec_addr<=sd_rd_sec_addr+1'b1;
   end 
   else
         sd_rd_sec_addr<=sd_rd_sec_addr;                      
 end
 //**************双缓冲切换***********************
 //初始: 写BufferA(0), 显示BufferB(1); 第一帧写完后VSYNC切换 -> 显示A、写B
 //此后每帧写完在 VSYNC上升沿 且 swap_allow=1(过渡允许) 时原子切换,
 //读侧永远读已写完的缓冲, 无撕裂; 过渡动画期间swap_allow=0会保持旧图
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)begin
        wr_buf_sel_r  <=1'b0;
        disp_buf_sel_r<=1'b1;
   end
   else if(state==WAIT_VSYNC&&vsync_rise&&swap_allow_50m)begin
        wr_buf_sel_r  <=~wr_buf_sel_r;
        disp_buf_sel_r<=~disp_buf_sel_r;
   end
   else begin
        wr_buf_sel_r  <=wr_buf_sel_r;
        disp_buf_sel_r<=disp_buf_sel_r;
   end
 end
 //**************img_num***********************
 //找到一张合法BMP图(进入读数据前)编号+1
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)
        img_num<=8'd0;
   else if(img_num_set)
        img_num<=img_num_val;
   else if(!catalog_mode && state==FIND_HEAD && sd_rd_done && find_img)
        img_num<=img_num+1'b1;
   else
        img_num<=img_num;
 end
 //**************led_cnt***********************
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)                           
         led_cnt<='d0;                       
   else if(state==FIND_HEAD_START||state==FIND_HEAD)begin 
           if(led_cnt==5_000_000-1)    
                 led_cnt<='d0;              
           else    
                 led_cnt<=led_cnt+1'b1;                      
   end                                 
   else                          
            led_cnt<='d0;                                                  
 end
 //**************find_led***********************
 always@(posedge clk or negedge rst_n)begin
   if(!rst_n)                           
         find_led<=1'b1;//复位时led熄灭                     
   else if(state==IDLE||state==FIND_HEAD_START||state==FIND_HEAD)begin    
            if(led_cnt==5_000_000-1)                    
                 find_led<=~find_led;
            else  
                 find_led<=find_led;      
   end                                                     
   else    
         find_led<=1'b0; //已找到图片(含WAIT_VSYNC/WAIT_KEY), led常亮  
 end                                  
 endmodule
