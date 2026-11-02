# data — 测试数据与版本关系

## 1. 测试视频

`testvideo/testvideo_320x240_15fps.dv1`

- 320×240 RGB565，15fps，60 帧，4 秒；
- 文件大小 9,216,512B = 512B 头 + 60×153,600B；
- 从 SD **扇区 0 裸写**；
- 生成脚本：`testvideo/gen_dv1.py`。

### DV1 头

```text
0 'D''V''1' 0x00
4-5 W=320
6-7 H=240
8 fps=15
9 fmt=0 (RGB565)
10-13 frame_bytes=153600
14-17 frame_count=60
18-63 保留
```

### 画面判读

| 元素 | 正常 |
|---|---|
| 顶部彩条 | 白/黄/青/绿/紫/红/蓝/黑 |
| 四周白框 | 闭合 |
| 白色横条 | 每秒从上到下 |
| 青色竖条 | 每秒两趟 |
| 橙色方块 | 4 秒往返 |
| 左上角帧号 | 每秒约 +15 |

## 2. 参考图

| 文件 | 说明 |
|---|---|
| `reference/param_vid.png` | 视频参数行效果图 |
| `reference/param_img.png` | 图片参数行效果图 |
| `reference/preview_frame0.png` | 测试视频第 0 帧 |
| `reference/preview_frame45.png` | 测试视频第 45 帧 |
| `reference/menu_media0.png` | 菜单“图片” |
| `reference/menu_media1.png` | 菜单“视频” |

## 3. 版本关系

见 `version_history.md`。

## 4. 校验

`checksums.sha256` 记录关键交付文件的 SHA256；可用：

```bash
python skill/scripts/verify_manifest.py data/checksums.sha256
```
