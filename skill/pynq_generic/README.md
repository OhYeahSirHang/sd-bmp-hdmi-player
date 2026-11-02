# 通用 PYNQ Skill（加分项，非本题绑定）

> 本项目是**纯 RTL**，不使用 PYNQ。本目录是一个与题目无关的通用模板，面向有 PS + PL 的 PYNQ-Z2/Gen3 等板卡；**未在本项目上板验证**，使用前需按板卡验证。

## 适用场景

- PYNQ overlay 加载失败/找不到 IP；
- PS 通过 MMIO 读写 PL 寄存器；
- DMA 回环/帧缓存；
- 需要把 FPGA 加速器接到 Python。

## 使用方法

1. 用 Vivado 导出 `.bit` + `.hwh`；
2. 把 `.bit/.hwh` 放到 PYNQ 板卡目录；
3. 用 `overlay_template.py` 加载；
4. 按 `prompts.md` 让模型生成 MMIO/DMA 测试；
5. 按 `pitfalls.md` 排查。

## 失效条件

- 纯 PL 工程（无 PS/overlay）；
- 没有 `.hwh`；
- PYNQ 镜像/板卡不匹配；
- IP 没有 AXI 接口。

## 验证状态

模板级：提供加载、MMIO、DMA 回环、ILA 检查清单；未在本项目验证。
