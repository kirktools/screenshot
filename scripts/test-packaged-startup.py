#!/usr/bin/env python3
"""从 ZIP 解压验证安装版资源，避免构建目录掩盖资源路径错误。"""
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
version = (root / "VERSION").read_text().strip()
with tempfile.TemporaryDirectory(prefix="screenshot-install-test-") as directory:
    folder = pathlib.Path(directory)
    subprocess.run(["ditto", "-x", "-k", str(root / "dist" / f"Screenshot-{version}-macOS.zip"), directory], check=True)
    app = folder / "Screenshot.app"
    binary = app / "Contents/MacOS/Screenshot"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run([str(binary), "--packaged-resources-test"], cwd=directory, check=True, timeout=20)
    # 菜单使用相同加载入口；安静启动/重开及显式打开设置无需读取屏幕。
    subprocess.run([str(binary), "--startup-smoke-test"], cwd=directory, check=True, timeout=20)
    # LICENSE 必须原样随 ZIP 分发；删除它应明确失败，而不是悄悄漏掉授权文本。
    license_file = app / 'Contents/Resources/LICENSE.txt'
    expected_license = (root / 'LICENSE').read_bytes()
    assert license_file.read_bytes() == expected_license
    license_file.unlink()
    result = subprocess.run([str(binary), '--packaged-resources-test'], cwd=directory, capture_output=True, text=True, timeout=20)
    assert result.returncode == 1 and "缺少完整的 MIT 许可证" in result.stderr, result
    license_file.write_bytes(expected_license)
    # 删除资源仅针对临时副本，验证检查会明确失败，不会借用 .build 内的资源。
    shutil.rmtree(app / "Contents/Resources/Screenshot_Screenshot.bundle")
    result = subprocess.run([str(binary), "--packaged-resources-test"], cwd=directory, capture_output=True, text=True, timeout=20)
    assert result.returncode == 1 and "安装包缺少语言资源包" in result.stderr, result
print("安装版回归通过：ZIP 解压、签名、双语资源、安静启动、显式设置、缺失资源检测。")
