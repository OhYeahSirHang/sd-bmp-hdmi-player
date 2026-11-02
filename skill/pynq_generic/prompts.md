# PYNQ 通用提示词

## 加载/寄存器

```text
这是 PYNQ overlay 的 ip_dict 和寄存器表。请生成：
1. Overlay 加载与 IP 枚举；
2. MMIO 写/读回环；
3. 复位/启动/等待 done 的轮询；
4. 超时与错误码；
5. 一段最小 pytest。
```

## DMA

```text
这是 AXI DMA 的配置（方向/位宽/帧大小）。请生成：
1. allocate(shape, dtype) 缓冲区；
2. sendchannel/recvchannel 顺序；
3. wait/超时；
4. 与 numpy 参考结果比对；
5. 失败时打印 DMA status。
```

## 失效条件

- 没有 `.hwh`；
- IP 没有 AXI-Lite/AXI-Stream；
- PYNQ 版本与 overlay 不匹配。
