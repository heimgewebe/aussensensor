from __future__ import annotations

import importlib.util
import sys
import unittest
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


if __name__ == "__main__":
    unittest.main()
