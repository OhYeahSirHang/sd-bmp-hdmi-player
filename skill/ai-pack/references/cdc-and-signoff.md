# 跨时钟域与时序收敛

> 原则：**功能正确性优先于时序数字**。先让设计在仿真里对，再让它在时序上收敛。
> 反过来做（靠约束把违例盖掉）会让 bug 变成"偶发"。

---

## 1. 跨域分类（先分类，再谈修法）

| 类型 | 例子 | 允许的做法 | 禁止 |
|---|---|---|---|
| 单 bit 控制 | `vsync`、`media_sel`、使能脉冲 | 两级同步 + 边沿检测 | 直接当数据用 |
| 多 bit 数据 | `img_w[11:0]`、`x_off[10:0]`、几何参数 | 握手 / 异步 FIFO / "数据稳定 + 单 bit 有效" | 直接打两拍 |
| 计数器/状态 | 写指针、帧计数 | 格雷码 + 同步，或异步 FIFO | 二进制直接同步 |
| 复位 | 跨域复位释放 | 复位同步器（异步置位、同步释放） | 异步撤除 |
| 时钟 | MMCM/PLL 输出 | 同一 MMCM 的输出视为相关时钟 | 假设异步而乱加 `false_path` |

判据：**多 bit 打两拍 = 一定会在某个时刻给出一个源端从未出现过的组合值**。
仿真里几乎抓不到，板子上表现为"偶发几何错位"。这条没有任何例外。

---

## 2. `false_path` 加在哪一层（真实 −4.7 ns 案例）

**现象**：加了一个跨域同步器（`media_sel` 从 50 MHz 进 148.5 MHz）之后，
WNS 从正变 **−4.7 ns**，报告的第一条违例路径起点是 50 MHz 域寄存器、
终点是 148.5 MHz 域的**同步器第一级**。

**根因**：静态时序分析把"同步器入口"当成普通同步路径来检查。
这条路径物理上本来就不需要满足建立时间（亚稳态由同步器吸收）。

**正确做法**：

```tcl
# 只约束同步器入口，不盖住整条路径
set_false_path -from [get_cells u_img_trans/media_s1_reg*] -to [get_cells u_img_trans/media_s2_reg*]
```

**错误做法**：

- `set_false_path -from [all_registers -clock clk_50m] -to [all_registers -clock clk_148m5]`
  —— 把真正的跨域数据路径也一起豁免了，bug 被藏起来；
- 对整个模块 `set_clock_groups -asynchronous` —— 同上，范围过大。

**判据**：加完约束，`report_timing` 里那条路径应当**消失**，而不是"数字变好"。
如果只是数字变好、路径还在，说明约束没生效或加错了对象。

---

## 3. WNS 只差 0.1~0.5 ns 怎么办

不要先动 RTL。按这个顺序：

1. **看违例路径的起点类型**：如果是 `RAMB/DSP/OSERDES` 的输出，多半是布线拥塞或单元位置；
2. **看逻辑级数**：`report_timing -max_paths 20`，级数 > 12 的组合路径优先打拍；
3. **看扇出**：单信号扇出 > 500 时插复制寄存器（`max_fanout` 或手动复制）；
4. **看时钟不确定性**：确认 `create_clock` 的抖动/不确定性设置是否过紧（不要靠放松约束"修"）；
5. 最后才换综合/实现策略（`-directive Explore` / `phys_opt_design -directive AggressiveExplore`）。

> 案例：某轮 `route_design` + `phys_opt_design AggressiveFanoutOpt` 之后 WNS 仍为负，
> 换成 `Explore` + `AggressiveExplore` 才收敛。这类"策略轮换"应作为**最后手段**并记录，
> 因为它不可解释、换工具版本会失效。

---

## 4. WPWS 为负但 WNS/WHS 为正

Vivado 会打印 `Timing constraints are not met.`，但三个数里只有 WPWS 负。

**先分类，别急着重构**：

| 违例端点集中在 | 结论 | 处理 |
|---|---|---|
| OSERDES / `selectio_wiz` / 输出 SERDES | 串行化时钟与并行时钟的固有相位关系 | 记录为已知项，写进报告 |
| MMCM 的 `CLKOUT*` 之间 | 相位约束本身较紧 | 确认 `create_generated_clock` 相位设置 |
| 普通逻辑 | 真问题（可能是时钟改相/占空比） | 按 §3 处理 |

判据：**违例端点数量很少（个位数）且全部集中在 SERDES** ⇒ 已知项；
数量大、分布散 ⇒ 真违例。

---

## 5. 约束审查清单（每次 signoff 过一遍）

- [ ] 每个时钟都有 `create_clock`，频率与板上晶振一致；
- [ ] MMCM/PLL 输出用 `create_generated_clock`（或自动派生），没有手动重复定义；
- [ ] 所有输入/输出都有 `set_input_delay` / `set_output_delay`（或明确声明为 `false_path`）；
- [ ] 每个同步器入口有 `false_path`（且只到入口）；
- [ ] 异步时钟组用 `set_clock_groups -asynchronous`，范围最小化；
- [ ] 引脚约束与原理图一致（电压标准、上下拉）；
- [ ] 综合/实现报告里 `0 error`、`0 critical warning`。

---

## 6. 收敛顺序（不要跳步）

```text
1. 仿真功能对（G2）
2. 综合无 latch / 无多驱动 / 无宽度不匹配（看 xvlog 警告）
3. 实现后 WNS/WHS ≥ 0
4. 资源在预算内且有余量（G4）
5. 上板复测（G5）
```

第 3 步不过就上板，等于用板子做随机测试；第 2 步不过就做时序，等于优化一个错的设计。
