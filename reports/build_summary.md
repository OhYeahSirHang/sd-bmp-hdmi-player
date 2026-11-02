# Build Summary

## Release bit（提交的 bit 对应）

| 项 | 值 |
|---|---|
| Tool | Vivado 2022.2 |
| Part | xc7a35tfgg484-2 |
| Top | sd_rd_img |
| Design state | Routed |
| Bitstream | `board/bitstreams/sd_rd_img_median_canny.bit` |
| LUT | 10,382 / 20,800 = 49.91% |
| LUT as Logic | 8,405 = 40.41% |
| LUT as Memory | 1,977 = 20.59% |
| FF | 7,524 / 41,600 = 18.09% |
| BRAM | 9.5 / 50 = 19.00% |
| DSP | 3 / 90 = 3.33% |
| MMCM / PLL | 3 / 1 |
| BUFG | 8 / 32 |
| WNS | +0.134 ns |
| WHS | +0.029 ns |
| WPWS | −0.245 ns（9 端点，OSERDES 固有） |
| Failing setup/hold | 0 / 0 |
| Errors / Critical warnings | 0 / 0 |

## Clean-room rebuild（`build/build.tcl` 在提交包内重新跑）

| 项 | 值 |
|---|---|
| LUT | 10,382 / 20,800 = 49.91% |
| FF | 7,524 / 41,600 = 18.09% |
| BRAM | 9.5 / 50 |
| DSP | 3 / 90 |
| WNS | +0.134 ns |
| WHS | +0.029 ns |
| Failing setup/hold | 0 / 0 |
| Errors / Critical warnings | 0 / 0 |

> release 与 clean-room rebuild 的时序基本一致（+0.134/+0.029），资源完全相同；两者均通过。
>
> - 主报告：release 构建；
> - `reports/rebuild/`：干净重建。

## Design notes

- 视频 CMD18 300 块 + 25MHz SPI；
- 4 个 VSYNC 节流 15fps；
- 偏移修复（FIFO flush、`img_trans` reset、`vid_next_ack`）；
- 100MB 图片索引表；
- 中值 3×3、Canny 近似；
- Canny 未做 NMS/完整滞后阈值。

## Report files

- `report_impl_util.rpt`
- `report_impl_timing.rpt`
- `report_hier_util.rpt`
- `report_clock_util.rpt`
- `rebuild/report_impl_util.rpt`
- `rebuild/report_impl_timing.rpt`
- `rebuild/report_hier_util.rpt`
- `rebuild/report_clock_util.rpt`
