"""仅打包隔离实验程序，检查完整许可、架构及项目公共内容规则。"""
import argparse,hashlib,importlib.util,json,os,struct,subprocess,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--directory',type=Path,required=True);p.add_argument('--arch',choices=['x64','arm64'],required=True);args=p.parse_args()
root=Path(__file__).resolve().parents[2];out=args.directory.resolve()
(out/'LICENSE.txt').write_bytes((root/'LICENSE').read_bytes())
modules=json.loads(subprocess.check_output(['go','env','-json','GOMODCACHE','GOROOT'],text=True))
cache=Path(modules['GOMODCACHE'])
notices=[]
for name,path in [('Go runtime',Path(modules['GOROOT'])/'LICENSE'),('MyGo fork',root/'.build/mygo-framework/LICENSE'),('purego',cache/'github.com/ebitengine/purego@v0.11.1/LICENSE'),('typesetting',cache/'github.com/go-text/typesetting@v0.3.5/LICENSE'),('x/image',cache/'golang.org/x/image@v0.46.0/LICENSE')]:notices.append(name+'\n'+path.read_text())
(out/'ThirdPartyNotices.txt').write_text('\n\n'.join(notices))
spec=importlib.util.spec_from_file_location('public',root/'scripts/check-public-content.py');public=importlib.util.module_from_spec(spec);spec.loader.exec_module(public)
errors=[];vendor_provenance=[];machine=0xaa64 if args.arch=='arm64' else 0x8664
for f in out.iterdir():
 if not f.is_file():raise SystemExit('Unexpected directory in probe output')
 data=f.read_bytes();findings=public.inspect_bytes(f.name,data)
 if f.name.lower()=='swiftcore.dll':
  # 唯一例外是固定官方 SDK 的逐字节相同文件；不改写供应商二进制。
  sdk=Path(os.environ['LOCALAPPDATA'])/'Programs/Swift'
  digest=hashlib.sha256(data).hexdigest()
  originals=[v for v in sdk.rglob('swiftCore.dll') if '6.4.1' in str(v) and hashlib.sha256(v.read_bytes()).hexdigest()==digest]
  if not originals:raise SystemExit('Swift runtime is not identical to pinned official SDK')
  vendor_provenance.append({'file':f.name,'source':'official Swift SDK 6.4.1, installer SHA-256 verified by setup script','sha256':digest})
  findings=[v for v in findings if not v.endswith(': 本机用户目录') and not v.endswith(': Windows 用户目录')]
 errors+=findings
 if f.suffix.lower() in ['.exe','.dll']:
  offset=struct.unpack_from('<I',data,0x3c)[0]
  if struct.unpack_from('<H',data,offset+4)[0]!=machine:errors.append(f.name+': incorrect architecture')
if errors:raise SystemExit('\n'.join(errors))
(out/'VendorProvenance.json').write_text(json.dumps(vendor_provenance,indent=2)+'\n')
archive=out.parent/('mygo-probe-'+args.arch+'.zip')
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
 for f in sorted(out.iterdir()):z.write(f,f.name)
archive.with_suffix('.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  '+archive.name+'\n')
print('PASS probe architecture, complete licenses and public content; this is not a release package')
