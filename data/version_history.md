# Desktop 旧版本关系

本提交包以 `C:\Users\15905\Desktop\sd_bmp_video320` 为**唯一规范版本**。  
桌面其他旧版本用于追溯来源，不直接复制进包，避免重复 IP/旧约束造成误构建。

| 目录 | 时间 | 作用（据 README/代码注释） | 与当前关系 |
|---|---|---|---|
| `A7lite_v1_work` | 2026-09-23 | work1：SD 读取链（sd_ctrl/sd_rd/ddr3_rx_buffer） | 被后续合并版复用 |
| `newdemo1018` | 2026-10-18 | 显示/OSD v3 链（ddr3_tx_buffer/img_scaler/img_trans/img_process） | 被 demo-only-1080p 复用 |
| `demo-only-1080p` | 2026-10-21 | 图片-only 1080p 合并版 | 当前工程的图片基础 |
| `newdemo1021` | 2026-10-21 | 后续菜单/OSD 版本 | 菜单/OSD 参考 |
| `sd_bmp_hdmi_v2_video` | 2026-10-21 | 早期视频-only（自适应分辨率） | 视频通路前身 |
| `sd_bmp_video320` | 2026-10-30 | **当前规范版**：320×240@15fps + 17 模式 + 索引表 + 偏移修复 | 本包来源 |

## 为什么只提交当前版本

1. 旧版本的部分 RTL 与当前版本同名但接口不同（`sd_rd`、`vid_player`、`rd_bmp`）；
2. 旧版本 IP/约束可能指向不同引脚或时钟；
3. 当前版本已包含旧版本的图片/显示/视频基础，并完成 15fps、偏移、索引、模式扩展；
4. 提交包只保留一套可构建工程，降低复现失败风险。

## 当前版本相对旧版的关键变化

- `sd_rd`：CMD18 多块 + CMD12 + 25/50MHz 位使能；
- `vid_player`：整帧 CMD18、4-VSYNC、`vid_next_ack`；
- `ddr3_rx_buffer`：媒体/源切换 FIFO flush；
- `img_trans`：媒体切换清 `rd_off`；
- `rd_bmp`：图片索引表；
- `img_process`/`key_menu`：mode 5-bit，17 模式，中值/Canny 近似。
