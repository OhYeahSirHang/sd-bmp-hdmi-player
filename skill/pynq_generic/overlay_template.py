"""Generic PYNQ overlay template (not used by this project).

Usage:
    from pynq import Overlay, allocate
    ol = Overlay("/home/xilinx/overlay/my.bit")
    print(ol.ip_dict.keys())
"""
from pynq import Overlay, allocate
import numpy as np


def load_overlay(path: str) -> Overlay:
    ol = Overlay(path)
    print("IP:", sorted(ol.ip_dict.keys()))
    return ol


def mmio_smoke(ol: Overlay, ip_name: str, offset: int = 0):
    """Write/read a scratch register; adapt to your IP."""
    ip = getattr(ol, ip_name)
    ip.write(offset, 0x5A5A5A5A)
    val = ip.read(offset)
    print(f"{ip_name}[0x{offset:X}] = 0x{val:08X}")
    assert val == 0x5A5A5A5A, "MMIO readback mismatch"
    return val


def dma_loopback(dma, in_buf, out_buf, nbytes: int):
    """Generic DMA recv/send; adapt channels/direction."""
    dma.recvchannel.transfer(out_buf)
    dma.sendchannel.transfer(in_buf)
    dma.sendchannel.wait()
    dma.recvchannel.wait()
    return np.array(out_buf, copy=True)


if __name__ == "__main__":
    # Example only; replace paths/IP names.
    # ol = load_overlay("/home/xilinx/overlay/my.bit")
    # mmio_smoke(ol, "my_ip")
    pass
