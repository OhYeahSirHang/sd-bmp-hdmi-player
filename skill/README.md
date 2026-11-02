# skill — 可复用技能包

本目录把本项目 FPGA 上板调试与交付中沉淀的经验显式化，按赛方选题指南 **3.3.5.2** 要求组织为**四类内容**：提示词工作流、案例模板、校验脚本、踩坑清单。每个技能条目均写明**适用场景、使用方法、失效条件、已验证效果、来源失败**。评价标准：**陌生队伍能否直接复用**——只看本 README，能否在 30 分钟内上手并对自己的工程跑出同样的验证。

## 1. 目录总览

```text
skill/
├─ README.md            ← 本文件：赛方口径四类索引与验证记录
├─ ai-pack/             ← 完整技能包（含技能入口 SKILL.md，可独立安装，见其内部 README）
│  ├─ SKILL.md          技能入口：S0→S5 主循环、十条硬规则、症状路由表、五道判定门
│  ├─ references/       6 份知识库：
│  │  ├─ timing-budget.md          时间/带宽/容量/量化台阶算式
│  │  ├─ symptom-playbook.md       症状→假设→证据→修复（10 症状）
│  │  ├─ cdc-and-signoff.md        CDC 检查表与时序收敛
│  │  ├─ verification-charter.md   只读验证/分阶段 TB/日志审计
│  │  ├─ pitfalls.md               踩坑清单 28 条（P01–P28）
│  │  └─ prompt-library.md         提问模板 10 条（中/英双语）
│  ├─ scripts/          5 个判定门脚本（G1~G5，退出码统一 0/1/2）
│  ├─ assets/           4 个模板（TB/仿真/构建/报告）
│  └─ examples/         完整案例 case-video320.md（12→15fps、整块偏移、CDC −4.7ns、索引截断）
└─ pynq_generic/        ← 加分项：PYNQ overlay/DMA/MMIO 通用模板（模板级）
```

## 2. 四类内容索引

### 2.1 提示词工作流（已验证可稳定完成任务的提问模板）

| 技能 | 适用场景 | 使用方法 | 失效条件 | 已验证效果 | 来源失败 |
|---|---|---|---|---|---|
| `ai-pack/references/prompt-library.md`（10 条，中英双语） | 现象模糊、预算不清、CDC 疑虑、验证不可信 | 按 P01~P10 复制提问模板；先让模型读 RTL/报告再作答，答完按模板内"怎么验"核对 | 无 RTL/报告可读、纯理论题 | 12→15fps、整块偏移、索引截断、CDC −4.7ns 均一次定位 | 见每条"来源"；最初直接猜"计数器错"被帧预算纠正 |
| `ai-pack/references/symptom-playbook.md`（10 症状） | 拿到具体症状：帧率/偏移/撕裂/花屏/点阵/OSD 错位 | 症状 → 假设 → 证据 → 修复四步对照，配合预算算式 | 硬件不启动、供电/下载链问题 | 本工程 8 类症状全部对号入座 | 每次跳过预算直接改 RTL 的失败轮次 |

### 2.2 案例模板（可直接套用的工程骨架）

| 模板 | 适用场景 | 使用方法 | 失效条件 | 已验证效果 |
|---|---|---|---|---|
| `ai-pack/assets/tb_template.v` | 模块级验证起步 | 复制后填 DUT 与断言；自带 watchdog、单调性断言、结构化 `RESULT` 输出 | 纯组合逻辑可简化 | 15fps 帧间隔、CMD18 多块、CMD17 单块均 PASS |
| `ai-pack/assets/run_xsim.ps1` | 一键三段日志仿真 | 改 `$VivadoBin` 路径后运行；xvlog/xelab/xsim 分段落盘 | 无 Vivado 或版本路径不同需改 | `sim/results/` 3 份日志全部 PASS |
| `ai-pack/assets/build_run_flow.tcl` | 综合/实现/报告骨架 | 用 `run` 流程（保留 IP 的 XDC），非 in-memory；改工程名与器件 | IP 有特殊生成步骤需补 | 提交包 `build/reports/` 两份 rpt 由此产出 |
| `ai-pack/assets/report_template.md` | 调试/交付报告 | 按 现象→预算→假设→改动→验证→失效条件 7 节填写 | 赛道有固定模板时以赛道为准 | 本仓库 `report/DESIGN_REPORT.md` 第 4/5/6 节按此结构 |

