#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -c release --product Nc2Shell
NC2SHELL_BIN_DIR="$(bash scripts/swift.sh build -c release --show-bin-path)"
export NC2SHELL_BIN_DIR
python3 - <<'PY'
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

root = Path.cwd()
binary_dir = Path(os.environ["NC2SHELL_BIN_DIR"])
# SwiftPM 资源可能是只读文件，每次在新目录打包，避免覆盖旧 bundle 时失败。
stage = Path(tempfile.mkdtemp(prefix="app-package-", dir=root / ".build"))
app = stage / "Nc2Shell.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources/ThirdParty").mkdir(parents=True, exist_ok=True)
shutil.copy2(binary_dir / "Nc2Shell", contents / "MacOS/Nc2Shell")
for resource in binary_dir.glob("*.bundle"):
    shutil.copytree(resource, contents / "Resources" / resource.name, dirs_exist_ok=True)
shutil.copy2(root / "LICENSE", contents / "Resources/LICENSE")
shutil.copy2(root / ".build/checkouts/SwiftTerm/LICENSE", contents / "Resources/ThirdParty/SwiftTerm-LICENSE.txt")
shutil.copy2(root / "Assets/AppIcon-A-Refined.icns", contents / "Resources/AppIcon.icns")
info = {
    "CFBundleExecutable": "Nc2Shell", "CFBundleName": "Nc2Shell",
    "CFBundleDisplayName": "Nc2Shell", "CFBundleIdentifier": "com.nc2oding.Nc2Shell",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.12.20", "CFBundleVersion": "39",
    "CFBundleIconFile": "AppIcon.icns",
    "LSMinimumSystemVersion": "14.0", "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True,
}
with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump(info, stream)
subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
destination = root / "dist/Nc2Shell.app"
destination.parent.mkdir(exist_ok=True)
if destination.exists():
    destination.rename(stage / "previous-Nc2Shell.app")
app.rename(destination)
print(destination)
PY
