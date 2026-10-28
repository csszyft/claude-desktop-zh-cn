"""Synthetic archives exercise the overlay builder without touching installed apps."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("overlay_asar", ROOT / "scripts/patch_claude_zh_cn.py")
asar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asar)


class WindowsOverlayTests(unittest.TestCase):
    def fixture(self, root):
        source = root / "source"
        (source / "assets/v1").mkdir(parents=True)
        (source / "i18n").mkdir()
        (source / "index.html").write_text('<html data-build-timestamp="123"><head><script src="/assets/v1/index.js"></script></head></html>', encoding="utf-8")
        (source / "assets/v1/index.js").write_text('window.electronIntl?.requestLocaleChange?.(e.locale);', encoding="utf-8")
        (source / "i18n/en-US.json").write_text('{"hello":"Hello","new":"New"}', encoding="utf-8")
        for name in ("original", "patched"):
            app = root / name
            (app / "resources").mkdir(parents=True)
            if name == "patched":
                (source / "i18n/en-US.json").write_text('{"hello":"Chinese translation","new":"New"}', encoding="utf-8")
            asar.build_asar(source, app / "resources/ion-dist.asar")
            (app / "Claude.exe").write_bytes(b'unchanged-prefix;resources\\\\ion-dist.asar","alg":"SHA256","value":"' + b'0' * 64 + b'";unchanged-suffix')
        return source

    def run_builder(self, root):
        return subprocess.run([
            sys.executable, str(ROOT / "scripts/build_windows_overlay.py"),
            "--original-app", str(root / "original"), "--patched-app", str(root / "patched"),
            "--output", str(root / "overlay"),
        ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_build_integrity_runtime_and_no_live_inputs_modified(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            before = {p: p.read_bytes() for name in ("original", "patched") for p in (root / name).rglob("*") if p.is_file()}
            result = self.run_builder(root)
            self.assertEqual(result.returncode, 0, result.stdout.decode(errors="replace"))
            out = root / "overlay"
            manifest = json.loads((out / "overlay-manifest.json").read_text("utf-8"))
            self.assertEqual(set(manifest["assets"]), {"/assets/v1/index.js", "/i18n/en-US.json"})
            self.assertIn(manifest["build"], manifest["readyMarker"])
            data = (out / "ion-dist-bootstrap.asar").read_bytes()
            hs, header_text, header = asar.read_asar_header(data, out)
            self.assertIn(manifest["bootstrap"].encode(), asar.read_asar_entry(data, hs, header, "index.html"))
            self.assertIn(b'"zh-Hans"', asar.read_asar_entry(data, hs, header, "assets/v1/index.js"))
            original_exe = (root / "patched/Claude.exe").read_bytes()
            self.assertEqual((out / "Claude-bootstrap.exe").read_bytes(), original_exe.replace(b'0' * 64, asar.asar_header_hash(header_text).encode()))
            for p, content in before.items():
                self.assertEqual(p.read_bytes(), content, str(p))
            self.assertNotEqual(self.run_builder(root).returncode, 0, "Existing output must not be overwritten")
            if shutil.which("node"):
                for name in (manifest["worker"], manifest["bootstrap"]):
                    subprocess.run(["node", "--check", str(out / "frontend-source" / name)], check=True, capture_output=True)
                runtime = subprocess.run(["node", str(ROOT / "tests/test_windows_overlay_runtime.cjs"), str(out)], capture_output=True)
                self.assertEqual(runtime.returncode, 0, runtime.stdout + runtime.stderr)

    def test_unknown_locale_bridge_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = self.fixture(root)
            (source / "assets/v1/index.js").write_text('console.log("unknown bundle");', encoding="utf-8")
            asar.build_asar(source, root / "patched/resources/ion-dist.asar")
            result = self.run_builder(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"Expected one locale bridge call", result.stdout)

    def test_old_installer_stops_before_cleanup_or_process_shutdown(self):
        source = (ROOT / "scripts/install_windows.ps1").read_text("utf-8-sig")
        self.assertIn("function Install-WindowsLanguagePack {\n    Assert-LegacyWindowsInstallSupported", source)
        self.assertIn("function Invoke-PreInstallCleanup {\n    # Check before restoring backups or stopping Claude, including interactive cleanup.\n    Assert-LegacyWindowsInstallSupported", source)

    def test_standalone_transaction_guards_are_present(self):
        source = (ROOT / "scripts/apply_windows_overlay.ps1").read_text("utf-8")
        for marker in ("Plan paths do not match", "overlay has not reported READY", "Official signature was not restored", "Unexpected file set", "Get-AuthenticodeSignature"):
            self.assertIn(marker, source)
        self.assertNotIn("WindowsStore", source)