### 2.3 校验脚本（自动判定，退出码统一 0/1/2）

| 脚本（门） | 用途 | 使用方法 | 失效条件 |
|---|---|---|---|
| `scripts/rtl_const_check.py`（G1 静态门） | 常量位宽截断 / 恒 0 恒 1 占位 / 未用输入 | `python rtl_const_check.py --root src/rtl` | 纯正则扫描，不理解宏/ifdef/generate，结论需人工复核 |
| `scripts/check_sim_logs.py`（G2 仿真门） | 结构化 RESULT 统计、FAIL/ERROR 审计、"无结论≠通过" | `python check_sim_logs.py --root sim/results` | 日志无 `RESULT`/`PASS` 字样时判 NO-RESULT（有意为之） |
| `scripts/check_timing.py`（G3 时序门） | WNS/WHS ≥ 阈值、违例端点计数；WPWS 单独报告不参与判定 | `python check_timing.py build/reports/report_impl_timing.rpt` | 只认 Design Timing Summary 表；多时钟分组需人工 |
| `scripts/check_util.py`（G4 资源门） | LUT/FF/BRAM/DSP 占用率对阈值 | `python check_util.py build/reports/report_impl_util.rpt` | 器件不同需改阈值；只看顶层合计行 |
| `scripts/verify_manifest.py`（G5 交付门） | SHA256 快照/比对、sha256sum 清单校验 | `python verify_manifest.py --root <proj> --manifest data/checksums.sha256` | 只证明"内容没变"，不证明"原本就正确" |

### 2.4 踩坑清单（含触发条件与排查步骤）

`ai-pack/references/pitfalls.md`：**28 条**（P01–P28），按五组分类：

- **A 语言与声明**：常量位宽静默截断、`localparam` 无法被 TB 覆盖、位宽改动即行为改动、死代码/占位线、有符号/无符号混用；
- **B 验证方法**：二值断言掩盖方向性错误、只读最后一行 RESULT、模块级 PASS ≠ 整机可用、产物陈旧、素材太小覆盖率虚高、只留一段日志；
- **C 设计与集成**：多 bit 跨域直接打两拍、硬编码分辨率、3×3 窗口边界缺失、跨域复位不同步、双缓冲换页未对齐 VSYNC、换源时 FIFO 未 flush、偏移量残留、"发出切换"≠"对方接受"、`ram_style` 未生效；
- **D 存储与素材**：索引表范围 < 扫描范围、文件未从扇区 0 裸写、帧长非 512 整数倍、行缓冲撑不住源端抖动、BGR/RGB 顺序；
- **E 环境与流程**：PowerShell 执行策略被误判、`false_path` 盖住整条跨域路径、WHS 余量过小。

每条含**触发条件、现象、根因、排查步骤、对策**；标【实测】的 22 条来自本工程真实失败，标【通用】的 6 条为行业通用经验。文末附"症状 → 条目"速查表。

## 3. 技能入口与主循环

`ai-pack/SKILL.md`（`name: fpga-bringup-debug`）是技能入口，解决一类失败模式：现象模糊、证据不可信、改动互相污染、报告与事实脱节。核心是 **S0→S5 主循环**：

```text
S0 基线（哈希快照+版本三元组） → S1 预算（时间/带宽/容量/量化台阶）
→ S2 假设（可证伪，能解释最多现象者优先） → S3 实验（一次一个变量，成本从低到高）
→ S4 修复（最小改动+双版本+回归） → S5 沉淀（报告+失效条件）
```

另有**十条硬规则**（原件只读、先算后猜、声明即行为、日志三段齐全、判据带数值与比较符、产物标版本、一次一个变量、跨域单独审、失败要回退、报告写失效条件）与**症状路由表**（12 类症状 → 第一嫌疑 → 先看哪里 → 详见哪份参考）。

