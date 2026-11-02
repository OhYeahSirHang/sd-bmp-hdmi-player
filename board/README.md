# board — 上板与实测

## 1. 比特流

| 文件 | 说明 |
|---|---|
| `bitstreams/sd_rd_img_median_canny.bit` | 最新：15fps + 偏移修复 + 100MB 索引表 + 中值/Canny |
| `bitstreams/sd_rd_img_offsetfix.bit` | 15fps + 偏移修复（无索引表/中值/Canny） |
| `bitstreams/sd_rd_img_offsetfix_index.bit` | 15fps + 偏移修复 + 索引表（无中值/Canny） |

## 2. 下载

Vivado Hardware Manager：

1. Open Hardware Manager → Open Target → Auto Connect；
2. Tools → Program Device；
3. 选择 bit；
4. Program。

或 Tcl：

```bat
D:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source board\program_bitstream.tcl
```

默认下载 `sd_rd_img_median_canny.bit`，可在脚本顶部 `BIT` 变量改。

## 3. SD 卡

- 测试视频：`data/testvideo/testvideo_320x240_15fps.dv1`；
- 从扇区 0 裸写（WinHex/DD）；
- BMP 可与 DV1 共存；
- 索引表版上电扫描前 100MB，约 17s，期间 LED 闪烁；
- 若卡上没有 DV1，视频模式保持最后一帧、LED 闪烁。

## 4. 操作

| 按键 | 作用 |
|---|---|
| KEY1 短按 | 菜单选中行下移 |
| KEY1 长按 | 菜单显隐 |
| KEY2 短按 | 修改当前行 |
| RESET | 复位 |

菜单 5 行：媒体、图片/视频、模式、颜色、效果。

模式 0..16，含 15 中值、16 Canny 近似。

## 5. 实测

见 `board_test_log.md`。当前记录：

- 修复前：OSD 12fps；视频下一段后回图片右移；最后一张→第一张长时间扫描；媒体切换重读；
- 本次提交：仿真 15fps、偏移修复逻辑、索引表、中值/Canny 已实现；
- 板级最终确认需按 `board_test_log.md` 执行并填写实测列。

## 6. 注意

- 视频改 25MHz 是为匹配 4 行缓冲；换 50MHz/SDIO 前先加 FIFO/源帧缓存；
- Canny 是双阈值近似，不是完整 NMS；
- 索引表切媒体会被复位，会重新 catalog；
- 读帧途中按“下一段”可能被忽略。
