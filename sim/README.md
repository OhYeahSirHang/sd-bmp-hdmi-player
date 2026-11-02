# sim — 仿真与验证

## 1. Testbench

| TB | 验证内容 | 预期 |
|---|---|---|
| `tb/tb_fps_15.v` | `vid_player` + 60Hz VSYNC + 25MHz 读模型 | 66.668ms/帧，17 次换帧/1.2s，OSD=15 |
| `tb/tb_sd_multi.v` | `sd_rd` CMD18 多块 + CMD12 | 4 块 2048B，PASS |
| `tb/tb_sd_single.v` | `sd_rd` CMD17 单块 | 512B，PASS |

## 2. 一键运行

```powershell
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1
```

脚本默认使用：

```text
D:\Xilinx\Vivado\2022.2\bin
```

如路径不同，修改 `run_sim.ps1` 顶部 `$VivadoBin`。

结果写入 `sim/results/*.log`。

## 3. 手动运行示例

```bat
cd sim\work
D:\Xilinx\Vivado\2022.2\bin\xvlog.bat ..\..\src\rtl\new\vid_player.v ..\tb\tb_fps_15.v
D:\Xilinx\Vivado\2022.2\bin\xelab.bat -debug typical tb_fps_15 -s tb_fps_15
D:\Xilinx\Vivado\2022.2\bin\xsim.bat tb_fps_15 -runall
```

## 4. 本次结果

见 `results/`：

- `fps15_result.log`：`RESULT swaps=17 fps=15`、`PACING_OK`；
- `sd_multi_result.log`：`RESULT ndone=1 bytes=2048 state=0`、`PASS`；
- `sd_single_result.log`：`RESULT ndone=1 bytes=512 state=0`、`PASS`。

> 仿真不是板级实测；上板请按 `board/board_test_log.md`。
