# -*- coding: utf-8 -*-
"""生成 320x240@15fps RGB565 的 DV1 测试视频(4 秒, 60 帧)"""
import struct, os
import numpy as np

W, H, FPS, N = 320, 240, 15, 60
OUT = r"C:\Users\15905\Desktop\sd_bmp_video320\testvideo_320x240_15fps.dv1"

hdr = bytearray(64)
hdr[0:4] = b'DV1\x00'
struct.pack_into('<HHBB', hdr, 4, W, H, FPS, 0)
struct.pack_into('<I', hdr, 10, W*H*2)
struct.pack_into('<I', hdr, 14, N)

yy, xx = np.mgrid[0:H, 0:W]
buf = bytearray()
buf += hdr + bytes(512-64)          # 扇区 0

for f in range(N):
    t = f / FPS
    # 背景: 对角渐变 + 随时间移动
    r = ((xx + 2*f) % 256).astype(np.uint16)
    g = ((yy*2 + f) % 256).astype(np.uint16)
    b = (((xx+yy)//2 + 3*f) % 256).astype(np.uint16)
    # 移动的白块
    cx = int((W-60) * (0.5 - 0.5*np.cos(2*np.pi*t/4)))
    cy = int((H-60) * (0.5 - 0.5*np.cos(2*np.pi*t/2)))
    mask = np.zeros((H, W), bool); mask[cy:cy+60, cx:cx+60] = True
    r[mask] = 255; g[mask] = 255; b[mask] = 255
    # 顶部帧号条: 每帧递增的白色长度
    bar = int((f % N) * (W/N))
    r[0:10, 0:bar] = 255; g[0:10, 0:bar] = 255; b[0:10, 0:bar] = 255
    r5 = (r >> 3).astype(np.uint16); g6 = (g >> 2).astype(np.uint16); b5 = (b >> 3).astype(np.uint16)
    px = (r5 << 11) | (g6 << 5) | b5
    buf += px.astype('>u2').tobytes()

open(OUT, 'wb').write(buf)
print("written", OUT, os.path.getsize(OUT), "bytes")
print("frames", N, "sectors/frame", W*H*2//512)