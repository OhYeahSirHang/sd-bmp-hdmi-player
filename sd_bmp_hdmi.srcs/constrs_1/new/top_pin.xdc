# ----------------------------------------------------------------------------
#  top_pin.xdc  --  A7 Lite 板卡引脚约束 (与官方 A7_lite.xdc 核对一致)
#  核对日期: 2026.09.16
#  核对结论: 本工程全部引脚 PACKAGE_PIN / IOSTANDARD 与官方硬件资料
#            A7_lite.xdc 完全一致, 无冲突。
#  说明:
#    1. 官方 A7_lite.xdc 中本工程未使用的信号(LED2/UART/EEPROM/ETH)
#       不在此文件约束 -- 顶层无对应端口, 约束未使用端口会导致报错。
#    2. 本文件在官方定义基础上补充: 时钟周期约束 create_clock (50MHz)
#       与未使用引脚上拉 BITSTREAM.CONFIG.UNUSEDPIN PULLUP。
#    3. KEY1(AA1)=key_in 短按菜单选行/长按菜单显隐; KEY2(W1)=key_in2
#       当前行取值循环; RESET(L18)=rst_n 复位。板载三个按键均已启用。
#  2026.10.21 合并版修订:
#    - 删除 v3 中 rd_img(FAT32) 专属的 4 条跨域约束
#      (img_width_out/img_height_out/img_type/img_num 帧级寄存器直连),
#      本工程读取侧改用 work1 的 rd_bmp(顺序扫描固定1080p BMP),
#      img_w/img_h/img_type 为顶层常量, 无该跨域路径。
#    - 其余 v3 CDC 同步链约束(img_num_s1/mode_s1/effect_s1/eff_s1/
#      menu_show_s1/menu_row_s1/color_s1/img_w_s1/img_h_s1/frame_ready_s1/
#      buf_sel_s1/vsync_sync_reg/swap_allow_sync_reg/bl_s1/dh_s1/w_u1/h_u1/
#      rst_s1/rst_s2) 全部保留, 与 img_process/img_trans/img_scaler/
#      ddr3_tx_buffer/rd_bmp 内部同步链通配匹配。
# ----------------------------------------------------------------------------
##############时钟和复位信号##########
create_clock -period 20.00       [get_ports clk]      ;# 50MHz 系统时钟
set_property PACKAGE_PIN J19     [get_ports clk]      ;# 对应官方 CLK_50M
set_property IOSTANDARD LVCMOS33 [get_ports clk]

set_property PACKAGE_PIN L18     [get_ports rst_n]    ;# 对应官方 RESET
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
#############按键输入##########
set_property PACKAGE_PIN  AA1    [get_ports key_in]   ;# 对应官方 KEY1: 短按菜单选行/长按显隐
set_property IOSTANDARD LVCMOS33 [get_ports key_in]

set_property PACKAGE_PIN  W1     [get_ports key_in2]  ;# 对应官方 KEY2: 当前行取值循环
set_property IOSTANDARD LVCMOS33 [get_ports key_in2]
#############LED##########
set_property PACKAGE_PIN  M18    [get_ports find_led] ;# 对应官方 LED1
set_property IOSTANDARD LVCMOS33 [get_ports find_led]
################SD卡(SPI模式)################
# 官方定义: SD_CMD=AA8  SD_DATA0=W9  SD_CLK=U7  SD_DATA3=Y8
# 本工程SPI映射: mosi=CMD  miso=DATA0  cs_n=DATA3
set_property PACKAGE_PIN  W9   [get_ports sd_miso]    ;# 对应官方 SD_DATA0
set_property PACKAGE_PIN  AA8  [get_ports sd_mosi]    ;# 对应官方 SD_CMD
set_property PACKAGE_PIN  U7   [get_ports sd_clk]     ;# 对应官方 SD_CLK
set_property PACKAGE_PIN  Y8   [get_ports sd_cs_n]    ;# 对应官方 SD_DATA3

