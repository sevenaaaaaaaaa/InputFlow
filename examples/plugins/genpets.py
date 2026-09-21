#!/usr/bin/env python3
"""InputFlow 桌宠包美术生成器（纯标准库，零依赖）。

为 5 个形象包绘制帧动画：
  pet-orange-cat        胖橘     · 机械键盘（猫最爱踩键盘）
  pet-shiba             豆豆柴   · 宠物玩具琴
  pet-robot             铁蛋     · 可视化全息屏幕
  pet-oriental-beauty   墨韵佳人 · 古筝
  pet-western-beauty    金发淑女 · 钢琴

每个包 9 帧：idle 4（闲时小动作：呼吸/摆尾/眨眼/小表情），
typing 4（坐着敲击与气质匹配的乐器，双手交替起落），
commit 1（上屏开心 + 星星）。256×256 RGBA，3x 超采样抗锯齿。

用法：python3 genpets.py [输出目录]     # 默认写到本目录
"""

import math
import os
import struct
import sys
import zlib

W = H = 256
SS = 3  # 超采样倍率


# ─────────────────────────── 绘图引擎 ───────────────────────────

class Img:
    def __init__(self):
        self.n = W * SS
        self.pix = [None] * (self.n * self.n)

    def comp(self, x, y, color):
        if not (0 <= x < self.n and 0 <= y < self.n):
            return
        i = y * self.n + x
        sr, sg, sb, sa = color
        if sa >= 255:
            self.pix[i] = (sr, sg, sb, 255)
            return
        d = self.pix[i]
        if d is None:
            self.pix[i] = (sr, sg, sb, sa)
            return
        dr, dg, db, da = d
        a = sa / 255.0
        ia = 1 - a
        self.pix[i] = (
            int(sr * a + dr * ia),
            int(sg * a + dg * ia),
            int(sb * a + db * ia),
            min(255, sa + int(da * ia)),
        )

    def _bbox(self, cx, cy, rx, ry):
        n = self.n
        return (
            max(0, int((cx - rx) * SS)),
            max(0, int((cy - ry) * SS)),
            min(n, int((cx + rx) * SS) + 2),
            min(n, int((cy + ry) * SS) + 2),
        )

    def ellipse(self, cx, cy, rx, ry, color):
        rx, ry = rx * SS, ry * SS
        cx, cy = cx * SS, cy * SS
        if rx <= 0 or ry <= 0:
            return
        x0, y0, x1, y1 = self._bbox(cx / SS, cy / SS, rx / SS, ry / SS)
        for py in range(y0, y1):
            dy = py + 0.5 - cy
            ey = dy / ry
            ey2 = ey * ey
            if ey2 > 1:
                continue
            span = rx * math.sqrt(1 - ey2)
            lo = max(x0, int(cx - span))
            hi = min(x1, int(cx + span) + 1)
            for px in range(lo, hi):
                dx = px + 0.5 - cx
                if dx * dx / (rx * rx) + dy * dy / (ry * ry) <= 1.06:
                    self.comp(px, py, color)

    def rrect(self, cx, cy, w, h, r, color):
        hw, hh = w / 2 * SS, h / 2 * SS
        cx, cy = cx * SS, cy * SS
        r *= SS
        x0, y0, x1, y1 = self._bbox(cx / SS, cy / SS, hw / SS, hh / SS)
        for py in range(y0, y1):
            dy = abs(py + 0.5 - cy) - (hh - r)
            dy = max(dy, 0.0)
            for px in range(x0, x1):
                dx = abs(px + 0.5 - cx) - (hw - r)
                dx = max(dx, 0.0)
                if dx * dx + dy * dy <= r * r:
                    self.comp(px, py, color)

    def line(self, x1, y1, x2, y2, w, color):
        x1, y1, x2, y2, w = x1 * SS, y1 * SS, x2 * SS, y2 * SS, w * SS
        cx = (x1 + x2) / 2
        cy = (y1 + y2) / 2
        rx = abs(x2 - x1) / 2 + w
        ry = abs(y2 - y1) / 2 + w
        x0, y0, x1_, y1_ = self._bbox(cx / SS, cy / SS, rx / SS, ry / SS)
        dx, dy = x2 - x1, y2 - y1
        len2 = dx * dx + dy * dy
        for py in range(y0, y1_):
            for px in range(x0, x1_):
                qx, qy = px + 0.5 - x1, py + 0.5 - y1
                t = 0.0 if len2 == 0 else max(0.0, min(1.0, (qx * dx + qy * dy) / len2))
                ex, ey = qx - t * dx, qy - t * dy
                if ex * ex + ey * ey <= (w / 2) ** 2:
                    self.comp(px, py, color)

    def polygon(self, pts, color):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        x0, y0, x1, y1 = self._bbox(
            (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2,
            (max(xs) - min(xs)) / 2 + 1, (max(ys) - min(ys)) / 2 + 1,
        )
        for py in range(y0, y1):
            y = (py + 0.5) / SS
            cross = []
            for i in range(len(pts)):
                a, b = pts[i], pts[(i + 1) % len(pts)]
                if (a[1] <= y < b[1]) or (b[1] <= y < a[1]):
                    cross.append(a[0] + (y - a[1]) / (b[1] - a[1]) * (b[0] - a[0]))
            cross.sort()
            for j in range(0, len(cross) - 1, 2):
                lo = max(x0, int(cross[j] * SS))
                hi = min(x1, int(cross[j + 1] * SS) + 1)
                for px in range(lo, hi):
                    self.comp(px, py, color)

    def star(self, cx, cy, r, color):
        k = 0.30 * r
        self.polygon(
            [(cx, cy - r), (cx + k, cy - k), (cx + r, cy), (cx + k, cy + k),
             (cx, cy + r), (cx - k, cy + k), (cx - r, cy), (cx - k, cy - k)],
            color,
        )

    def save(self, path):
        raw = bytearray()
        for y in range(H):
            raw.append(0)  # 无滤波
            for x in range(H):
                r = g = b = a = 0
                for sy in range(SS):
                    for sx in range(SS):
                        p = self.pix[(y * SS + sy) * self.n + (x * SS + sx)]
                        if p is None:
                            continue
                        pr, pg, pb, pa = p
                        r += pr * pa
                        g += pg * pa
                        b += pb * pa
                        a += pa
                if a == 0:
                    raw += b"\x00\x00\x00\x00"
                    continue
                raw += bytes((r // a, g // a, b // a, 255))
        chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
        ihdr = struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)
        png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
               + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(png)


def C(hexstr, a=255):
    hexstr = hexstr.lstrip("#")
    return (int(hexstr[0:2], 16), int(hexstr[2:4], 16), int(hexstr[4:6], 16), a)


def o_ellipse(img, cx, cy, rx, ry, fill, line_c, lw=2.5):
    """带描边的椭圆：先画大一号的描边色，再画填充。"""
    img.ellipse(cx, cy, rx + lw, ry + lw, line_c)
    img.ellipse(cx, cy, rx, ry, fill)


def o_rrect(img, cx, cy, w, h, r, fill, line_c, lw=2.5):
    img.rrect(cx, cy, w + lw * 2, h + lw * 2, r + lw, line_c)
    img.rrect(cx, cy, w, h, r, fill)


# ─────────────────────────── 通用部件 ───────────────────────────

def shadow(img):
    img.ellipse(128, 244, 66, 8, C("000000", 40))


def face(img, ex=10, ey=0, blink=False, happy=False, blush_a=110, mouth="smile"):
    """通用脸部：眼睛 + 腮红 + 嘴。坐标基于 256 画布。"""
    blush = C("FF9D9D", blush_a)
    if happy:
        # ^^ 眼
        for x in (106 + ex, 150 + ex):
            img.line(x - 7, 104 + ey, x, 97 + ey, 3.4, C("2A2118"))
            img.line(x, 97 + ey, x + 7, 104 + ey, 3.4, C("2A2118"))
        img.ellipse(94 + ex, 116 + ey, 9, 5.5, blush)
        img.ellipse(162 + ex, 116 + ey, 9, 5.5, blush)
        mouth_arc(img, 128 + ex, 120 + ey, 9, C("7A3B2E"), 3.2, up=False)
        return
    if blink:
        for x in (106 + ex, 150 + ex):
            img.line(x - 7, 102 + ey, x + 7, 102 + ey, 3.6, C("2A2118"))
    else:
        for x in (106 + ex, 150 + ex):
            img.ellipse(x, 101 + ey, 6.2, 8.6, C("2A2118"))
            img.ellipse(x + 2, 97.6 + ey, 2.2, 2.8, C("FFFFFF"))
    img.ellipse(95 + ex, 115 + ey, 8.5, 5, blush)
    img.ellipse(161 + ex, 115 + ey, 8.5, 5, blush)
    if mouth == "omega":
        img.line(122 + ex, 118 + ey, 127 + ex, 122 + ey, 2.8, C("7A3B2E"))
        img.line(127 + ex, 122 + ey, 128 + ex, 119 + ey, 2.8, C("7A3B2E"))
        img.line(128 + ex, 119 + ey, 129 + ex, 122 + ey, 2.8, C("7A3B2E"))
        img.line(129 + ex, 122 + ey, 134 + ex, 118 + ey, 2.8, C("7A3B2E"))
    else:
        mouth_arc(img, 128 + ex, 117 + ey, 7, C("7A3B2E"), 2.8, up=True)


def mouth_arc(img, cx, cy, r, color, w, up):
    pts = []
    for i in range(7):
        a = math.pi * i / 6
        if up:
            pts.append((cx - r * math.cos(a), cy - r * 0.6 * math.sin(a)))
        else:
            pts.append((cx - r * math.cos(a), cy + r * 0.7 * math.sin(a)))
    for i in range(len(pts) - 1):
        img.line(*pts[i], *pts[i + 1], w, color)


def sparkles(img):
    gold = C("FFD75E")
    img.star(52, 74, 12, gold)
    img.star(200, 60, 9, gold)
    img.star(208, 118, 7, C("FFE9A8"))
    img.star(44, 140, 6, C("FFE9A8"))


# ─────────────────────────── 乐器 ───────────────────────────

def keyboard(img, press_left, press_right):
    o_rrect(img, 128, 216, 152, 22, 8, C("EADFC4"), C("B8A87E"))
    for row, y in enumerate((209, 218)):
        for i in range(10):
            kx = 62 + i * 14.7
            accent = (row * 10 + i) % 7 == 3
            c = C("F59E4C") if accent else C("FBF6EA")
            o_rrect(img, kx, y, 11, 6, 2, c, C("C9BC98"), 1.2)
    for px, py in ((100, 205 + press_left * 3), (156, 205 + press_right * 3)):
        pass  # 爪子由角色画在键上


def piano(img):
    o_rrect(img, 104, 222, 156, 26, 5, C("141419"), C("000000"))
    o_rrect(img, 100, 208, 132, 12, 3, C("F7F5EE"), C("B9B4A4"), 1.5)
    for i in range(8):
        if i % 3 != 2:
            img.rrect(48 + i * 14.6 + 9, 206, 6, 7, 1, C("1A1A20"))


def guzheng(img):
    o_rrect(img, 106, 227, 172, 17, 8, C("8A5630"), C("54301B"), 2.5)
    img.rrect(106, 227, 160, 11, 5, C("A56A3C"))
    for i in range(5):
        y = 222 + i * 2.4
        img.line(26, y, 186, y, 1.6, C("F7EBC0"))
    for i in range(5):
        img.ellipse(46 + i * 28, 223.6 + (i % 2) * 2, 2.4, 2.4, C("FFE9A8"))
    img.rrect(19, 227, 10, 17, 4, C("5A3419"))
    img.rrect(193, 227, 10, 17, 4, C("5A3419"))


def toy(img):
    o_rrect(img, 128, 218, 142, 18, 8, C("F5F2EA"), C("C9C2B2"))
    colors = ["E85D5D", "F59E4C", "F5D442", "5DBB6A", "4D8DE8"]
    for i, c in enumerate(colors):
        o_rrect(img, 74 + i * 27, 208, 20, 9, 4, C(c), C("00000040"[:6] + "40" if False else "B9B2A2"), 1.4)
    # 磨牙饼干骨头
    o_rrect(img, 58, 196, 26, 9, 4.5, C("FFF9EE"), C("D8CDB4"), 1.5)
    for bx in (46, 70):
        img.ellipse(bx, 193, 5, 5, C("FFF9EE"))
        img.ellipse(bx, 199, 5, 5, C("FFF9EE"))


def holo(img, t):
    glow = C("3FE0FF", 150)
    sx, sy = 190, 128  # 屏幕中心：右上，不挡身体
    img.rrect(sx, sy, 96, 70, 9, C("3FE0FF", 60))
    img.rrect(sx, sy, 90, 64, 8, C("103048", 170))
    for x1, y1, x2, y2 in ((145, 96, 145, 160), (235, 96, 235, 160), (145, 96, 235, 96), (145, 160, 235, 160)):
        img.line(x1, y1, x2, y2, 1.6, glow)
    # 柱状图（随打字节拍跳动）
    for i in range(4):
        hgt = 7 + 11 * abs(math.sin(t * math.tau + i * 1.1))
        img.rrect(160 + i * 18, 146 - hgt / 2, 11, hgt, 2, C("3FE0FF", 210))
    # 波形
    prev = None
    for i in range(12):
        x = 150 + i * 7.2
        y = 110 + math.sin(t * math.tau * 2 + i * 0.9) * 5
        if prev:
            img.line(*prev, x, y, 1.8, C("8FF0FF", 220))
        prev = (x, y)
    # 投射光束：屏幕底 → 键盘平板
    img.polygon([(160, 162), (196, 190), (160, 190)], C("3FE0FF", 40))
    img.ellipse(128, 244, 52, 7, C("3FE0FF", 70))  # 悬浮基座光圈


# ─────────────────────────── 角色 ───────────────────────────

def draw_cat(img, state, t):
    fur, dark, cream, line_c = C("F59E4C"), C("DE8434"), C("FFF1DE"), C("A85A20")
    blink = state == "idle" and t >= 0.5
    happy = state == "commit"
    pl = max(0.0, math.sin(t * math.tau))
    pr = max(0.0, math.sin(t * math.tau + math.pi))
    sway = math.sin(t * math.tau) * 12 if state != "commit" else 18
    shadow(img)
    # 坐垫
    img.ellipse(128, 232, 62, 13, C("E06A4F"))
    img.ellipse(128, 229, 56, 10, C("EE7E62"))
    # 尾巴（摆动）
    base = (182, 204)
    tip = (base[0] + 26 * math.cos(math.radians(-38 + sway)), base[1] + 26 * math.sin(math.radians(-38 + sway)))
    img.line(*base, *tip, 15, dark)
    img.line(base[0] + 6, base[1] - 6, tip[0], tip[1], 15, fur)
    img.ellipse(*tip, 8, 8, dark)
    # 身体
    o_ellipse(img, 128, 182, 52, 34, fur, line_c)
    img.ellipse(128, 192, 32, 21, cream)
    o_ellipse(img, 88, 198, 19, 15, fur, line_c, 2)
    o_ellipse(img, 168, 198, 19, 15, fur, line_c, 2)
    img.ellipse(103, 213, 9, 6, cream)
    img.ellipse(153, 213, 9, 6, cream)
    # 条纹
    for x in (112, 128, 144):
        img.line(x, 56 + (abs(x - 128) * -0.2), x + (2 if x < 128 else -2), 72, 4.5, dark)
    img.line(84, 170, 92, 186, 4.5, dark)
    img.line(172, 170, 164, 186, 4.5, dark)
    # 耳朵
    img.polygon([(80, 62), (68, 26), (108, 44)], line_c)
    img.polygon([(176, 62), (188, 26), (148, 44)], line_c)
    img.polygon([(83, 58), (74, 32), (104, 47)], fur)
    img.polygon([(173, 58), (182, 32), (152, 47)], fur)
    img.polygon([(84, 53), (79, 38), (98, 47)], C("FFB3A0"))
    img.polygon([(172, 53), (177, 38), (158, 47)], C("FFB3A0"))
    # 头
    o_ellipse(img, 128, 104, 55, 49, fur, line_c)
    img.ellipse(128, 122, 26, 17, cream)
    if happy:
        face(img, blink=False, happy=True)
    else:
        face(img, blink=blink, mouth="omega" if state == "idle" and 0.25 <= t < 0.5 else "smile")
    # 胡须
    for sx, sy, ex, ey in ((78, 108, 52, 104), (78, 116, 52, 118), (178, 108, 204, 104), (178, 116, 204, 118)):
        img.line(sx, sy, ex, ey, 2, C("8A5A2A", 160))
    # 鼻子
    img.polygon([(124, 112), (132, 112), (128, 117)], C("E86A6A"))
    if state in ("typing", "commit"):
        keyboard(img, pl, pr)
        yl, yr = 203 - pl * 6, 203 - pr * 6
        o_ellipse(img, 102, yl, 11, 8, cream, line_c, 2)
        o_ellipse(img, 154, yr, 11, 8, cream, line_c, 2)
        if happy:
            img.line(84, 168, 70, 148, 8, fur)
            img.line(172, 168, 186, 148, 8, fur)
            sparkles(img)


def draw_shiba(img, state, t):
    fur, cream, line_c = C("EF9F55"), C("FFF6E8"), C("B06A28")
    blink = state == "idle" and t >= 0.75
    happy = state == "commit"
    tongue = state == "idle" and 0.25 <= t < 0.5
    pl = max(0.0, math.sin(t * math.tau))
    pr = max(0.0, math.sin(t * math.tau + math.pi))
    sway = math.sin(t * math.tau) * 8
    shadow(img)
    img.rrect(128, 233, 128, 12, 6, C("8FBF7A"))
    img.rrect(128, 233, 118, 8, 4, C("A5D18F"))
    # 卷尾
    tx, ty = 178 + sway, 196
    img.ellipse(tx, ty, 16, 16, fur)
    img.ellipse(tx, ty, 16, 16, fur)
    img.ellipse(tx, ty, 16, 16, fur)
    o_ellipse(img, tx, ty, 15, 15, fur, line_c, 2)
    o_ellipse(img, tx + 1, ty - 1, 9, 9, cream, line_c, 1.5)
    # 身体
    o_ellipse(img, 128, 184, 50, 33, fur, line_c)
    img.ellipse(128, 194, 30, 20, cream)
    o_ellipse(img, 90, 199, 18, 15, fur, line_c, 2)
    o_ellipse(img, 166, 199, 18, 15, fur, line_c, 2)
    img.ellipse(104, 214, 9, 6, cream)
    img.ellipse(152, 214, 9, 6, cream)
    # 耳朵（圆三角）
    for dx in (-1, 1):
        ex = 128 + dx * 38
        img.polygon([(ex - 15, 66), (ex + dx * 2, 24), (ex + 16, 60)], line_c)
        img.polygon([(ex - 11, 61), (ex + dx * 1, 31), (ex + 12, 56)], fur)
    # 头
    o_ellipse(img, 128, 102, 53, 48, fur, line_c)
    o_ellipse(img, 128, 120, 27, 19, cream, C("E8CBA0"), 1.2)
    if happy:
        face(img, happy=True)
    else:
        face(img, blink=blink)
        img.ellipse(128, 112, 4.6, 4, C("2A2118"))
        if tongue:
            img.ellipse(128, 126, 6, 8, C("F08080"))
            img.ellipse(128, 132, 6, 4, C("F08080"))
    if state in ("typing", "commit"):
        toy(img)
        yl, yr = 202 - pl * 6, 202 - pr * 6
        o_ellipse(img, 103, yl, 10.5, 7.5, cream, line_c, 2)
        o_ellipse(img, 153, yr, 10.5, 7.5, cream, line_c, 2)
        if happy:
            sparkles(img)


def draw_robot(img, state, t):
    body_c, dark, visor = C("C9D2DC"), C("6E7885"), C("101820")
    happy = state == "commit"
    scan = math.sin(t * math.tau) * 4
    pl = max(0.0, math.sin(t * math.tau))
    shadow(img)
    img.ellipse(128, 244, 46, 7, C("3FE0FF", 60))
    # 天线
    img.line(128, 76, 128, 56, 3.5, dark)
    img.ellipse(128, 52, 5.5, 5.5, C("FF5A5A") if (state == "idle" and t < 0.5) or state != "idle" else C("FFE066"))
    # 头
    o_rrect(img, 128, 102, 56, 46, 16, C("D6DEE7"), dark)
    img.rrect(128, 102, 40, 14, 6, visor)
    ex = 122 + (scan if state != "commit" else 0)
    for dx in (0, 16):
        img.rrect(ex + dx, 102, 8, 7, 2.5, C("3FE0FF") if not happy else C("7FF3FF"))
    # 嘴（ speaker ）
    for i in range(3):
        img.line(120 + i * 8, 122, 120 + i * 8, 126, 2.4, dark)
    # 耳侧
    img.rrect(97, 102, 8, 18, 3, dark)
    img.rrect(159, 102, 8, 18, 3, dark)
    # 身体
    o_rrect(img, 128, 170, 58, 54, 14, body_c, dark)
    img.rrect(128, 170, 34, 22, 6, C("2A3440"))
    for r in range(2):
        for c in range(3):
            img.ellipse(117 + c * 11, 164 + r * 11, 3, 3, C("8FF0FF", 190))
    # 腿
    img.rrect(113, 199, 13, 26, 5, dark)
    img.rrect(143, 199, 13, 26, 5, dark)
    img.rrect(113, 224, 17, 8, 3.5, C("3A424D"))
    img.rrect(143, 224, 17, 8, 3.5, C("3A424D"))
    if state in ("typing", "commit"):
        holo(img, t if state == "typing" else 0.75)
        # 全息键盘平板（前方地面）
        img.rrect(118, 200, 74, 14, 4, C("3FE0FF", 60))
        for i in range(6):
            img.line(90 + i * 11, 196, 90 + i * 11, 204, 1.2, C("8FF0FF", 120))
        # 手臂：左手敲平板，右手指向屏幕
        img.line(101, 152, 112, 194 - pl * 5, 9, body_c)
        img.line(155, 152, 164, 176 - (1 - pl) * 4, 9, body_c)
        img.ellipse(112, 196 - pl * 5, 7, 7, C("D6DEE7"))
        img.ellipse(164, 178 - (1 - pl) * 4, 7, 7, C("D6DEE7"))
        if happy:
            img.line(96, 148, 84, 134, 8, body_c)
            img.line(160, 148, 172, 134, 8, body_c)
            sparkles(img)


def girl_face(img, blink=False, happy=False, lip="C8506A", lid="9FC8E8", tilt=0.0):
    """妩媚美人脸：白皙底、眼线挑飞、半阖眼波、眼影、挑眉、饱满唇。"""
    skin_shadow = C("F3C9AC", 90)
    # 眉（细挑眉）
    img.line(96 + tilt, 88, 114 + tilt, 85.5, 1.7, C("4A3040", 210))
    img.line(140 + tilt, 85.5, 158 + tilt, 88, 1.7, C("4A3040", 210))
    for x, wing in ((106, -1), (150, 1)):
        wx = x + tilt
        if happy:
            # 弯月笑眼 + 睫毛
            img.line(wx - 7, 102, wx, 96, 3.2, C("1A1420"))
            img.line(wx, 96, wx + 7, 102, 3.2, C("1A1420"))
        elif blink:
            # 阖眼：下弯睫毛线
            img.line(wx - 6.5, 99, wx, 103, 2.6, C("1A1420"))
            img.line(wx, 103, wx + 6.5, 99, 2.6, C("1A1420"))
        else:
            # 眼影
            img.ellipse(wx, 98.6, 7.4, 4, C(lid, 70))
            # 眼白 + 眼珠（眼波微抬）
            img.ellipse(wx, 101, 6.4, 7.4, C("FFFFFF"))
            img.ellipse(wx + wing * 1.4, 101.6, 4.1, 6.1, C("38202F"))
            img.ellipse(wx + wing * 2.1, 103.4, 1.7, 2.2, C("FFFFFF"))
            img.ellipse(wx - wing * 1.6, 98.4, 1.2, 1.6, C("6A4A6A"))
            # 上睑线 + 眼尾挑飞
            img.line(wx - 6.4, 96.4, wx + 6.4, 96.4, 2.3, C("1A1420"))
            img.line(wx + wing * 5.6, 96.8, wx + wing * 10, 93.6, 2.3, C("1A1420"))
            # 下睫毛（淡）
            img.line(wx - wing * 3.4, 107.6, wx + wing * 1.2, 108.2, 1.1, C("1A1420", 110))
    # 腮红（淡）
    img.ellipse(93 + tilt, 112, 8, 4.2, C("FFB4BC", 90))
    img.ellipse(163 + tilt, 112, 8, 4.2, C("FFB4BC", 90))
    # 唇（饱满唇珠）
    dark_lip = "8A3648" if lip == "C8506A" else lip
    img.ellipse(128 + tilt, 116.5, 4.6, 2.8, C(lip))
    img.ellipse(128 + tilt, 114.6, 3.2, 1.4, C(dark_lip, 150))


def _glam_legs(img, hip, knee, ankle, w_thigh=13, w_calf=10, stocking="1B1B26", back=False):
    """侧坐伸腿：圆头粗线条画旋转的大腿/小腿，黑丝 + 腿侧高光。"""
    tone = C("101018") if back else C(stocking)
    sheen = C("9A9AB8", 0 if back else 110)
    wt = w_thigh - 3 if back else w_thigh
    wc = w_calf - 2.5 if back else w_calf
    img.line(*hip, *knee, wt, tone)
    img.line(*knee, *ankle, wc, tone)
    # 高光沿腿一侧
    img.line(hip[0] + 2, hip[1] - 2, knee[0] + 2, knee[1] - 2, 2.2, sheen)
    img.line(knee[0] + 2, knee[1] - 2, ankle[0] + 2, ankle[1] - 2, 1.8, sheen)
    # 袜口（大腿上端一圈）
    if not back:
        img.line(hip[0] + 1, hip[1] + 5, hip[0] + 7, hip[1] + 1, w_thigh - 3, C("101016"))


def _stocking_legs(img, y_top, hgt, w=11, gap=22):
    for dx in (-gap / 2 - w / 2, gap / 2 + w / 2):
        img.rrect(128 + dx, y_top + hgt / 2, w, hgt, 5, C("17171F"))
        img.line(128 + dx, y_top + 6, 128 + dx, y_top + hgt - 4, 1.6, C("9A9AB4", 80))
        # 大腿袜口
        img.rrect(128 + dx, y_top + 4, w + 2, 7, 3, C("101016"))


def _girl_hair_sides(img, cx_s, color, long_extra=False):
    img.ellipse(86, 138, 15, 46, color)
    img.ellipse(170, 138, 15, 46, color)
    if long_extra:
        img.ellipse(88, 178, 11, 26, color)
        img.ellipse(168, 178, 11, 26, color)


def draw_oriental(img, state, t):
    """墨韵佳人：黑长发、抹胸高开衩紧身旗袍、黑丝长腿侧坐、抚古筝。"""
    skin, hair, dress = C("FFE9D8"), C("26222E"), C("A5304C")
    skin_line = C("E0B49A")
    blink = state == "idle" and t >= 0.5
    happy = state == "commit"
    pl = max(0.0, math.sin(t * math.tau))
    pr = max(0.0, math.sin(t * math.tau + math.pi))
    sway = math.sin(t * math.tau) * 2.2
    tilt = sway * 0.6
    hx, hy = 128 + tilt, 98
    shadow(img)
    # 凳（低）
    img.rrect(112, 234, 64, 12, 5, C("3E2C1E"))
    # 后发（披散 + 摆动）
    img.ellipse(88 + sway, 140, 15, 48, hair)
    img.ellipse(168 + sway, 140, 15, 48, hair)
    img.ellipse(86 + sway, 180, 11, 28, hair)
    img.ellipse(170 + sway, 180, 11, 28, hair)
    # 高开衩裙身（紧身收腰，右衩开到腰际 → 右腿全露）
    img.polygon([(108, 148), (148, 148), (158, 176), (120, 208), (100, 200)], skin_line)
    img.polygon([(110, 148), (146, 148), (155, 175), (118, 205), (102, 198)], dress)
    # 开衩边缘金线
    img.line(152, 172, 116, 203, 2.2, C("E8C46A"))
    # 腿：侧坐向右伸，右腿前、左腿后，脚尖交叠（在琴上方，不被挡）
    _glam_legs(img, (124, 190), (172, 208), (206, 219), back=True)
    _glam_legs(img, (120, 194), (170, 212), (202, 223))
    # 高跟鞋尖
    img.polygon([(200, 221), (212, 227), (202, 229)], C("7E2438"))
    # 抹胸上衣（肩臂全露）
    img.rrect(128, 152, 40, 22, 8, dress)
    img.line(110, 158, 146, 158, 2.2, C("E8C46A"))
    img.ellipse(128, 144, 9, 5, skin)  # 颈胸
    # 手臂：左手抚弦、右手（idle 提于发侧 / typing 点弦 / commit 抬腕翻袖）
    img.line(112, 158, 116, 172, 8.5, skin)
    ry = 172 + (4 if state == "idle" and 0.25 <= t < 0.5 else 0)
    img.line(144, 158, 152 + sway, ry, 8.5, skin)
    # 头（白皙 + 微倾）
    o_ellipse(img, hx, hy, 48, 45, skin, skin_line, 1.6)
    # 头顶发 + 刘海
    img.ellipse(hx, hy - 25, 52, 29, hair)
    for x in (hx - 24, hx, hx + 24):
        img.ellipse(x, hy - 26 + (abs(x - hx) * -0.16), 19, 15, hair)
    img.ellipse(hx - 44, hy - 4, 12, 27, hair)
    img.ellipse(hx + 44, hy - 4, 12, 27, hair)
    # 发簪坠
    img.line(hx + 22, hy - 40, hx + 44, hy - 48, 3, C("E8C46A"))
    img.ellipse(hx + 46, hy - 49, 3.5, 3.5, C("E85D8A"))
    img.line(hx + 46, hy - 46, hx + 47, hy - 38, 1.2, C("E8C46A"))
    img.ellipse(hx + 47, hy - 36, 2.4, 2.4, C("E85D8A"))
    # 脸
    girl_face(img, blink=blink, happy=happy, tilt=tilt)
    # 耳坠
    img.ellipse(hx - 42, hy + 12, 2.6, 2.6, C("E8C46A"))
    img.ellipse(hx + 42, hy + 12, 2.6, 2.6, C("E8C46A"))
    # 手（最后画，落在弦上）
    if state in ("typing", "commit"):
        guzheng(img)
        ly = 220 - pl * 6
        ry2 = 222 - pr * 6
        img.ellipse(96, ly, 6.2, 5.6, skin)
        img.ellipse(132, ry2, 6.2, 5.6, skin)
        if happy:
            # 销魂抬腕：一手上举翻袖
            img.line(144, 158, 162, 138, 8.5, skin)
            img.ellipse(164, 134, 6.5, 6.5, skin)
            sparkles(img)
    else:
        img.ellipse(118, 174, 5.6, 5.2, skin)
        img.ellipse(154 + sway, ry, 5.6, 5.2, skin)


def draw_western(img, state, t):
    """金发淑女：高挑白皙、抹胸高开衩黑礼裙、大波浪金发、长腿直伸弹钢琴。"""
    skin, hair, dress = C("FFEAD9"), C("E9C76B"), C("1E1E28")
    skin_line = C("E0B49A")
    blink = state == "idle" and t >= 0.5
    happy = state == "commit"
    pl = max(0.0, math.sin(t * math.tau))
    pr = max(0.0, math.sin(t * math.tau + math.pi))
    sway = math.sin(t * math.tau) * 2.6
    tilt = sway * 0.7
    hx, hy = 128 + tilt, 94
    shadow(img)
    # 后发（大波浪，三层）
    img.ellipse(84 + sway, 128, 16, 46, hair)
    img.ellipse(172 + sway, 128, 16, 46, hair)
    img.ellipse(80 + sway, 166, 12, 30, hair)
    img.ellipse(176 + sway, 166, 12, 30, hair)
    img.ellipse(88 + sway, 192, 9, 20, hair)
    img.ellipse(168 + sway, 192, 9, 20, hair)
    # 高开衩晚礼裙（抹胸，左衩高开 → 左腿全露）
    img.polygon([(108, 144), (148, 144), (162, 172), (138, 208), (98, 198)], skin_line)
    img.polygon([(110, 144), (146, 144), (159, 171), (136, 205), (100, 196)], dress)
    img.line(156, 168, 136, 202, 2.2, C("8E8E9C"))
    # 腿：右伸交叠，长腿（在琴上方）
    _glam_legs(img, (122, 186), (176, 204), (212, 216), back=True)
    _glam_legs(img, (118, 190), (174, 208), (208, 220))
    img.ellipse(206, 218, 5.6, 3.8, C("0E0E14"))
    img.polygon([(206, 218), (218, 224), (208, 226)], C("0E0E14"))
    # 腰链
    img.line(112, 146, 144, 146, 1.6, C("E8E4F0", 160))
    # 抹胸 + 颈胸
    img.rrect(128, 150, 40, 20, 8, dress)
    img.ellipse(128, 142, 8, 5, skin)
    # 项链
    for i, x in enumerate((119, 128, 137)):
        img.ellipse(x, 138 + (3 if i == 1 else 0), 1.8, 1.8, C("F5F0E8"))
    # 手臂
    img.line(112, 152, 116, 168, 8, skin)
    img.line(144, 152, 152 + sway, 168, 8, skin)
    # 头（略小显高挑）
    o_ellipse(img, hx, hy, 43, 41, skin, skin_line, 1.5)
    # 金发（中分大波浪）
    img.ellipse(hx, hy - 26, 47, 27, hair)
    img.line(hx, hy - 50, hx, hy - 34, 2.2, skin)
    img.ellipse(hx - 22, hy - 28, 16, 13, hair)
    img.ellipse(hx + 22, hy - 28, 16, 13, hair)
    img.ellipse(hx - 41, hy - 2, 12, 28, hair)
    img.ellipse(hx + 41, hy - 2, 12, 28, hair)
    # 脸
    girl_face(img, blink=blink, happy=happy, lip="C2506A", lid="C9A8D8", tilt=tilt)
    # 耳坠（珍珠）
    img.ellipse(hx - 39, hy + 11, 2.4, 2.4, C("F5F0E8"))
    img.ellipse(hx + 39, hy + 11, 2.4, 2.4, C("F5F0E8"))
    # 手（最后画，落在琴键上）
    if state in ("typing", "commit"):
        piano(img)
        ly = 204 - pl * 6
        ry2 = 206 - pr * 6
        img.ellipse(88, ly, 5.8, 5.2, skin)
        img.ellipse(122, ry2, 5.8, 5.2, skin)
        if happy:
            # 手臂上扬甩发
            img.line(144, 152, 164, 132, 8, skin)
            img.ellipse(166, 128, 6, 6, skin)
            img.ellipse(hx + 48, hy - 10 + sway, 11, 22, hair)
            sparkles(img)
    else:
        img.ellipse(118, 170, 5.4, 5, skin)
        img.ellipse(154 + sway, 170, 5.4, 5, skin)


# ─────────────────────────── 生成 ───────────────────────────

PACKS = {
    "pet-orange-cat": draw_cat,
    "pet-shiba": draw_shiba,
    "pet-robot": draw_robot,
    "pet-oriental-beauty": draw_oriental,
    "pet-western-beauty": draw_western,
}
PHASES = [i / 4 for i in range(4)]


def main():
    out_root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    for pack_id, draw in PACKS.items():
        frames_dir = os.path.join(out_root, pack_id, "frames")
        made = []
        for i, t in enumerate(PHASES):
            img = Img()
            draw(img, "idle", t)
            p = os.path.join(frames_dir, f"idle-{i}.png")
            img.save(p)
            made.append(p)
        for i, t in enumerate(PHASES):
            img = Img()
            draw(img, "typing", t)
            p = os.path.join(frames_dir, f"typing-{i}.png")
            img.save(p)
            made.append(p)
        img = Img()
        draw(img, "commit", 0.0)
        p = os.path.join(frames_dir, "commit-0.png")
        img.save(p)
        made.append(p)
        print(f"{pack_id}: {len(made)} 帧")
    print("完成")


if __name__ == "__main__":
    main()
