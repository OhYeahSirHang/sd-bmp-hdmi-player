# build — 可复现构建

## 1. 工具

- Vivado 2022.2
- xc7a35tfgg484-2

## 2. 一键构建

```bat
cd sd_bmp_video320_submission
D:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source build\build.tcl
```

脚本会打开 `build/vivado_project/sd_bmp_hdmi.xpr`，执行：

1. `synth_1`
2. `impl_1`（place Explore + phys opt Explore）
3. `write_bitstream`
4. 重新生成 `build/reports/*.rpt`
5. 复制 bit 到 `build/output/sd_rd_img.bit`

## 3. 目录

```text
build/
├─ build.tcl                  # 构建入口
├─ vivado_project/            # 可移植 XPR + srcs + gen
├─ reports/                   # 本次报告
│  ├─ report_impl_util.rpt
│  ├─ report_impl_timing.rpt
│  ├─ report_hier_util.rpt
│  ├─ report_clock_util.rpt
│  └─ build_summary.md
└─ output/                    # 构建后 bit（运行后生成）
```

## 4. 报告摘要

见 `reports/build_summary.md`。

## 5. 注意

- XPR 使用 `$PSRCDIR` 相对路径；把整个 `vivado_project/` 一起移动即可；
- `.gen` 已随包提供，避免首次打开时重新生成 IP；
- 如果 Vivado 提示 run 文件缺失，`build.tcl` 会重新创建 run 目录；
- 构建时间约 3～5 分钟（机器相关）。
