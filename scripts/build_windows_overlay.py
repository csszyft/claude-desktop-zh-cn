"""Build the 4.29 static translation cache bootstrap from two local app copies."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

import patch_claude_zh_cn as asar

RESOURCES = Path(__file__).resolve().parents[1] / "resources"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def render_template(name: str, values: dict[str, object]) -> str:
    text = (RESOURCES / name).read_text("utf-8")
    for key, value in values.items():
        text = text.replace(key, json.dumps(value, ensure_ascii=True, separators=(",", ":")))
    return text


def build(original: Path, patched: Path, output: Path) -> dict:
    if output.exists():
        raise ValueError("Output already exists; use a fresh workspace")
    output.mkdir(parents=True)
    source = output / "frontend-source"
    asar.extract_asar(patched / "resources/ion-dist.asar", source)
    official_path = original / "resources/ion-dist.asar"
    data = official_path.read_bytes()
    hs, _, header = asar.read_asar_header(data, official_path)
    official = dict(asar.walk_asar_entries(header))
    html = (source / "index.html").read_text("utf-8")
    stamp = re.search(r'data-build-timestamp="([0-9]+)"', html)
    scripts = re.findall(r'<script[^>]+src="([^"]+)"', html)
    if not stamp or not scripts or not all(s.startswith("/assets/") for s in scripts) or html.count("</head>") != 1:
        raise ValueError("Unknown frontend entry document; refusing to guess the build identity")

    # Keep the native shell on its shipped Simplified Chinese catalog. The SPA's
    # zh-CN/en-US translations stay in the static cache, not in the signed package.
    count = 0
    for path in source.rglob("*.js"):
        text = path.read_text("utf-8")
        updated, matches = re.subn(
            r'window\.electronIntl\?\.requestLocaleChange\?\.\([A-Za-z_$][\w$]*\.locale\)',
            'window.electronIntl?.requestLocaleChange?.("zh-Hans")', text,
        )
        if matches:
            path.write_text(updated, encoding="utf-8", newline="\n")
            count += matches
    if count != 1:
        raise ValueError(f"Expected one locale bridge call, found {count}")

    assets = {}
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(source).as_posix()
        if not (relative.startswith("assets/") and relative.endswith(".js") or
                relative.startswith("i18n/") and relative.endswith(".json")):
            continue
        content = path.read_bytes()
        old = asar.read_asar_entry(data, hs, header, relative) if relative in official else None
        if old != content:
            assets["/" + relative] = {"hash": hashlib.sha256(content).hexdigest(), "size": len(content)}
    if not assets:
        raise ValueError("No translated static files found")
    # A unique cache also prevents an interrupted install from reusing stale READY logs.
    import uuid
    build_id = uuid.uuid4().hex
    worker_name = "claude-zh-overlay-" + build_id + ".js"
    bootstrap_name = "claude-zh-install-" + build_id + ".js"
    cache_name = "claude-zh-static-" + build_id
    worker = render_template("windows-overlay-worker.js", {
        "__FILES__": assets, "__CACHE__": cache_name, "__BUILD__": build_id,
        "__STAMP__": stamp.group(0), "__SCRIPTS__": scripts,
    })
    bootstrap = render_template("windows-overlay-bootstrap.js", {
        "__BUILD__": build_id, "__COUNT__": len(assets),
    }).replace("__WORKER__", worker_name)
    (source / worker_name).write_text(worker, encoding="utf-8", newline="\n")
    (source / bootstrap_name).write_text(bootstrap, encoding="utf-8", newline="\n")
    html = html.replace("</head>", f'<script defer src="/{bootstrap_name}"></script></head>')
    (source / "index.html").write_text(html, encoding="utf-8", newline="\n")
    archive = output / "ion-dist-bootstrap.asar"
    asar.build_asar(source, archive)
    _, header_text, _ = asar.read_asar_header(archive.read_bytes(), archive)
    exe = bytearray((patched / "Claude.exe").read_bytes())
    marker = b'resources\\\\ion-dist.asar","alg":"SHA256","value":"'
    if exe.count(marker) != 1:
        raise ValueError("Expected one frontend integrity slot in Claude.exe")
    offset = exe.index(marker) + len(marker)
    exe[offset:offset + 64] = asar.asar_header_hash(header_text).encode()
    (output / "Claude-bootstrap.exe").write_bytes(exe)
    manifest = {
        "version": "4.29.0.0", "build": build_id, "assets": assets, "cache": cache_name,
        "stamp": stamp.group(0), "scripts": scripts, "worker": worker_name,
        "bootstrap": bootstrap_name, "readyMarker": f"CLAUDE_ZH_READY:{build_id}:{len(assets)}",
    }
    (output / "overlay-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original-app", type=Path, required=True)
    parser.add_argument("--patched-app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = build(args.original_app, args.patched_app, args.output)
    print(f"Prepared {len(manifest['assets'])} files; build {manifest['build']}")


if __name__ == "__main__":
    main()
