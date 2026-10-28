"""Keep public download/install links on this fork, with explicit source credits."""
from html.parser import HTMLParser
from pathlib import Path
import json
import re
import unittest
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
REPO = "https://github.com/csszyft/claude-desktop-zh-cn"
UPSTREAM = "https://github.com/javaht/claude-desktop-zh-cn"


class PageLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.ids = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if "id" in attributes:
            self.ids.append(attributes["id"])
        for name in ("href", "src", "data-lightbox"):
            if attributes.get(name):
                self.links.append(attributes[name])


class ProjectDocsTests(unittest.TestCase):
    def test_landing_page_links_and_fragment_targets(self):
        page = PageLinks()
        page.feed((ROOT / "docs/index.html").read_text("utf-8"))
        self.assertEqual(len(page.ids), len(set(page.ids)), "Duplicate HTML IDs")
        for link in page.links:
            if link.startswith("#"):
                self.assertIn(link[1:], page.ids, link)
            elif urlsplit(link).scheme:
                self.assertTrue(link == UPSTREAM or link == REPO or link.startswith(REPO + "/"), link)
            else:
                self.assertTrue((ROOT / "docs" / unquote(urlsplit(link).path)).is_file(), link)
        self.assertIn(REPO + "/blob/main/docs/windows-overlay.md", page.links)
        self.assertIn(REPO + "/archive/refs/heads/main.zip", page.links)
        self.assertEqual(page.links.count(UPSTREAM), 1, "Retain one explicit source credit")

    def test_markdown_links_resolve(self):
        paths = [ROOT / "README.md", ROOT / "CHANGELOG.md", ROOT / "docs/windows-overlay.md"]
        paths += list((ROOT / "skills").rglob("*.md"))
        for path in paths:
            text = re.sub(r"```.*?```", "", path.read_text("utf-8"), flags=re.S)
            for link in re.findall(r"\[[^\]]*\]\(([^)]+)\)", text):
                target = urlsplit(link)
                if target.scheme:
                    continue
                destination = path.parent / unquote(target.path) if target.path else path
                self.assertTrue(destination.is_file(), f"{path}: {link}")
                if target.fragment and destination.suffix == ".md":
                    headings = re.findall(r"^#+\s+(.+)$", destination.read_text("utf-8"), flags=re.M)
                    anchors = [re.sub(r"[^\w\s-]", "", h.lower()).replace(" ", "-") for h in headings]
                    self.assertIn(unquote(target.fragment), anchors, link)

    def test_no_promotional_assets_or_old_download_targets(self):
        for path in [ROOT / "README.md", *list((ROOT / "docs").glob("*.md")), ROOT / "docs/index.html"]:
            text = path.read_text("utf-8").lower()
            for stale in ("tokenmetro", "oxoapi", "wechat-group", "api.star-history.com", "linux.do/t/", "releases/latest"):
                self.assertNotIn(stale, text, str(path))
        for name in ("tokenmetro-dark.png", "tokenmetro-light.png", "oxoapi.png", "wechat-group.png"):
            self.assertFalse((ROOT / "docs/images" / name).exists(), name)

    def test_install_instructions_use_this_fork(self):
        for name in ("README.md", "docs/windows-overlay.md"):
            text = (ROOT / name).read_text("utf-8")
            self.assertIn("git clone " + REPO + ".git", text)
            self.assertNotIn("install-mac.command", text)
            self.assertNotIn("install-linux.sh", text)
            self.assertIn("4.29.0.0 x64", text)
        metadata = json.loads((ROOT / "resources/release.json").read_text("utf-8"))
        self.assertEqual(metadata["repo"], "csszyft/claude-desktop-zh-cn")
        self.assertIn("Copyright (c) 2025 javaht", (ROOT / "LICENSE").read_text("utf-8"))

    def test_issue_template_points_to_our_workflow(self):
        text = (ROOT / ".github/ISSUE_TEMPLATE/bug-report.yml").read_text("utf-8")
        self.assertIn(REPO + "/blob/main/docs/windows-overlay.md", text)
        for phase in ("prepare", "seed", "finish", "recover"):
            self.assertIn(phase, text)
