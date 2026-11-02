`timescale 1ns/1ps
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
// 2026.09.16     Double buffer + img process + OSD 修订
//    - DDR3双缓冲(地址位插入隔离) + VSYNC原子切换, 按键切图无撕裂
//    - 双按键: KEY1(AA1)切下一张, KEY2(W1)循环切换图像处理模式
//    - img_process: 原图/灰度/Sobel + OSD图片编号
//    - 去除5s自动轮播
// 2026.09.22     v1.1 修订: 顶部滚动字幕 + 图片切换过渡效果
//    - img_process: 新增顶部从左向右滑动字幕(文本易改, 8x16字库)
//    - img_trans  : 新增2s图片切换过渡(淡入淡出/左右滑动, 注释选择)
//    - rd_bmp     : 新增 frame_ready/swap_allow 握手, 由过渡模块控制换帧时机
//    - ddr3_tx_buffer: 新增 rd_off 行旋转支持滑动效果
//    - 按键布局不变: KEY1切图(带过渡) KEY2切模式 RESET复位
// 2026.10.18     v3 扩展: FAT32 + BMP/JPEG 双格式 + 多图层OSD菜单
//    - rd_bmp -> rd_img: 真FAT32文件系统(sd_fat32), BMP24bit/JPEG基线
//      解码(jpeg_dec)双格式, 上电自动扫描SD卡根目录(.BMP/.JPG, 最多32张)
//    - key_menu: 双按键菜单  KEY1短按=选中行下移 KEY1长按=菜单显隐
//      KEY2短按=当前行取值循环(图片下一张/模式/字幕颜色/切换效果)
//    - img_trans: 过渡效果运行时4选(淡入淡出/切入/随机线条/溶解)
//    - img_process: 多图层OSD 左上图片参数/右上菜单(左对齐)/正下方
//      中文字幕5色可换 + 顶部滚动字幕(默认关闭)
//    - 全屏1920x1080, 小分辨率等比缩放居中(沿用v2 img_scaler)
// 2026.10.21     合并版(work1读取链 + v3菜单/OSD), 固定1080p BMP-only:
//    - SD读取链(DDR3写侧)沿用 work1 已验证路径: rd_bmp(顺序扫描扇区,
//      找1920x1080 24bit BMP, 最多4张) + sd_ctrl/sd_init/sd_rd(work1) +
//      ddr3_rx_buffer(work1) -> ddr3_ctrl(写接口)
//    - 显示链(DDR3读侧->HDMI)沿用 newdemo1018 v3: ddr3_ctrl/ddr3_rd_ctrl
//      (带rd_len按行突发) + ddr3_tx_buffer(v3行缓冲) + img_scaler
//      (MODE-FIXED 固定1920x1080全屏1:1, 除法器/几何锁存路径已绕开)
//      + img_trans(v3 过渡4选) + img_process(v3 多图层OSD) + key_menu
//    - 目标: SD卡只读1080p BMP -> DDR3双缓冲 -> HDMI全屏1920x1080
//      右上角OSD菜单(KEY1短按选行/长按显隐, KEY2取值)切换:
//        行0: 图片下一张(img_next)
//        行1: 图像显示模式(原图/灰度/边缘/边缘彩色叠加)
//        行2: 底部字幕颜色(黑/白/红/蓝/绿)
//        行3: 图片转场效果(淡入淡出/切入/随机线条/溶解)
//    - img_w/img_h/img_type 固定常量(1920/1080/BMP), 不再随文件系统变化
// --------------------------------------------------------------------
module sd_rd_img  #(
           parameter   SYS_FRENCY    =50_000_000,//系统时钟频率
           parameter   INIT_FRENCY   =250_000   , //SD卡初始化时钟设置为250k
           parameter   DDR3_ADDR_MAX =1920*1080-8,//ddr3地址的最大值
           parameter   BURST_LEN     = 64        ,
           parameter   WR_MAX        = 896  
    )(
        input               clk        ,
        input               rst_n      ,
        input               key_in     ,//KEY1(AA1): 短按菜单选行下移 / 长按菜单显隐
        input               key_in2    ,//KEY2(W1): 当前行取值循环
        output              find_led   ,
        //SD卡接口
        output              sd_clk     ,
        output              sd_cs_n    ,
        input               sd_miso    ,
        output              sd_mosi    ,
        //DDR3接口
        output [14:0]		ddr3_addr      ,  
        output [2:0]		ddr3_ba        ,
        output	            ddr3_cas_n     ,
        output [0:0]		ddr3_ck_n      ,
        output [0:0]		ddr3_ck_p      ,
        output [0:0]		ddr3_cke       ,
        output	            ddr3_ras_n     ,
        output	            ddr3_reset_n   ,
        output	            ddr3_we_n      ,
        inout  [15:0]		ddr3_dq        ,
        inout  [1:0]		ddr3_dqs_n     ,
        inout  [1:0]		ddr3_dqs_p     ,
        output [1:0]		ddr3_dm        ,
        output [0:0]		ddr3_odt       ,
        //hdmi输出相关的接口
         output             hdmi_tx_clk_n   ,
		 output             hdmi_tx_clk_p   ,
		 output             hdmi_tx_chn_r_n ,
		 output             hdmi_tx_chn_r_p ,
		 output             hdmi_tx_chn_g_n ,
		 output             hdmi_tx_chn_g_p ,
		 output             hdmi_tx_chn_b_n ,
		 output             hdmi_tx_chn_b_p ,
         output             hdmi_hpd        

    );
wire            init_done           ;
wire            sd_rd_start         ;
wire  [31:0]    sd_rd_sec_addr      ;
wire            sd_rd_multi         ;//1=视频整帧 CMD18 多块读
wire  [15:0]    sd_rd_blk_cnt       ;//多块读的 512B 块数
wire            sd_rd_data_valid    ;
wire  [7:0]     sd_rd_data          ;
wire            sd_rd_done          ;
wire            sd_busy             ;
wire  [7:0]     img_data            ;
wire            img_data_vld        ;
wire  [7:0]     img_num             ;//当前图片编号(OSD显示用, rd_bmp顺序扫描编号)
wire  [1:0]     img_type            ;//固定 BMP=1 (本工程只读1080p BMP)
wire  [11:0]    img_w               ;//固定 1920 (源像素宽)
wire  [11:0]    img_h               ;//固定 1080 (源像素高)
assign img_type = 2'd1;              // 1 = BMP24bit (与 rd_bmp/rd_img 定义一致)
assign img_w    = 12'd1920;          // [1080P-FIXED] 与 rd_bmp 固定尺寸一致
assign img_h    = 12'd1080;
//双缓冲与图像处理信号
wire            wr_buf_sel          ;//后台缓冲(写侧)
wire            disp_buf_sel        ;//显示缓冲(读侧)
wire            vsync_out           ;//场同步(148.5M域)
wire            key1_pulse          ;//KEY1按下脉冲(去抖)
wire            key1_up_pulse       ;//KEY1松开脉冲(去抖)
wire            key2_pulse          ;//KEY2按下脉冲(去抖)
wire            key2_up_pulse       ;//KEY2松开脉冲(去抖)
wire  [4:0]     proc_mode           ;//0..14原15种 + 15中值 + 16Canny近似
wire  [2:0]     color_sel           ;//字幕颜色 0=黑 1=白 2=红 3=蓝 4=绿
wire  [3:0]     effect_sel          ;//0淡入淡出 1切入 2随机线条 3溶解 4百叶窗 5中心扩散 6上下合拢 7棋盘格
wire            menu_show           ;//菜单显示(OSD图层)
wire            media_sel           ;//0=图片 1=视频 (菜单媒体行)
wire            vid_next            ;//切换下一段视频
wire  [3:0]     vid_fps_t           ;//视频实测帧率十位
wire  [3:0]     vid_fps_o           ;//视频实测帧率个位
wire            frame_sync          ;//写地址归零(ui域单拍)
wire  [2:0]     menu_row            ;//菜单选中行
wire            img_next            ;//切下一张脉冲
wire  [23:0]    img_proc_data       ;//图像处理后数据
wire            img_proc_de         ;//图像处理后数据有效(对齐)
//ddr3相关的控制接口
wire          ui_clk            ;   
wire          ui_rst            ;    
wire          ddr3_busy         ;    
wire          ddr3_wr_start     ;    
wire          ddr3_wr_addr_req  ;    
wire  [28:0]  ddr3_wr_addr      ;    
wire          ddr3_wr_data_req  ;    
wire  [127:0] ddr3_wr_data      ;    
wire          ddr3_wr_done      ;
wire          ddr3_rd_start     ;  //signals about control
wire          ddr3_rd_addr_req  ;  //读地址请求信号
wire [28:0]   ddr3_rd_addr      ;  
wire          ddr3_rd_data_vld  ;
wire [127:0]  ddr3_rd_data      ;
wire          ddr3_rd_done      ;   
wire [9:0]    ddr3_rd_len_w     ;  //读突发长度=行字数(一次突发只读1行)
wire          clk_200m          ;
wire          sys_rst_n         ;
wire          hdmi_data_req  ;//hdmi请求数据
wire [23:0]   hdmi_data      ;
wire          hdmi_rst_n     ;
wire          clk_1x         ;
wire          clk_5x         ; 
//过渡效果与缩放相关信号
wire [11:0]   rd_off         ;//切入效果: 行旋转偏移(源像素) -> ddr3_tx_buffer
wire          swap_allow     ;//过渡允许换帧信号 -> rd_bmp (1=允许)
wire          frame_ready    ;//新一帧已完整写入后台缓冲 -> img_trans
wire [23:0]   trans_data     ;//过渡后像素 -> img_process
wire          trans_req      ;//过渡后像素有效(与trans_data对齐)
wire          hdmi_data_req_out ;//tx_buffer延迟2拍的de -> img_trans
wire [10:0]   geom_x_off     ;//黑边左偏移(缩放器, 固定1080p=0)
wire [10:0]   geom_disp_w    ;//显示宽(缩放器, 固定1080p=1920)
wire [27:0]   geom_step      ;//水平缩放定点步进(固定1080p=65536)
wire          geom_update    ;//换帧时刻 -> 缩放器锁存几何

sd_ctrl  #(.SYS_FRENCY  (SYS_FRENCY ),//系统时钟频率
           .INIT_FRENCY (INIT_FRENCY) //SD卡初始化时钟设置为250k
                 )
        sd_ctrl(
        .clk        (clk      ),
        .rst_n      (rst_n    ),
        .sd_clk     (sd_clk   ),
        .sd_cs_n    (sd_cs_n  ),
        .sd_miso    (sd_miso  ),
        .sd_mosi    (sd_mosi  ),  
        .init_done  (init_done), //初始化完成
        //写的应用接口(只读工程, 不连接)
        .sd_wr_start     (),    //一次写数据开始
        .sd_wr_data_req  (),//请求写数据
        .sd_wr_sec_addr  (),
        .sd_wr_data      (),
        .sd_wr_done      (),
        //用户接口  
        .sd_rd_start      (sd_rd_start      ),
        .sd_rd_sec_addr   (sd_rd_sec_addr   ),
        .sd_rd_multi      (sd_rd_multi      ),
        .sd_rd_blk_cnt    (sd_rd_blk_cnt    ),
        .sd_rd_data_valid (sd_rd_data_valid ),
        .sd_rd_data       (sd_rd_data       ),
        .sd_rd_done       (sd_rd_done       ),
        .sd_busy          (sd_busy          )   
    );
//KEY1: 去抖 (短按=菜单选行 / 长按=菜单显隐)
key_debounce key1_debounce(
       .clk         (clk     ), //50M的时钟输入  
       .rst_n       (rst_n   ),
       .key_in      (key_in  ),
       .key_down    (key1_pulse), //按下脉冲
       .key_up      (key1_up_pulse) //松开脉冲
    );
//KEY2: 去抖 (当前行取值循环)
key_debounce key2_debounce(
       .clk         (clk     ), //50M的时钟输入  
       .rst_n       (rst_n   ),
       .key_in      (key_in2 ),
       .key_down    (key2_pulse), //按下脉冲
       .key_up      (key2_up_pulse) //松开脉冲
    );
//菜单控制状态机: KEY1行下移/长按显隐, KEY2当前行取值循环
key_menu u_key_menu(
    .clk         ( clk           ),
    .rst_n       ( rst_n         ),
    .key1_down   ( key1_pulse    ),
    .key1_up     ( key1_up_pulse ),
    .key2_down   ( key2_pulse    ),
    .key2_up     ( key2_up_pulse ),
    .img_next    ( img_next      ),
    .vid_next    ( vid_next      ),
    .mode        ( proc_mode     ),
    .color_sel   ( color_sel     ),
    .effect_sel  ( effect_sel    ),
    .menu_show   ( menu_show     ),
    .menu_row    ( menu_row      ),
    .media_sel   ( media_sel     )
);
//--------------------------------------------------------------------
// 媒体源仲裁: 先探测扇区0 是否 DV1 视频; 是则只跑视频通路, 否则释放 rd_bmp
//--------------------------------------------------------------------
wire        v_sd_start;
wire [31:0] v_sec;
wire        v_sd_multi;
wire [15:0] v_sd_blk_cnt;
wire        v_next_ack;
wire        v_wr_sel, v_disp_sel, v_frame_ready, v_find_led;
wire        v_probe_done, v_is_video;
wire [15:0] v_px;
wire        v_px_vld;
wire        rd_sd_start_, rd_wr_sel_, rd_disp_sel_, rd_frame_ready_, rd_find_led_;
wire [31:0] rd_sec_;
wire        vid_rst_n    = rst_n & media_sel;          // 视频被选中才复位释放
wire        rd_bmp_rst_n = rst_n & ~media_sel;         // 图片被选中才复位释放

vid_player u_vid_player(
    .clk            ( clk             ),
    .rst_n          ( vid_rst_n       ),
    .init_done      ( init_done       ),
    .vsync          ( vsync_out       ),
    .swap_allow     ( swap_allow      ),
    .vid_next       ( vid_next        ),
    .vid_next_ack   ( v_next_ack      ),
    .wr_buf_sel     ( v_wr_sel        ),
    .disp_buf_sel   ( v_disp_sel      ),
    .frame_ready    ( v_frame_ready   ),
    .find_led       ( v_find_led      ),
    .sd_rd_start    ( v_sd_start      ),
    .sd_rd_sec_addr ( v_sec           ),
    .sd_rd_multi    ( v_sd_multi      ),
    .sd_rd_blk_cnt  ( v_sd_blk_cnt    ),
    .sd_rd_data_valid(sd_rd_data_valid),
    .sd_rd_data     ( sd_rd_data      ),
    .sd_rd_done     ( sd_rd_done      ),
    .sd_busy        ( sd_busy         ),
    .vid_px         ( v_px            ),
    .vid_px_vld     ( v_px_vld        ),
    .probe_done     ( v_probe_done    ),
    .is_video       ( v_is_video      ),
    .vid_fps_t      ( vid_fps_t       ),
    .vid_fps_o      ( vid_fps_o       )
);

assign wr_buf_sel     = media_sel ? v_wr_sel      : rd_wr_sel_;
assign disp_buf_sel   = media_sel ? v_disp_sel    : rd_disp_sel_;
assign frame_ready    = media_sel ? 1'b0          : rd_frame_ready_;
assign sd_rd_start    = media_sel ? v_sd_start    : rd_sd_start_;
assign sd_rd_sec_addr = media_sel ? v_sec         : rd_sec_;
assign sd_rd_multi    = media_sel ? v_sd_multi    : 1'b0;
assign sd_rd_blk_cnt  = media_sel ? v_sd_blk_cnt  : 16'd1;
assign find_led       = media_sel ? v_find_led    : rd_find_led_;

//--------------------------------------------------------------------
// 媒体源切换 -> DDR3 写地址计数器归零
//   (否则新源的帧从旧源的地址相位开始写, 画面出现固定偏移)
//--------------------------------------------------------------------
reg        media_d;
always @(posedge clk or negedge rst_n)
    if(!rst_n) media_d <= 1'b0;
    else       media_d <= media_sel;
wire media_chg = media_sel ^ media_d;
reg media_tog;
always @(posedge clk or negedge rst_n)
    if(!rst_n) media_tog <= 1'b0;
    else if(media_chg || v_next_ack) media_tog <= ~media_tog;
reg tog_u1, tog_u2, tog_u3;
always @(posedge ui_clk) begin
    tog_u1 <= media_tog; tog_u2 <= tog_u1; tog_u3 <= tog_u2;
end
assign frame_sync = tog_u2 ^ tog_u3;

//图片读取顶层(work1路径): 顺序扫描SD卡扇区, 定位1920x1080 24bit BMP
rd_bmp rd_bmp(
    .clk 		      (clk 	      )      ,//系统时钟50M	
    .rst_n 		      (rd_bmp_rst_n)      ,//探测到视频时保持复位
    .key_down	      (img_next     )      ,//切下一张图片脉冲(key_menu)
    .vsync           (vsync_out    )      ,//场同步(双缓冲原子切换)
    .find_led        (rd_find_led_ )      ,//led闪烁=正在扫描/加载, 常亮=已找到图片
    .init_done       (init_done    )      ,//sd卡初始化完成
    .wr_buf_sel      (rd_wr_sel_   )      ,//后台缓冲(写侧)
    .disp_buf_sel    (rd_disp_sel_ )      ,//显示缓冲(读侧)
    .img_num         (img_num      )      ,//当前图片编号
    .frame_ready     (rd_frame_ready_)    ,//新帧已写入后台缓冲(过渡用)
    .swap_allow      (swap_allow   )      ,//允许换帧(来自img_trans, 1=允许)
    //读取sd卡数据的接口             
    .sd_rd_start     (rd_sd_start_    )   ,
    .sd_rd_sec_addr  (rd_sec_         )   ,
    .sd_rd_data_valid(sd_rd_data_valid)   ,
    .sd_rd_data      (sd_rd_data      )   ,
    .sd_rd_done      (sd_rd_done      )   ,
    .sd_busy         (sd_busy         )   ,   
    //输出的图像数据信息
    .img_data        (img_data    )    ,
    .img_data_vld    (img_data_vld)    
);
//DDR3写侧(work1路径): 像素流 -> 16bit FIFO -> 128bit -> ui域 -> DDR3
ddr3_rx_buffer#(
    .DDR3_ADDR_MAX           ( DDR3_ADDR_MAX ),
    .BURST_LEN               ( BURST_LEN )
)u_ddr3_rx_buffer(
    .clk                     ( clk                     ),
    .data_in_vld             ( img_data_vld             ),
    .data_in                 ( img_data                 ),
    .ui_clk                  ( ui_clk                  ),
    .ui_rst                  ( ui_rst                  ),
    .ddr3_busy               ( ddr3_busy               ),
    .buf_sel                 ( wr_buf_sel              ), //写后台缓冲
    .ddr3_wr_start           ( ddr3_wr_start           ),
    .ddr3_wr_addr_req        ( ddr3_wr_addr_req        ),
    .ddr3_wr_addr            ( ddr3_wr_addr            ),
    .ddr3_wr_data_req        ( ddr3_wr_data_req        ),
    .ddr3_wr_data            ( ddr3_wr_data            ),
    .ddr3_wr_done            ( ddr3_wr_done            ),
    // 视频直通口
    .vid_en                  ( media_sel               ),
    .vid_px                  ( v_px                    ),
    .vid_px_vld              ( v_px_vld                ),
    .frame_sync              ( frame_sync              )
);

ddr3_clock ddr3_clock
   (
    // Clock out ports
    .clk_out1(clk_200m),     // output clk_out1
    // Status and control signals
    .resetn(rst_n), // input resetn
    .locked(sys_rst_n),       // output locked
   // Clock in ports
    .clk_in1(clk));      // input clk_in1
//DDR3控制器(v3): 写接口兼容work1 rx_buffer; 读接口带rd_len按行突发
ddr3_ctrl u_ddr3_ctrl(
    .sys_clk                                               ( clk_200m          ),
    .sys_rst_n                                             ( sys_rst_n         ),
    /*************应用层接口以及时钟**********/  
    .ui_clk                                                ( ui_clk            ),
    .ui_rst                                                ( ui_rst            ),
    .ddr3_busy                                             ( ddr3_busy         ),
    . ddr3_wr_start                                        ( ddr3_wr_start     ),
    .ddr3_wr_data_req                                      ( ddr3_wr_data_req  ),
    .ddr3_wr_data                                          ( ddr3_wr_data      ),
    .ddr3_wr_addr_req                                      ( ddr3_wr_addr_req  ),
    .ddr3_wr_addr                                          ( ddr3_wr_addr      ),
    .ddr3_wr_done                                          ( ddr3_wr_done      ),
    .ddr3_rd_start                                         (  ddr3_rd_start    ),
    .ddr3_rd_addr_req                                      ( ddr3_rd_addr_req  ),
    .ddr3_rd_addr                                          ( ddr3_rd_addr      ),
    .ddr3_rd_len                                           ( ddr3_rd_len_w     ),
    .ddr3_rd_data_vld                                      ( ddr3_rd_data_vld  ),
    .ddr3_rd_data                                          ( ddr3_rd_data      ),
    .ddr3_rd_done                                          ( ddr3_rd_done      ),
    .ddr3_addr                                             ( ddr3_addr         ),
    .ddr3_ba                                               ( ddr3_ba           ),
    .ddr3_cas_n                                            ( ddr3_cas_n        ),
    .ddr3_ck_n                                             ( ddr3_ck_n         ),
    .ddr3_ck_p                                             ( ddr3_ck_p         ),
    .ddr3_cke                                              ( ddr3_cke          ),
    .ddr3_ras_n                                            ( ddr3_ras_n        ),
    .ddr3_reset_n                                          ( ddr3_reset_n      ),
    .ddr3_we_n                                             ( ddr3_we_n         ),
    .ddr3_dq                                               ( ddr3_dq           ),
    .ddr3_dqs_n                                            ( ddr3_dqs_n        ),
    .ddr3_dqs_p                                            ( ddr3_dqs_p        ),
    .ddr3_dm                                               ( ddr3_dm           ),
    .ddr3_odt                                              ( ddr3_odt          )
);

//DDR3读侧/显示(v3路径): 行缓冲 + 固定1080p缩放器 + 几何输出
ddr3_tx_buffer#(
    .WR_MAX            ( WR_MAX )
)u_ddr3_tx_buffer(
    .ui_clk            ( ui_clk            ),
    .ui_rst            ( ui_rst            ),
    .ddr3_busy         ( ddr3_busy         ),
    .buf_sel           ( disp_buf_sel      ), //读显示缓冲
    .img_w             ( img_w             ), //固定1920
    .img_h             ( img_h             ), //固定1080
    .rd_off            ( rd_off            ), //切入效果行旋转偏移
    .ddr3_rd_start     ( ddr3_rd_start     ),
    .ddr3_rd_addr_req  ( ddr3_rd_addr_req  ),
    .ddr3_rd_addr      ( ddr3_rd_addr      ),
    .ddr3_rd_data_vld  ( ddr3_rd_data_vld  ),
    .ddr3_rd_data      ( ddr3_rd_data      ),
    .ddr3_rd_done      ( ddr3_rd_done      ),
    .hdmi_clk          (    clk_1x       ),
    .hdmi_data_req     ( hdmi_data_req     ),
    .hdmi_data         ( hdmi_data         ),
    .hdmi_data_req_out ( hdmi_data_req_out ),
    .hdmi_rst_n        ( hdmi_rst_n        ),
    .x_off             ( geom_x_off        ),
    .disp_w            ( geom_disp_w       ),
    .step_fix          ( geom_step         ),
    .geom_update       ( geom_update       ),
    .ddr3_rd_len       ( ddr3_rd_len_w      )
);

clock clock
   (
    // Clock out ports
    .clk_out1(clk_1x),     // output clk_out1
    .clk_out2(clk_5x),     // output clk_out2
    // Status and control signals
    .resetn(rst_n), // input resetn
    .locked(),       // output locked
   // Clock in ports
    .clk_in1(clk));      // input clk_in1
//图片切换过渡效果: 运行时4选(淡入淡出/切入/随机线条/溶解), 2s, 由key_menu选择
img_trans u_img_trans(
    .clk            ( clk_1x            ),
    .rst_n          ( hdmi_rst_n        ),
    .vsync          ( vsync_out         ),
    .data_req       ( hdmi_data_req_out ),//缩放器延迟2拍的de(与hdmi_data对齐)
    .data_in        ( hdmi_data         ),
    .data_out       ( trans_data        ),
    .data_out_req   ( trans_req         ),
    .frame_ready    ( frame_ready       ),
    .disp_buf_sel   ( disp_buf_sel      ),
    .media_sel      ( media_sel         ),
    .swap_allow     ( swap_allow        ),
    .effect_sel     ( effect_sel        ),
    .img_w          ( img_w             ), //固定1920
    .x_off          ( geom_x_off        ), //固定0
    .disp_w         ( geom_disp_w       ), //固定1920
    .step_fix       ( geom_step         ), //固定65536
    .rd_off         ( rd_off            ),
    .geom_update    ( geom_update       ),
    .trans_state    (                   )
);
//图像处理: 原图/灰度/边缘/边缘彩色叠加 + 多图层OSD(参数/菜单/中文字幕)
img_process u_img_process(
    .clk            ( clk_1x          ),
    .rst_n          ( hdmi_rst_n      ),
    .data_req       ( trans_req       ),
    .data_in        ( trans_data      ),
    .mode           ( proc_mode       ),
    .img_num        ( img_num         ),
    .img_type       ( img_type        ), //固定BMP=1
    .img_w          ( img_w           ), //固定1920
    .img_h          ( img_h           ), //固定1080
    .menu_show      ( menu_show       ),
    .menu_row       ( menu_row        ),
    .media_sel      ( media_sel        ),
    .vid_fps_t      ( vid_fps_t        ),
    .vid_fps_o      ( vid_fps_o        ),
    .color_sel      ( color_sel       ),
    .effect_sel     ( effect_sel      ),
    .data_out       ( img_proc_data   ),
    .de_out         ( img_proc_de     )
);
hdmi_driver hdmi_driver(
         .clk1x       (clk_1x) ,
         .clk5x       (clk_5x) ,
         .rst_n       (hdmi_rst_n) ,
         //获取数据的接口
         .hdmi_data_req (hdmi_data_req),
         .hdmi_data     (img_proc_data),
         .de_in         (img_proc_de),
         //hdmi输出相关的接口
         .hdmi_tx_clk_n  (hdmi_tx_clk_n  ),
		 .hdmi_tx_clk_p  (hdmi_tx_clk_p  ),
		 .hdmi_tx_chn_r_n(hdmi_tx_chn_r_n),
		 .hdmi_tx_chn_r_p(hdmi_tx_chn_r_p),
		 .hdmi_tx_chn_g_n(hdmi_tx_chn_g_n),
		 .hdmi_tx_chn_g_p(hdmi_tx_chn_g_p),
		 .hdmi_tx_chn_b_n(hdmi_tx_chn_b_n),
		 .hdmi_tx_chn_b_p(hdmi_tx_chn_b_p),
         .vsync_out      (vsync_out)
    );
assign  hdmi_hpd=1'b1;
endmodule
