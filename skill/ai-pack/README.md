# ai-pack — 可安装的 AI 技能：`fpga-bringup-debug`

> 这不是"本项目说明"，而是一个**可被任意 AI 助手加载的技能**：
> 换板卡、换题目、换模型都能用；面向的是"现象模糊、证据不可信"这类失败模式。

- 入口文件：[`SKILL.md`](SKILL.md)（YAML frontmatter + 正文，Claude/Agent Skill 通用格式）
- 安装位置：`~/.dsh/skills/fpga-bringup-debug/`（已安装一份）
- 也可直接把它当**人读的工作手册**：从 `SKILL.md` 的 §2 主循环开始读。

---

## 1. 五分钟上手

```text
① 读 SKILL.md §0（一条原则）+ §2（S0→S5）+ §3（十条硬规则）
② 拿到现象：先跑 §2 的 S0 基线（快照 + 副本 + 版本三元组）
③ 填 references/timing-budget.md §6 的预算表
④ 查 references/symptom-playbook.md 对应条目，列 3 条假设
⑤ 用 scripts/ 的五道门做客观判定，再动手
```

**最小可用集**（时间只够看三样）：

1. `SKILL.md` §2 主循环；
2. `references/symptom-playbook.md` 对应症状那一节；
3. `references/pitfalls.md` 的速查表。

---

## 2. 目录与职责

| 文件 | 职责 | 何时读 |
|---|---|---|
| `SKILL.md` | 入口：原则、循环、硬规则、症状路由、五道门 | 每次开工 |
| `references/timing-budget.md` | 帧/行/带宽/容量/量化台阶的算式 | 任何"多快/多大/够不够" |
| `references/symptom-playbook.md` | 10 类症状 → 假设 → 证据 → 修复 | 拿到现象第一站 |
| `references/cdc-and-signoff.md` | CDC 分类、`false_path` 范围、WPWS 例外 | 偶发错位 / 时序不收敛 |
| `references/verification-charter.md` | 只读验证五条、分阶段 TB、日志三问、覆盖矩阵 | 要"证明"而非"觉得" |
| `references/pitfalls.md` | 28 条踩坑（触发→现象→根因→排查→对策） | 动手前扫一遍 |
| `references/prompt-library.md` | 10 个可直接复制的提示词（中/英） | 不知道怎么问清楚时 |
| `scripts/check_timing.py` | G3：WNS/WHS 判定，WPWS 单列 | 实现后 |
| `scripts/check_util.py` | G4：LUT/FF/BRAM/DSP 阈值 | 实现后 |
| `scripts/check_sim_logs.py` | G2：日志证据表，容差型 PASS 告警 | 仿真后 |
| `scripts/rtl_const_check.py` | G1：常量截断 / 占位逻辑 / 未用输入 | 读代码时 |
| `scripts/verify_manifest.py` | G5：SHA256 快照与比对 | 只读验证 / 交付 |
| `assets/tb_template.v` | 带 watchdog 与结构化 `RESULT` 的 TB 骨架 | 新 TB |
| `assets/run_xsim.ps1` | 一键仿真，三段日志分别落盘 | 新工程 |
| `assets/build_run_flow.tcl` | 批量构建 + 出报告 | 新工程 |
| `assets/report_template.md` | 7 节报告模板（含失效条件） | 写报告 |
| `examples/case-video320.md` | 完整案例：12→15fps、整块偏移、CDC −4.7ns | 想看清循环怎么跑 |

---

## 3. 五道门怎么跑

```powershell
$py = "python"   # 或你的解释器
$p  = "skill\ai-pack\scripts"

# G1 静态
& $py "$p\rtl_const_check.py" --root src\rtl

# G2 仿真证据
& $py "$p\check_sim_logs.py" --root sim\results --md evidence.md

# G3 时序
& $py "$p\check_timing.py" build\reports\report_impl_timing.rpt

# G4 资源
& $py "$p\check_util.py" build\reports\report_impl_util.rpt

# G5 只读验证 / 交付
& $py "$p\verify_manifest.py" --root . --save baseline.json
& $py "$p\verify_manifest.py" --root . --check baseline.json
```

