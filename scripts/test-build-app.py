#!/usr/bin/env python3
"""在隔离目录执行打包脚本，检查独立应用携带的许可证。"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class BuildAppTests(unittest.TestCase):
    def test_bundle_includes_project_and_dependency_licenses(self):
        with tempfile.TemporaryDirectory(prefix="nc2shell-package-test-") as temporary:
            root = Path(temporary)
            for directory in ("scripts", "Assets", ".build/release", ".build/checkouts/SwiftTerm"):
                (root / directory).mkdir(parents=True)
            shutil.copy2(ROOT / "scripts/build-app.sh", root / "scripts/build-app.sh")
            shutil.copy2(ROOT / "LICENSE", root / "LICENSE")
            shutil.copy2(ROOT / "Assets/AppIcon-A-Refined.icns", root / "Assets/AppIcon-A-Refined.icns")
            dependency_license = b"Isolated third-party license fixture\n"
            (root / ".build/checkouts/SwiftTerm/LICENSE").write_bytes(dependency_license)
            # 只替代编译阶段；仍执行真实的资源复制、plist 生成和应用签名。
            shutil.copy("/usr/bin/true", root / ".build/release/Nc2Shell")
            (root / "scripts/swift.sh").write_text(
                '#!/bin/bash\nset -euo pipefail\n'
                'if [[ "$*" == *"--show-bin-path"* ]]; then printf "%s\\n" "$PWD/.build/release"; fi\n'
            )
            result = subprocess.run(["bash", "scripts/build-app.sh"], cwd=root,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            resources = root / "dist/Nc2Shell.app/Contents/Resources"
            self.assertTrue((resources / "LICENSE").is_file(), "应用包缺少本项目 MIT 许可证")
            self.assertEqual((resources / "LICENSE").read_bytes(), (ROOT / "LICENSE").read_bytes())
            self.assertEqual((resources / "ThirdParty/SwiftTerm-LICENSE.txt").read_bytes(), dependency_license)


if __name__ == "__main__":
    unittest.main()