set_property IOSTANDARD LVCMOS33  [get_ports sd_miso]
set_property IOSTANDARD LVCMOS33  [get_ports sd_mosi]
set_property IOSTANDARD LVCMOS33  [get_ports sd_clk]
set_property IOSTANDARD LVCMOS33  [get_ports sd_cs_n]
####################HDMI显示信号########################
# 官方定义: HDMI1_CLK_P=L19  HDMI1_D0_P=K21  HDMI1_D1_P=J20  HDMI1_D2_P=G17
# 本工程映射: D0=蓝  D1=绿  D2=红
set_property PACKAGE_PIN L19 [get_ports hdmi_tx_clk_p]  ;# 对应官方 HDMI1_CLK_P
set_property PACKAGE_PIN K21 [get_ports hdmi_tx_chn_b_p];# 对应官方 HDMI1_D0_P
set_property PACKAGE_PIN J20 [get_ports hdmi_tx_chn_g_p];# 对应官方 HDMI1_D1_P
set_property PACKAGE_PIN G17 [get_ports hdmi_tx_chn_r_p];# 对应官方 HDMI1_D2_P

set_property IOSTANDARD TMDS_33 [get_ports hdmi_tx_clk_p]
set_property IOSTANDARD TMDS_33 [get_ports hdmi_tx_chn_b_p]
set_property IOSTANDARD TMDS_33 [get_ports hdmi_tx_chn_g_p]
set_property IOSTANDARD TMDS_33 [get_ports hdmi_tx_chn_r_p]

set_property PACKAGE_PIN H15     [get_ports hdmi_hpd]   ;# 对应官方 HDMI1_HPD_CON
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_hpd]
##################将使用的引脚拉高##########################
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]

################## v3 跨时钟域(CDC)2级同步路径 ##################
# 以下信号均为慢速控制/状态信号, 经2级同步寄存器进入目标时钟域,
# 同步器无需时序收敛(标准做法), 从源时钟寄存器到第1级同步寄存器的路径置为false:
#   148.5M -> ui_clk : band_line/disp_h/img_w_lat/src_h/g_h(缩放行映射)
#   148.5M -> ui_clk : first_done(复位同步链入口)
#   148.5M -> 50M    : vsync/swap_allow(读图控制, rd_bmp)
#   50M    -> 148.5M : img_num/img_w/img_h(按键/图号/几何)
#   50M    -> 148.5M : menu_show/menu_row/color_sel/effect_sel(菜单/字幕/效果)
#   50M    -> 148.5M : frame_ready/buf_sel/eff(过渡握手与效果选择)
set_false_path -to [get_cells -hier -filter {NAME =~ */bl_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */dh_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */w_u1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */h_u1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */rst_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */vsync_sync_reg[0]*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */swap_allow_sync_reg[0]*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */img_num_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */mode_s1*}]
# v3 新增: 图片类型/宽高/菜单/颜色/效果 同步链
set_false_path -to [get_cells -hier -filter {NAME =~ */img_type_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */img_w_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */img_h_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */menu_show_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */menu_row_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */color_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */effect_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */frame_ready_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */buf_sel_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ */eff_s1*}]
# 复位同步链第二级(phys-opt可能合并为SRL)
set_false_path -to [get_cells -hier -filter {NAME =~ */rst_s2*}]

# ------------------------------------------------------------------
# video path (vid_player): 148.5M vsync -> 50M 2FF sync (CDC)
# ------------------------------------------------------------------
set_false_path -to [get_cells -hier -filter {NAME =~ *u_vid_player/vs_d1*}]

set_false_path -to [get_cells -hier -filter {NAME =~ *u_img_process/media_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_img_trans/media_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_img_trans/media_s2*}]

# 2026-10-28 视频实测 fps / 媒体切换同步 (50M -> 148.5M / ui_clk)
set_false_path -to [get_cells -hier -filter {NAME =~ *u_img_process/ft_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_img_process/fo_s1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_ddr3_rx_buffer/tog_u1*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *tog_u1*}]
