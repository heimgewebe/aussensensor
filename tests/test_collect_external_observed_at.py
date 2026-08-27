from __future__ import annotations

import importlib.util
import sys
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import Mock, patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "collect_external.py"
SPEC = importlib.util.spec_from_file_location("collect_external_observed_at", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
collect_external = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = collect_external
SPEC.loader.exec_module(collect_external)


class ObservedAtTests(unittest.TestCase):
    def test_fetch_json_timestamps_immediately_after_response_read(self) -> None:
        order: list[str] = []
        timestamp = "2026-08-27T18:30:00Z"

        class FakeResponse:
            headers: dict[str, str] = {}

            def __enter__(self):
                return self

            def __exit__(self, _exc_type, _exc, _tb):
                return False

            def read(self, _limit: int) -> bytes:
                order.append("read")
                return b'{"value":"ok"}'

        opener = Mock()
        opener.open.return_value = FakeResponse()

        def fake_now() -> str:
            order.append("timestamp")
            return timestamp

        with (
            patch.object(collect_external, "validate_external_url", return_value=None),
            patch.object(collect_external, "wall_clock_deadline", return_value=nullcontext()),
            patch.object(collect_external.urllib.request, "build_opener", return_value=opener),
            patch.object(collect_external, "utc_now", side_effect=fake_now),
        ):
            observation = collect_external.fetch_json(
                "https://example.com/status",
                allowed_hosts={"example.com"},
                timeout_seconds=1.0,
                max_bytes=1024,
            )

        self.assertEqual(order, ["read", "timestamp"])
        self.assertEqual(observation.observed_at, timestamp)

    def test_collect_uses_each_response_timestamp(self) -> None:
        timestamps = ["2026-08-27T18:30:01Z", "2026-08-27T18:30:09Z"]
        config = {
            "allowed_hosts": ["example.com"],
            "sources": [
                {
                    "id": "first",
                    "label": "First",
                    "adapter": "json-value",
                    "url": "https://example.com/first",
                    "source": "example:first",
                    "value_path": ["value"],
                    "expected_value": "ok",
                    "tags": [],
                },
                {
                    "id": "second",
                    "label": "Second",
                    "adapter": "json-value",
                    "url": "https://example.com/second",
                    "source": "example:second",
                    "value_path": ["value"],
                    "expected_value": "ok",
                    "tags": [],
                },
            ],
        }
        observations = [
            collect_external.Observation(
                payload={"value": "bad-first"},
                evidence_sha256="a" * 64,
                byte_count=1,
                observed_at=timestamps[0],
            ),
            collect_external.Observation(
                payload={"value": "bad-second"},
                evidence_sha256="b" * 64,
                byte_count=1,
                observed_at=timestamps[1],
            ),
        ]
        state = {"schema_version": collect_external.STATE_SCHEMA_VERSION, "sources": {}}

        with patch.object(collect_external, "fetch_json", side_effect=observations):
            events, next_state = collect_external.collect(config, state)

        self.assertEqual([event["ts"] for event in events], timestamps)
        self.assertEqual(
            [next_state["sources"][source_id]["observed_at"] for source_id in ("first", "second")],
            timestamps,
        )


if __name__ == "__main__":
    unittest.main()
