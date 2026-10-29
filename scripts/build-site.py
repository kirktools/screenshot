#!/usr/bin/env python3
"""只发布显式列出的官网素材，避免把本地资料或签名文件带入网站。"""
from pathlib import Path
import os
import re
import shutil
root = Path(__file__).resolve().parent.parent
default_download = 'https://github.com/kirktools/screenshot/releases/latest/download/Screenshot-macOS.dmg'
download = os.environ.get('SITE_DOWNLOAD_URL') or default_download
if download != default_download and not re.fullmatch(
        r'https://github\.com/kirktools/screenshot/releases/download/v(\d+\.\d+\.\d+)/Screenshot-\1-macOS\.dmg', download):
    raise SystemExit('官网 DMG 下载地址必须指向本仓库正式版本，且标签与文件版本一致')
output = root / '.build/site'
if (root / '.build').is_symlink() or output.is_symlink():
    raise SystemExit('拒绝通过符号链接写入官网输出目录')
output.mkdir(parents=True, exist_ok=True)
for child in output.iterdir():
    if child.is_dir() and not child.is_symlink(): shutil.rmtree(child)
    else: child.unlink()
for name in ['index.html', 'style.css', 'icon.svg']:
    shutil.copyfile(root / 'site' / name, output / name)
page = output / 'index.html'
page.write_text(page.read_text().replace(default_download, download))
(output / 'assets').mkdir()
for name in ['editor.png', 'screenshot-intro.gif', 'screenshot-intro.mp4', 'screenshot-intro-poster.png']:
    shutil.copyfile(root / 'docs/images' / name, output / 'assets' / name)
(output / '.nojekyll').touch()
(output / 'robots.txt').write_text('User-agent: *\nAllow: /\nSitemap: https://kirktools.github.io/screenshot/sitemap.xml\n')
(output / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://kirktools.github.io/screenshot/</loc></url></urlset>\n')
print('官网已生成：.build/site（仅包含白名单文件）')
