# sd_bmp_video320 — SD 卡图片/视频播放与图像处理 FPGA 工程

基于 **xc7a35tfgg484-2（A7 Lite）** 的 SD 卡只读图片/视频播放器：

- 1080p BMP 图片播放，17 种图像处理模式；
- 320×240 RGB565 @15fps 视频播放，3× 放大居中到 1080p；
- SD 卡 SPI 模式，视频用 **CMD18 多块读 + 25MHz**，图片/探测用 50MHz；
- DDR3 双缓冲，VSYNC 原子换帧；
- OSD 菜单/参数行；
- 图片索引表版本，缓解“最后一张→第一张”长扫描；
- 中值 3×3、Canny 近似模式。

> 本目录是提交包，所有目录/文件名为英文；正文为中文。
> 设计说明见 [report/DESIGN_REPORT.md](report/DESIGN_REPORT.md)；技能包见 [skill/README.md](skill/README.md)。

---

## 1. 快速开始

### 1.1 硬件与工具

| 项 | 值 |
|---|---|
| FPGA | xc7a35tfgg484-2（A7 Lite，DDR3 x16 256MB） |
| 工具 | Vivado 2022.2 |
| 显示 | HDMI 1920×1080@60 |
| SD | SPI 模式；CLK/CMD/DAT0/DAT3 |
| 按键 | KEY1=菜单选行/显隐，KEY2=当前行取值，RESET=复位 |

### 1.2 烧录

```text
board/bitstreams/sd_rd_img_median_canny.bit   # 最新：15fps + 偏移修复 + 索引表 + 中值/Canny
board/bitstreams/sd_rd_img_offsetfix.bit      # 15fps + 偏移修复（无索引表）
board/bitstreams/sd_rd_img_offsetfix_index.bit# 15fps + 偏移修复 + 索引表（无中值/Canny）
```

推荐先烧 `sd_rd_img_median_canny.bit`。

Vivado Hardware Manager 脚本：

```text
board/program_bitstream.tcl
```

或手动：Open Hardware Manager → Open Target → Program Device → 选择 bit。

### 1.3 SD 卡

- 视频文件 `testvideo_320x240_15fps.dv1` 从**扇区 0 裸写**；
- 图片 BMP 可以与 DV1 共存，`rd_bmp` 会逐扇区扫描；
- 索引表版本上电扫描前 100MB，约 17 秒；
- 生成测试视频：`python data/testvideo/gen_dv1.py`。

### 1.4 菜单

| 行 | 标签 | KEY2 |
|---|---|---|
| 0 | 媒体 | 图片 ↔ 视频 |
| 1 | 图片/视频 | 下一张 / 下一段 |
| 2 | 模式 | 17 种循环（0..16） |
| 3 | 颜色 | 字幕颜色 |
| 4 | 效果 | 过渡效果 0..7 |

模式：

```text
0 原图   1 灰度   2 边缘   3 负片   4 黑白
5 红调   6 冷调   7 浮雕   8 色阶   9 线稿
10 锐化  11 模糊  12 复古  13 紫调  14 绿调
15 中值  16 坎尼(Canny 近似)
```

---

## 2. 目录结构

```text
sd_bmp_video320_submission/
├─ README.md                 # 本文件
├─ src/
│  ├─ rtl/                   # 全部 RTL（ddr3/hdmi/new/sd_ctrl/key_debounce）
│  ├─ constrs/top_pin.xdc    # 引脚与时钟约束
│  ├─ ip/                    # XCI/PRJ（clock/ddr3_clock/fifo/mig）
│  └─ README.md              # 模块与时钟域说明
├─ sim/
│  ├─ tb/                    # 通过验证的 testbench
│  ├─ results/               # 本次仿真日志
│  ├─ run_sim.ps1            # 一键仿真
│  └─ README.md
├─ build/
│  ├─ build.tcl              # 可复现构建脚本（打开自带工程）
│  ├─ vivado_project/        # 自带 XPR + srcs + gen，路径可移植
│  ├─ reports/               # 综合/实现/时序/资源报告
│  └─ README.md
├─ board/
│  ├─ bitstreams/            # 3 个 bit
│  ├─ program_bitstream.tcl  # Vivado 下载脚本
│  ├─ board_test_log.md      # 上板测试记录/模板
│  └─ README.md
├─ data/
│  ├─ testvideo/             # DV1 测试视频 + 生成脚本
│  ├─ reference/             # OSD/画面参考图
│  ├─ version_history.md     # 桌面旧版本关系
│  └─ checksums.sha256
├─ report/
│  ├─ DESIGN_REPORT.md       # 设计报告（背景/原理/优化/协作/复现，含大模型协作记录）
│  └─ hardware_block_diagram.png  # 总体架构与硬件连接框图
└─ skill/
   ├─ README.md              # 技能包说明（适用/使用/失效/验证）
   ├─ prompts/               # 提示词工作流
   ├─ templates/             # 工程/报告/TB 模板
   ├─ scripts/               # 时序/资源/仿真/清单校验
   ├─ pitfalls/              # 踩坑清单
   └─ pynq_generic/          # 通用 PYNQ 技能（加分项，非本题绑定）
```