退出码统一：`0 = 通过`、`1 = 不通过`、`2 = 解析失败`。可直接接 CI。

---

## 4. 验证记录（不是"设计好了"，是"跑过了"）

用本仓库的真实产物实跑（Windows 10 + Python 3.13 + Vivado 2022.2 报告）：

| 脚本 | 输入 | 结果 |
|---|---|---|
| `check_timing.py` | `build/reports/report_impl_timing.rpt` | `WNS=+0.134 WHS=+0.029 WPWS=−0.245 (9 endpoints)` → **PASS**，并正确提示 WPWS 需人工归因 |
| `check_util.py` | `build/reports/report_impl_util.rpt` | LUT 49.91% / FF 18.09% / BRAM 19.00% / DSP 3.33% → **PASS** |
| `check_sim_logs.py` | `sim/results/*.log` | 3 份日志全部 PASS，抓到 `RESULT swaps=17 fps=15` + `PACING_OK` |
| `rtl_const_check.py` | `src/rtl/`（27 个文件） | 命中 1 处 `V2`：`new/key_menu.v:70` 的 `key1_down && 1'b0` 恒 0 占位 |
| `verify_manifest.py` | `data/checksums.sha256` | 首次运行命中 1 处路径缺口（`skill/SESSION_SUMMARY.md` 实际在 `skill/1/` 下）；**已修正清单并重生成，现 110 条 changed=0 missing=0** |

> 最后两行是"技能真的能发现问题"的证据：前者是交付包里遗留的死代码，
> 后者是校验清单的路径缺口——都是人工容易漏、脚本一次就抓到的。
> 二者均已在本轮交付中修正/记录。

---

## 5. 来源：每条经验对应哪次失败

| 失败/观察 | 沉淀到 |
|---|---|
| 12 fps 被当成"计数器写错" | `timing-budget.md` §2 量化台阶、`SKILL.md` §0 |
| 300 次 CMD17 导致每帧超时 | `timing-budget.md` §3、`symptom-playbook.md` §1 |
| 切媒体后整块右移（三处根因并存） | `symptom-playbook.md` §2、`pitfalls.md` P17–P19 |
| 加 CDC 同步器后 WNS −4.7，被整片 `false_path` 掩盖 | `cdc-and-signoff.md` §2、P27 |
| 索引表 32MB 只找到 2 张 | `timing-budget.md` §5 反推、P21 |
| 一份"四阶段 PASS"实际来自改过的源码 | `verification-charter.md` §3、P02/P03 |
| `localparam [24:0] = 50_000_000` 截断成 0.329s | `pitfalls.md` P01 |
| 只留 `_xsim.txt`，无法回答"日志是不是当前源码" | P11 |
| PowerShell 执行策略被误判为"没权限" | P26 |
| 4 行行缓冲撑不住 SD 抖动 | `timing-budget.md` §4.2、P24 |

---

## 6. 边界（什么时候这套东西不适用）

- **不是通用 debug 教程**：假定"能下载、有时钟、有复位"，不覆盖供电/下载链/器件选型；
- **不是某个厂商的教程**：脚本按 Vivado 报告格式写，Quartus/Gowin 需改解析（方法不变）；
- **不做自动修复**：所有脚本只判定与定位，改哪一行必须人来定；
- **不替代读代码**：静态规则是"把可疑点摆上桌"，误报率不为零（`V3` 尤其）；
- **不做仿真器**：`check_sim_logs.py` 只读日志，不产生激励。

---

## 7. 安装 / 卸载

```powershell
# 安装（用户级，任何项目都可见）
Copy-Item -Recurse skill\ai-pack "$env:USERPROFILE\.dsh\skills\fpga-bringup-debug" -Force

# 仅当前项目可见
Copy-Item -Recurse skill\ai-pack "<项目>\.dsh\skills\fpga-bringup-debug" -Force

# 卸载
Remove-Item -Recurse "$env:USERPROFILE\.dsh\skills\fpga-bringup-debug"
```

技能发现规则（DSH）：项目级 `.dsh/skills` 优先于用户级 `~/.dsh/skills`；
每个技能目录必须含 `SKILL.md`，frontmatter 的 `name` 与目录名一致。
