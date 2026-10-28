#!/usr/bin/env python3
"""验证 Windows 便携包、共享核心、运行时架构、公开内容与完整许可证。"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime', choices=['win-x64', 'win-arm64'], required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
version = (root/'VERSION').read_text().strip()
arch = args.runtime.removeprefix('win-')
path = root/'dist'/f'Screenshot-{version}-Windows-{arch}.zip'
specification = json.loads((root/'platforms/windows/package-files.json').read_text())
required = {n.lower() for n in specification['required']}
allowed = required | {n.lower() for n in specification['optional']}
spec = importlib.util.spec_from_file_location('public', root/'scripts/check-public-content.py')
public = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public)
def imports(image):
    pe = struct.unpack_from('<I', image, 0x3c)[0]
    count, optional_size = struct.unpack_from('<H', image, pe+6)[0], struct.unpack_from('<H', image, pe+20)[0]
    optional = pe+24
    directory = optional+(112 if struct.unpack_from('<H', image, optional)[0] == 0x20b else 96)
    rva = struct.unpack_from('<I', image, directory+8)[0]
    sections = []
    for n in range(count):
        at = optional+optional_size+n*40
        size, address, raw_size, raw = struct.unpack_from('<IIII', image, at+8)
        sections.append((address, max(size, raw_size), raw))
    def offset(value):
        for address, size, raw in sections:
            if address <= value < address+size:
                return raw+value-address
        raise AssertionError('非法 PE 导入地址')
    result = []
    if not rva:
        return result
    at = offset(rva)
    for _ in range(4096):
        entry = struct.unpack_from('<IIIII', image, at)
        if not any(entry):
            return result
        name = offset(entry[3])
        result.append(image[name:image.index(b'\0', name)].decode('ascii').lower())
        at += 20
    raise AssertionError('PE 导入表超过限制')

with zipfile.ZipFile(path) as archive:
    names = {n.lower(): n for n in archive.namelist()}
    assert len(names) == len(archive.namelist()) and required <= names.keys() <= allowed, '安装包文件范围异常'
    def read(name): return archive.read(names[name.lower()])
    assert read('LICENSE.txt') == (root/'LICENSE').read_bytes(), 'MIT 许可证缺失或不完整'
    for name in ['Swift-LICENSE.txt', 'Microsoft-VC-Runtime-LICENSE.txt']:
        assert read(name) == (root/'third_party'/name).read_bytes(), '运行时许可缺失或不完整'
    assert len(read('ThirdPartyNotices.txt')) > 1000, '缺少 .NET 第三方声明'
    for name in names:
        if not name.endswith(('.exe', '.dll')):
            continue
        image = read(name)
        assert image[:2] == b'MZ', '缺少 Windows 程序头'
        offset = struct.unpack_from('<I', image, 0x3c)[0]
        assert image[offset:offset+4] == b'PE\0\0'
        assert struct.unpack_from('<H', image, offset+4)[0] == {'x64': 0x8664, 'arm64': 0xaa64}[arch], f'组件架构错误：{name}'
        for dependency in imports(image):
            if dependency.startswith(('swift', 'msvcp140', 'vcruntime140')):
                assert dependency in names, f'缺少私有运行时依赖：{dependency}'
        if name in {'screenshot.exe', 'stitchcoreabi.dll'}:
            assert not public.inspect_bytes('Windows/'+name, image), '自建组件含规则覆盖的路径或凭据'
        assert len(image) < 160*1024*1024, '组件超过更新资源限制'
assert (root/'dist'/f'Screenshot-Windows-{arch}.zip').read_bytes() == path.read_bytes(), '固定名与版本名不一致'
manifest = (root/'dist'/f'SHA256SUMS-Windows-{arch}.txt').read_text(encoding='utf-8-sig')
assert hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name in manifest, '缺少有效更新校验值'
print('Windows 应用、共享核心、运行时架构、许可证、公开内容及更新校验通过')
