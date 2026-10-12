#!/usr/bin/env python3
"""松萝 / Liana 图标生成器（SVG → icns / 菜单栏模板图）。

源文件在 platforms/macos/assets/icon/*.svg，改图只改 SVG，然后运行：

    pip install playwright pillow && python3 -m playwright install chromium   # 首次
    python3 platforms/macos/tools/make_icons.py

产物：
    assets/Liana.icns           输入法 / 设置中心图标
    assets/LianaInstaller.icns  安装器图标（带下载角标）
    assets/LianaMenu.png        菜单栏输入法图标（16pt@2x 模板图；Info.plist 里 TISIconIsTemplate=true）
    docs/assets/logo.png        README 用 512px
渲染用无头 Chromium（与浏览器同一套 SVG 引擎），不依赖 macOS，Linux 上也能跑。
"""
import io
import os
import sys
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
MAC = HERE.parent
ROOT = MAC.parent.parent
SRC = MAC / "assets" / "icon"
OUT = MAC / "assets"

ICNS_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def render(page, svg: Path, size: int) -> Image.Image:
    """SVG 内联进页面按目标尺寸矢量渲染（不是大图缩放）。"""
    import re

    text = svg.read_text(encoding="utf-8")
    text = re.sub(r'(<svg[^>]*?)\swidth="[^"]*"', r"\1", text, count=1)
    text = re.sub(r'(<svg[^>]*?)\sheight="[^"]*"', r"\1", text, count=1)
    text = text.replace("<svg ", f'<svg width="{size}" height="{size}" ', 1)
    page.set_viewport_size({"width": size, "height": size})
    page.set_content(
        "<html><body style='margin:0;background:transparent'>" + text + "</body></html>"
    )
    png = page.screenshot(omit_background=True, clip={"x": 0, "y": 0, "width": size, "height": size})
    return Image.open(io.BytesIO(png)).convert("RGBA")


def main() -> int:
    with sync_playwright() as p:
        exe = os.environ.get("CHROMIUM_PATH")
        browser = p.chromium.launch(executable_path=exe) if exe else p.chromium.launch()
        page = browser.new_page(device_scale_factor=1)

        for name in ["Liana", "LianaInstaller"]:
            svg = SRC / f"{name}.svg"
            # 每个尺寸单独矢量渲染（小尺寸不是大图缩放，边缘更清楚）
            images = {s: render(page, svg, s) for s in ICNS_SIZES}
            big = images[1024]
            big.save(
                OUT / f"{name}.icns",
                sizes=[(s, s) for s in ICNS_SIZES],
                append_images=[images[s] for s in ICNS_SIZES if s != 1024],
            )
            print(f"已生成 {OUT / (name + '.icns')}")
            if name == "Liana":
                images[512].save(ROOT / "docs" / "assets" / "logo.png")
                print(f"已生成 {ROOT / 'docs/assets/logo.png'}")

        # 菜单栏图标 16pt：32px 写 144dpi，系统按 16pt 显示（Retina 原生清晰，非 Retina 自动缩小）
        menu = SRC / "LianaMenu.svg"
        render(page, menu, 32).save(OUT / "LianaMenu.png", dpi=(144, 144))
        print(f"已生成 {OUT / 'LianaMenu.png'}（16pt@2x 模板图）")
        browser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
