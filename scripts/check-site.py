#!/usr/bin/env python3
"""检查静态官网资源、锚点和发布文件范围，不联网。"""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote

root = Path(__file__).resolve().parent.parent / '.build/site'
expected = {'index.html', 'style.css', 'icon.svg', 'assets/editor.png',
            'assets/scrolling.gif', '.nojekyll', 'robots.txt', 'sitemap.xml'}
actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}
assert actual == expected, f'官网文件范围异常：{actual ^ expected}'

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.links = set(), []
        self.language = None
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'html': self.language = attrs.get('lang')
        if 'id' in attrs:
            assert attrs['id'] not in self.ids, '重复锚点'
            self.ids.add(attrs['id'])
        self.links.extend(attrs[k] for k in ('href', 'src') if k in attrs)

page = Page()
source = (root / 'index.html').read_text()
page.feed(source)
assert page.language == 'zh-CN'
assert '<title>' in source and 'name="description"' in source
assert 'name="viewport"' in source
assert '<script' not in source.lower(), '官网不应引入脚本或统计'
for link in page.links:
    url = urlsplit(link)
    if url.scheme or url.netloc:
        assert url.scheme == 'https' and url.netloc, f'外链必须使用 HTTPS：{link}'
        continue
    target = (root / unquote(url.path or 'index.html')).resolve()
    assert target.is_relative_to(root.resolve()), f'资源越界：{link}'
    assert target.is_file(), f'资源缺失：{link}'
    if url.fragment and target.name == 'index.html':
        assert unquote(url.fragment) in page.ids, f'锚点缺失：{link}'
print('官网检查通过：资源、链接锚点和发布文件范围正常。')