> 目录遵循选题指南 3.3.5.4 推荐结构（README/src/sim/build/board/data/skill/report）。

---

## 3. 复现

### 3.1 构建

```bat
D:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source build\build.tcl
```

脚本会：

1. 打开 `build/vivado_project/sd_bmp_hdmi.xpr`；
2. 综合、实现、写 bit；
3. 重新生成 `build/reports/*.rpt`；
4. 把 bit 复制到 `build/output/sd_rd_img.bit`。

### 3.2 仿真

```powershell
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1
```

预期：

- `tb_fps_15`：`RESULT swaps=17 fps=15`、`PACING_OK`；
- `tb_sd_multi`：CMD18 4 块，2048B，`PASS`；
- `tb_sd_single`：CMD17 单块，512B，`PASS`。

### 3.3 报告

- `build/reports/report_impl_util.rpt`
- `build/reports/report_impl_timing.rpt`
- `build/reports/report_hier_util.rpt`
- `build/reports/build_summary.md`

---

## 4. 已验证结果

| 项 | 结果 |
|---|---|
| 15fps 帧节奏 | 仿真 66.668ms/帧，17 次换帧/1.2s，OSD=15 |
| CMD18 多块 | 4 块 2048B + CMD12，PASS |
| CMD17 单块 | 512B，PASS |
| 综合/实现 | 0 error，0 critical warning |
| LUT | 10,382 / 20,800 = **49.91%** |
| FF | 7,524 / 41,600 = **18.09%** |
| BRAM | 9.5 / 50 = 19% |
| DSP | 3 / 90 |
| WNS | **+0.134ns** |
| WHS | **+0.029ns** |
| WPWS | −0.245ns（OSERDES 固有，9 端点） |

> 上板实测数据见 `board/board_test_log.md`；目前记录的是用户现场观察（修复前 12fps、切换偏移）与本次仿真/实现结果，最终板级确认需按该文件执行。

---

## 5. 已知限制

1. **Canny 是近似版**：Sobel + 双阈值，未做 NMS/完整滞后阈值；完整 Canny 需再加 magnitude line buffer 与 mask 缓冲。
2. **媒体切换仍会重读**：`rd_bmp`/`vid_player` 在切媒体时复位；索引表也会被清掉，切回图片会重新 catalog。要彻底解决需 4 缓冲 + 暂停/恢复。
3. **索引表版上电约 17 秒**：扫描前 100MB；超出 100MB 的图片不在表内。
4. **视频下一段**：读帧途中按键可能被忽略（`sd_busy` 门控），需再按一次。
5. 4 行行缓冲只有约 2.5KB；SD 抖动大时仍可能 underrun，详见设计报告“视频卡顿优化”。

---

## 6. 版本选择

| bit | 适用 |
|---|---|
| `sd_rd_img_median_canny.bit` | 最新综合版，推荐 |
| `sd_rd_img_offsetfix.bit` | 不要索引表/中值/Canny，只要 15fps + 偏移修复 |
| `sd_rd_img_offsetfix_index.bit` | 要索引表，不要中值/Canny |

旧版本关系见 `data/version_history.md`。

---

## 7. 相关文档

- [report/DESIGN_REPORT.md](report/DESIGN_REPORT.md)：选题、框图、软硬件划分、优化对比、大模型协作、技能提炼、复现。
- [src/README.md](src/README.md)：RTL 模块、时钟域、数据格式。
- [build/README.md](build/README.md)：构建与报告。
- [sim/README.md](sim/README.md)：仿真。
- [board/README.md](board/README.md)：上板。
- [skill/README.md](skill/README.md)：技能包。