## 4. 五道判定门与本仓库验证记录

上板/交付前逐门过，任何一门不过不许说"完成"。以下为本技能包在**本仓库（sd_bmp_video320_submission）真实产物**上的验证记录：

| 门 | 判据 | 工具 | 本仓库实测结果 |
|---|---|---|---|
| G1 静态门 | 无常量截断 / 无恒 0 恒 1 占位 / 无未用输入 | `rtl_const_check.py` | 扫 `src/rtl/` 27 文件：命中 1 处 V2（`new/key_menu.v:70` `key1_long = key1_down && 1'b0` 恒 0 占位）→ **FAIL，记录为待修复项**，其余 26 文件干净 |
| G2 仿真门 | 每条 TB 有结构化 RESULT，FAIL/ERROR=0 | `check_sim_logs.py` | `sim/results/` 3 份日志全 PASS：`swaps=17 fps=15`、CMD18 多块 2048B、CMD17 单块 512B，fail_lines=0 |
| G3 时序门 | WNS ≥ 0 且 WHS ≥ 0，违例端点已归类 | `check_timing.py` | WNS **+0.134ns**（failing 0/34165）、WHS **+0.029ns**（failing 0/34149）；WPWS −0.245ns（failing 9/10152，OSERDES 固有相位，已知项不参与判定）→ PASS |
| G4 资源门 | LUT/FF/BRAM/DSP 在预算内 | `check_util.py` | LUT **49.91%**（10,382/20,800）、FF **18.09%**（7,524/41,600）、BRAM **19.00%**（9.5/50）、DSP **3.33%**（3/90）→ PASS |
| G5 交付门 | 原件哈希未变；bit 与 RTL 版本对应 | `verify_manifest.py` | 旧清单 `data/checksums.sha256` 比对：changed=2（README.md、board/board_test_log.md 为后续更新）、missing=13（旧 skill/ 四类目录本轮重组移除 + 清单路径需重生成）→ 定稿后重新生成清单并通过，见 §5 |

> G1 发现说明：`key1_long`（长按）恒 0 占位是调试残留，工具链不报错、上板不体现，属于"功能未实现"而非缺陷，已记录为待办；修法是把表达式补成真实长按逻辑或删除该线并写入未实现清单。

## 5. 清单重新生成（随定稿更新）

`data/checksums.sha256` 已按定稿后提交包现状重新生成（`verify_manifest.py --root <提交包> --manifest data/checksums.sha256` 复核通过）。此后任何文件改动都会使 G5 失效，改完需重新生成清单。

## 6. PYNQ 加分项

`pynq_generic/`：PYNQ overlay 加载 / MMIO 读写 / DMA 回环 / ILA 触发检查的通用模板（`overlay_template.py`、`prompts.md`、`pitfalls.md`、`README.md`）。适用 PYNQ-Z2/Gen3 等带 PS + PL 的板卡；本项目为纯 RTL 未使用，**验证状态：模板级**，供换平台时按需套用。

## 7. 复用方法（陌生队伍 30 分钟上手）

1. 现象对表：先看 `references/pitfalls.md` 文末速查表 + `symptom-playbook.md`，把症状落到条目；
2. 提问：从 `prompt-library.md` 复制对应提问模板，附上自己的 RTL/报告；
3. 预算：按 `timing-budget.md` 算出时间/带宽/容量 4 个数字，确认现象"对得上号"再动手；
4. 门槛：跑五道门脚本，任何一门不过就回到 S1/S2，不许说"完成"；
5. 起步：新工程从 `assets/` 复制 TB/仿真/构建/报告骨架，参照 `examples/case-video320.md` 的完整循环。

## 8. 边界

- 脚本按 Vivado 报告格式解析（本仓库以 Vivado 2022.2 报告验证），换版本/厂商需调整解析正则与阈值；
- 资源/时序结论基于 xc7a35t（Artix-7），换器件需重新预算；
- PYNQ 模板未在本项目上板验证；
- 技能包不替代具体板卡的时序约束与工程特有流程。
