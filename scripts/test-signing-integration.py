#!/usr/bin/env python3
"""本机固定签名集成验收：需先构建应用；不安装、不上传、不修改系统信任。"""
from pathlib import Path
import base64,fcntl,importlib.util,os,plistlib,re,subprocess,tempfile
root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('signing',root/'scripts/sign-app.py');signing=importlib.util.module_from_spec(spec);spec.loader.exec_module(signing)
def run(args,**kwargs):
 try:r=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=45,**kwargs)
 except subprocess.TimeoutExpired:raise RuntimeError(Path(str(args[0])).name+' integration timeout') from None
 if r.returncode: raise RuntimeError(Path(str(args[0])).name+' integration failed')
 return r
os.umask(0o077)
state=signing.state_directory()/'release'
try:
 if not (state/'identity.json').is_file(): raise RuntimeError('请先运行 make signing-prepare 初始化固定发布身份')
 with (state/'signing.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  identity,keychain,password=signing.local_identity(state)
  run(['/usr/bin/security','lock-keychain',keychain])
  encoded=base64.b64encode(keychain.read_bytes()).decode()
 with tempfile.TemporaryDirectory(prefix='integration-',dir=root/'.build') as folder:
  temp=Path(folder)
  env=dict(os.environ,RUNNER_TEMP=str(temp),GITHUB_ENV=str(temp/'ci.env'),MACOS_SIGNING_KEYCHAIN_BASE64=encoded,MACOS_SIGNING_PASSWORD=password)
  run(['python3',root/'scripts/prepare-ci-signing.py'],env=env)
  signing_env=dict(line.split('=',1) for line in (temp/'ci.env').read_text().splitlines())
  env.update(signing_env)
  ci_keychain=Path(signing_env['SIGN_KEYCHAIN'])
  try:
   requirements=[];hashes=[]
   for version in ['101','102']:
    app=temp/version/'Screenshot.app';app.parent.mkdir()
    run(['/usr/bin/ditto',root/'dist/Screenshot.app',app])
    info=app/'Contents/Info.plist';data=plistlib.loads(info.read_bytes());data['CFBundleVersion']=version;data['BuildSource']='generated-signing-fixture-'+version;info.write_bytes(plistlib.dumps(data))
    run(['python3',root/'scripts/sign-app.py',app,'--mode','release'],env=env)
    requirements.append(run(['/usr/bin/codesign','-d','-r-',app]).stdout.strip())
    detail=run(['/usr/bin/codesign','-d','--verbose=4',app]).stderr
    hashes.append(re.search(r'^CDHash=(.+)$',detail,re.M).group(1))
   assert hashes[0]!=hashes[1], 'fixture content unchanged'
   assert requirements[0]==requirements[1], 'signing identity changed'
   expression=requirements[0].split('=>',1)[1].strip()
   run(['/usr/bin/codesign','--verify','--strict','-R','='+expression,temp/'102/Screenshot.app'])
   print('STABLE SIGNING INTEGRATION PASSED: changed package hashes, identical DR, cross-version requirement validation, isolated CI keychain loading and release signing')
  finally: run(['/usr/bin/security','delete-keychain',ci_keychain])
except Exception as error:
 print(type(error).__name__+': '+str(error));raise SystemExit(1)
