from __future__ import annotations

import importlib.util
import sys
import time
import unittest
from unittest import mock
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "collect_external.py"
SPEC = importlib.util.spec_from_file_location("collect_external_security", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
collect_external = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = collect_external
SPEC.loader.exec_module(collect_external)


class ExternalUrlSecurityTests(unittest.TestCase):
    def test_rejects_non_https_before_dns(self) -> None:
        with self.assertRaisesRegex(collect_external.CollectorError, "Nur HTTPS"):
            collect_external.validate_external_url("http://example.com/data", {"example.com"})

    def test_rejects_credentials_before_dns(self) -> None:
        with self.assertRaisesRegex(collect_external.CollectorError, "Credentials"):
            collect_external.validate_external_url("https://user:pass@example.com/data", {"example.com"})

    def test_rejects_unlisted_host_before_dns(self) -> None:
        with self.assertRaisesRegex(collect_external.CollectorError, "nicht explizit freigegeben"):
            collect_external.validate_external_url("https://not-allowed.example/data", {"example.com"})

    def test_rejects_nonstandard_https_port_before_dns(self) -> None:
        with self.assertRaisesRegex(collect_external.CollectorError, "Standardport 443"):
            collect_external.validate_external_url("https://example.com:4443/data", {"example.com"})

    def test_fetch_json_enforces_end_to_end_wall_clock_deadline(self) -> None:
        class SlowResponse:
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self, _limit):
                time.sleep(0.20)
                return b"{}"

        class SlowOpener:
            def open(self, _request, timeout):
                self.timeout = timeout
                return SlowResponse()

        start = time.monotonic()
        with (
            mock.patch.object(collect_external, "_host_is_public", return_value=None),
            mock.patch.object(collect_external.urllib.request, "build_opener", return_value=SlowOpener()),
            self.assertRaisesRegex(collect_external.CollectorError, "Gesamtzeitlimit"),
        ):
            collect_external.fetch_json(
                "https://example.com/data",
                allowed_hosts={"example.com"},
                timeout_seconds=0.05,
                max_bytes=1024,
            )
        self.assertLess(time.monotonic() - start, 0.15)


if __name__ == "__main__":
    unittest.main()
