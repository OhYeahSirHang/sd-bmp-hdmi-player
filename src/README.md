# src — RTL 与约束

## 1. 目录

```text
src/
├─ rtl/
│  ├─ ddr3/          DDR3 读写/仲裁/行缓冲/缩放
│  ├─ hdmi/          HDMI 时序/编码/并串
│  ├─ new/           BMP/视频/OSD/菜单
│  ├─ sd_ctrl/       SD SPI 初始化/读写
│  └─ key_debounce/  按键去抖
├─ constrs/
│  └─ top_pin.xdc    引脚、时钟、CDC false path
└─ ip/               XCI/PRJ
```

## 2. 顶层与模块

顶层：`rtl/new/sd_rd_img.v`

| 模块 | 说明 |
|---|---|
| `sd_ctrl` / `sd_init` / `sd_rd` | SPI 模式 SD；视频 CMD18 25MHz，图片/探测 CMD17 50MHz |
| `rd_bmp` | 逐扇区找 BMP；索引表版本 catalog 100MB |
| `vid_player` | DV1、CMD18 300 块、4 行缓冲、1080p 生成、4-VSYNC |
| `ddr3_ctrl`/`ddr3_arbit`/`ddr3_wr_ctrl`/`ddr3_rd_ctrl` | MIG 用户接口 |
| `ddr3_rx_buffer` | 16→128bit、双缓冲、FIFO flush |
| `ddr3_tx_buffer`/`img_scaler` | 读 DDR3、行缓冲、缩放、`rd_off` |
| `img_trans` | 8 种过渡、媒体切换复位 |
| `img_process` | 17 种模式、OSD、中值/Canny |
| `key_menu` | 5 行菜单、5-bit mode |
| `hdmi_driver`/`hdmi_trans`/`encode`/`parallel_serial` | HDMI 1080p60 |

## 3. 时钟域

| 时钟 | 频率 | 说明 |
|---|---:|---|
| `clk` | 50MHz | 系统/SD/按键/写侧像素 |
| `ui_clk` | 100MHz | MIG 用户接口 |
| `clk_out1` | 148.5MHz | HDMI 像素/OSD/处理 |
| `clk_5x` | 742.5MHz | OSERDES |

CDC：

- `vsync`：148.5M→50M 2FF；
- `frame_sync`：50M→100M toggle；
- `media_sel`：50M→148.5M 2FF（`img_trans`）；
- 同步器入口在 `top_pin.xdc` 加 `false_path`。

## 4. 模式

`mode` 5-bit，0..16：

```text
0 原图 1 灰度 2 边缘 3 负片 4 黑白
5 红调 6 冷调 7 浮雕 8 色阶 9 线稿
10 锐化 11 模糊 12 复古 13 紫调 14 绿调
15 中值 16 Canny 近似
```

## 5. DV1 格式

```text
0 'D''V''1' 0x00
4-5 W(LE,320)
6-7 H(LE,240)
8 fps
9 fmt(0=RGB565)
10-13 frame_bytes(LE,153600)
14-17 frame_count(LE)
18-63 保留
扇区1起：每帧300扇区，像素高字节在前
```

## 6. 修改注意

- 改 `mode` 宽度要同步 `key_menu`、`img_process`、`m_mode_val`、OSD 字库；
- 改视频时钟要同时看 4 行缓冲/FIFO 是否会被冲垮；
- 改 CDC 要补 `top_pin.xdc` false path，否则 WNS 可能大幅负；
- 行缓冲 `ram_style="block"` 只是提示，实际可能落 LUTRAM。
