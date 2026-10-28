#!/usr/bin/env python3
"""验证 Windows 便携包结构、架构、版本资源外的公开内容与许可证。"""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import struct
import zipfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime',choices=['win-x64','win-arm64'],required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
version=(root/'VERSION').read_text().strip()
arch=args.runtime.removeprefix('win-')
path=root/'dist'/f'Screenshot-{version}-Windows-{arch}.zip'
spec=importlib.util.spec_from_file_location('public',root/'scripts/check-public-content.py')
public=importlib.util.module_from_spec(spec);spec.loader.exec_module(public)
with zipfile.ZipFile(path) as archive:
    assert sorted(archive.namelist())==['LICENSE.txt','Screenshot.exe','ThirdPartyNotices.txt'],'安装包文件范围异常'
    assert archive.read('LICENSE.txt')==(root/'LICENSE').read_bytes(),'MIT 许可证缺失或不完整'
    assert len(archive.read('ThirdPartyNotices.txt'))>1000,'缺少 .NET 第三方声明'
    image=archive.read('Screenshot.exe')
    assert image[:2]==b'MZ','缺少 Windows 程序'
    offset=struct.unpack_from('<I',image,0x3c)[0]
    assert image[offset:offset+4]==b'PE\0\0'
    assert struct.unpack_from('<H',image,offset+4)[0]=={'x64':0x8664,'arm64':0xaa64}[arch],'程序架构错误'
    # 本项目源码与路径另外检查；运行时是微软构建的官方二进制，不改写其中第三方路径。
    assert not public.inspect_bytes('Windows/Screenshot.exe',image),'二进制含规则覆盖的路径或凭据'
    assert len(image)<160*1024*1024,'安装程序超过更新资源限制'
assert (root/'dist'/f'Screenshot-Windows-{arch}.zip').read_bytes()==path.read_bytes(),'固定名与版本名不一致'
manifest=(root/'dist'/f'SHA256SUMS-Windows-{arch}.txt').read_text(encoding='utf-8-sig')
assert hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name in manifest,'缺少有效更新校验值'
print('Windows 安装包结构、架构、许可证、公开内容及更新校验通过')
