"""Run the Windows catalog regression without executing the installer entry point."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import unittest


class WindowsCatalogTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "win32", "Windows installer regression")
    def test_catalog_fallback_and_restore(self):
        shell = shutil.which("powershell") or shutil.which("pwsh")
        if not shell:
            self.skipTest("PowerShell is unavailable")
        test = Path(__file__).with_name("Test-I18nCatalogs.ps1")
        # A Python child of pwsh can inherit PS7-only module paths into Windows PS5.
        env = {key: value for key, value in os.environ.items() if key.lower() != "psmodulepath"}
        result = subprocess.run(
            [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(test)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120, env=env,
        )
        self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", errors="replace"))
