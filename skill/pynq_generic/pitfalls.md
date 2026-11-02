# PYNQ 常见坑（通用）

1. **Overlay 加载失败**：`.bit` 与 `.hwh` 不匹配；确认同名、同目录。
2. **IP 不在 `ip_dict`**：Vivado 导出时没勾选 `.hwh`，或 IP 没被地址映射。
3. **MMIO 写不生效**：IP 时钟/复位没释放；先写复位寄存器再轮询。
4. **DMA 卡死**：`recv` 必须先于 `send`；检查 TLAST/位宽/帧长度。
5. **DMA 数据错位**：Python 缓冲区 dtype 与 AXI 位宽不一致；用 `np.uint32`/`uint8` 对齐。
6. **Cache 一致性**：DMA 前后 `invalidate`/`flush`；PYNQ `allocate` 默认 cacheable。
7. **中断不触发**：没接 `axi_intc` 或没使能 IRQ；先用轮询。
8. **ILA 抓不到**：ILA 时钟域/触发条件错；先抓自由运行。
9. **PS-PL 时钟不匹配**：AXI 时钟必须与 IP 时钟同源或异步桥。
10. **bit 下载成功但 PS 不启动**：BOOT.bin/overlay 混用；确认启动模式。

验证：MMIO 回环、DMA 回环、numpy 比对、连续 100 次不挂。
