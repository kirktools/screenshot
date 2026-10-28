#!/usr/bin/env python3
"""只发布显式列出的官网素材，避免把本地资料或签名文件带入网站。"""
from pathlib import Path
import shutil
root = Path(__file__).resolve().parent.parent
output = root / '.build/site'
if (root / '.build').is_symlink() or output.is_symlink():
    raise SystemExit('拒绝通过符号链接写入官网输出目录')
output.mkdir(parents=True, exist_ok=True)
for child in output.iterdir():
    if child.is_dir() and not child.is_symlink(): shutil.rmtree(child)
    else: child.unlink()
for name in ['index.html', 'style.css', 'icon.svg']:
    shutil.copyfile(root / 'site' / name, output / name)
(output / 'assets').mkdir()
for name in ['editor.png', 'scrolling.gif']:
    shutil.copyfile(root / 'docs/images' / name, output / 'assets' / name)
(output / '.nojekyll').touch()
(output / 'robots.txt').write_text('User-agent: *\nAllow: /\nSitemap: https://kirktools.github.io/screenshot/sitemap.xml\n')
(output / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://kirktools.github.io/screenshot/</loc></url></urlset>\n')
print('官网已生成：.build/site（仅包含白名单文件）')
