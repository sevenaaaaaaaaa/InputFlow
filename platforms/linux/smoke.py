#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""libliana.py 无 GUI 冒烟（不依赖 ibus，可在 macOS/Linux 任何机器跑）。

用法：python3 platforms/linux/smoke.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import libliana

failures = 0


def check(cond, msg):
    global failures
    print(("  ✓ " if cond else "  ✗ ") + msg)
    if not cond:
        failures += 1


print(f"== libliana 冒烟（内核 {libliana.version()}）==")
s = libliana.Session("pinyin")

for ch in "nihao":
    s.feed(ch)
comp = s.composition()
check(comp.get("raw") == "nihao", "raw 回显")
check(len(comp.get("candidates", [])) > 0, "产生候选")
top = s.select(0)
check(top == "你好", f"select(0) == 你好（实际 {top}）")

s.clear()
check(not s.composition().get("candidates"), "clear 后无候选")
check(s.set_mode("en") and s.mode == "en", "切 en 模式")
s.feed("h")
check(len(s.composition().get("candidates", [])) > 0, "en 补全出候选")
s.set_mode("pinyin")
check(not s.traditional, "默认简体")
s.set_traditional(True)
check(s.traditional, "繁体开关回读")
check(s.record_commit("冒烟测试") , "record_commit")
check(s.user_export() and "你好" in s.user_export(), "user_export 含学习词")
bak = s.backup_export()
check(bak and s.backup_import(bak), "备份导出/导入闭环")

print(f"== 结果：{'全部通过' if failures == 0 else f'{failures} 项失败'} ==")
sys.exit(1 if failures else 0)