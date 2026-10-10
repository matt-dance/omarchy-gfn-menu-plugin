#!/usr/bin/env python3
"""Sanitization and response-size tests for scripts/gfn-catalog-search.py."""

from __future__ import annotations

import importlib.util
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "gfn_catalog_search", ROOT / "scripts" / "gfn-catalog-search.py"
)
assert SPEC and SPEC.loader
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


class StripAndIds(unittest.TestCase):
    def test_strip_controls_removes_nul_cr_lf(self) -> None:
        raw = "Diablo\x00 IV\r\nExec=touch /tmp/pwned"
        self.assertEqual(catalog.strip_controls(raw), "Diablo IVExec=touch /tmp/pwned")

    def test_is_safe_id_accepts_known_tokens(self) -> None:
        self.assertTrue(catalog.is_safe_id("102670811"))
        self.assertTrue(catalog.is_safe_id("d32c9410-62cb-45cf-9c53-740bb92d4a2d"))
        self.assertTrue(catalog.is_safe_id("STEAM"))
        self.assertTrue(catalog.is_safe_optional_id(""))
        self.assertFalse(catalog.is_safe_id(""))
        self.assertFalse(catalog.is_safe_id("STEAM;evil"))
        self.assertFalse(catalog.is_safe_id("id\nExec=touch /tmp/pwned"))
        self.assertFalse(catalog.is_safe_id("`id`"))
        self.assertFalse(catalog.is_safe_id("$(id)"))
        self.assertFalse(catalog.is_safe_id("%f"))

    def test_is_https_url_rejects_injection(self) -> None:
        self.assertTrue(catalog.is_https_url("https://img.example/box.png"))
        self.assertFalse(catalog.is_https_url("http://img.example/box.png"))
        self.assertFalse(catalog.is_https_url("https://img.example/box.png\nExec=touch /tmp/pwned"))
        self.assertFalse(catalog.is_https_url("file:///etc/passwd"))


class NormalizeItem(unittest.TestCase):
    def _item(self, **overrides):
        item = {
            "id": "d32c9410-62cb-45cf-9c53-740bb92d4a2d",
            "cmsId": "101069911",
            "title": "Diablo IV",
            "type": "GAME",
            "images": {"GAME_BOX_ART": "https://img.example/box.png"},
            "variants": [
                {
                    "id": "102670811",
                    "shortName": "",
                    "appStore": "STEAM",
                }
            ],
        }
        item.update(overrides)
        return item

    def test_happy_path(self) -> None:
        rows = catalog.normalize_item(self._item())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["cmsId"], "102670811")
        self.assertEqual(rows[0]["title"], "Diablo IV")
        self.assertEqual(rows[0]["boxArt"], "https://img.example/box.png")

    def test_drops_newline_in_cms_variant(self) -> None:
        item = self._item(
            variants=[
                {
                    "id": "102670811\nExec=touch /tmp/pwned",
                    "shortName": "",
                    "appStore": "STEAM",
                }
            ]
        )
        self.assertEqual(catalog.normalize_item(item), [])

    def test_strips_controls_from_title(self) -> None:
        item = self._item(title="Diablo\nExec=touch /tmp/pwned IV")
        rows = catalog.normalize_item(item)
        self.assertEqual(len(rows), 1)
        self.assertNotIn("\n", rows[0]["title"])
        self.assertNotIn("\x00", rows[0]["title"])

    def test_drops_bad_parent_id(self) -> None:
        item = self._item(id="not a uuid\nExec=touch /tmp/pwned")
        self.assertEqual(catalog.normalize_item(item), [])

    def test_drops_bad_store(self) -> None:
        item = self._item(
            variants=[{"id": "102670811", "shortName": "", "appStore": "STEAM;$(id)"}]
        )
        self.assertEqual(catalog.normalize_item(item), [])

    def test_drops_non_https_box_art(self) -> None:
        item = self._item(images={"GAME_BOX_ART": "http://evil.example/x"})
        rows = catalog.normalize_item(item)
        self.assertEqual(rows[0]["boxArt"], "")


class CacheRow(unittest.TestCase):
    def test_poisoned_cache_row_is_dropped(self) -> None:
        raw = {
            "id": "d32c9410-62cb-45cf-9c53-740bb92d4a2d",
            "cmsId": "102670811\nExec=touch /tmp/pwned",
            "title": "Diablo IV",
            "shortName": "",
            "appStore": "STEAM",
            "boxArt": "",
        }
        self.assertIsNone(catalog.row_from_cache_dict(raw))

    def test_nul_in_cached_title_is_stripped(self) -> None:
        raw = {
            "id": "d32c9410-62cb-45cf-9c53-740bb92d4a2d",
            "cmsId": "102670811",
            "title": "Diablo\x00 IV",
            "shortName": "",
            "appStore": "STEAM",
            "boxArt": "",
        }
        row = catalog.row_from_cache_dict(raw)
        self.assertIsNotNone(row)
        self.assertEqual(row["title"], "Diablo IV")


class HttpReadLimit(unittest.TestCase):
    def test_rejects_oversized_body(self) -> None:
        payload = b'{"data":{}}' + b"x" * (catalog.MAX_RESPONSE_BYTES)

        class FakeResp:
            def read(self, n: int = -1) -> bytes:
                return payload[:n] if n >= 0 else payload

            def __enter__(self) -> "FakeResp":
                return self

            def __exit__(self, *args: object) -> None:
                return None

        with mock.patch("urllib.request.urlopen", return_value=FakeResp()):
            with self.assertRaises(ValueError) as ctx:
                catalog.http_get_json("https://games.geforce.com/graphql")
        self.assertIn("exceeds", str(ctx.exception))

    def test_accepts_small_json(self) -> None:
        payload = b'{"ok":true}'

        class FakeResp:
            def read(self, n: int = -1) -> bytes:
                return payload[:n] if n >= 0 else payload

            def __enter__(self) -> "FakeResp":
                return self

            def __exit__(self, *args: object) -> None:
                return None

        with mock.patch("urllib.request.urlopen", return_value=FakeResp()):
            self.assertEqual(catalog.http_get_json("https://games.geforce.com/graphql"), {"ok": True})


class CursorSafety(unittest.TestCase):
    def test_unsafe_cursor_stops_pagination(self) -> None:
        pages = [
            {
                "data": {
                    "apps": {
                        "pageInfo": {"hasNextPage": True, "endCursor": 'evil"injected'},
                        "items": [],
                    }
                }
            }
        ]

        def fake_get(_url: str, timeout: float = 60.0):
            return pages.pop(0)

        with mock.patch.object(catalog, "http_get_json", side_effect=fake_get):
            items = catalog.fetch_catalog()
        self.assertEqual(items, [])
        self.assertEqual(pages, [])  # second page never requested


if __name__ == "__main__":
    # Keep stdout quiet for CI; unittest writes to stderr.
    buf = io.StringIO()
    runner = unittest.TextTestRunner(stream=sys.stderr, verbosity=2)
    result = runner.run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    sys.exit(0 if result.wasSuccessful() else 1)
