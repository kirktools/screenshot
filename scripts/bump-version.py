#!/usr/bin/env python3
"""仅计算并写入版本文件，不隐式提交或推送。"""
import argparse
from pathlib import Path
import re
parser = argparse.ArgumentParser()
parser.add_argument("part", choices=["patch", "minor", "major"])
args = parser.parse_args()
path = Path(__file__).resolve().parent.parent / "VERSION"
current = path.read_text().strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", current):
    raise SystemExit("VERSION 格式无效")
major, minor, patch = map(int, current.split("."))
if args.part == "major": major, minor, patch = major + 1, 0, 0
elif args.part == "minor": minor, patch = minor + 1, 0
else: patch += 1
version = f"{major}.{minor}.{patch}"
path.write_text(version + "\n")
print(version)
