from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "collect_external.py"
SPEC = importlib.util.spec_from_file_location("collect_external", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
collect_external = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = collect_external
SPEC.loader.exec_module(collect_external)


class CollectExternalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.set_cfg = {
            "id": "models",
            "label": "Model catalog",
            "adapter": "json-set",
            "url": "https://example.com/models",
            "source": "example:models",
            "items_path": ["data"],
            "identity_path": ["id"],
            "expected_items": ["must/exist"],
            "report_removed": True,
            "report_added": False,
            "report_missing_on_baseline": True,
            "tags": ["operator-evidence"],
        }

    def observation(self, payload):
        raw = collect_external.canonical_json(payload)
        return collect_external.Observation(
            payload=payload,
            evidence_sha256=collect_external.sha256_text(raw),
            byte_count=len(raw),
        )

    def test_resolve_path(self) -> None:
        value = {"a": [{"b": "ok"}]}
        self.assertEqual(collect_external.resolve_path(value, ["a", 0, "b"]), "ok")
        with self.assertRaises(collect_external.CollectorError):
            collect_external.resolve_path(value, ["missing"])

    def test_json_set_baseline_reports_missing_expected_once(self) -> None:
        first_events, first_state = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "other/model"}]}),
            None,
            "2026-08-26T18:00:00Z",
        )
        self.assertEqual([event["features"]["change_kind"] for event in first_events], ["missing-expected"])
        self.assertEqual(first_events[0]["source"], "example:models")
        self.assertEqual(first_state["missing_expected"], ["must/exist"])

        second_events, _ = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "other/model"}]}),
            first_state,
            "2026-08-26T18:10:00Z",
        )
        self.assertEqual(second_events, [])

    def test_json_set_event_ids_are_retry_stable_but_episode_unique(self) -> None:
        baseline_events, baseline_state = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "must/exist"}, {"id": "other/model"}]}),
            None,
            "2026-08-26T18:00:00Z",
        )
        self.assertEqual(baseline_events, [])

        missing_events, missing_state = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "other/model"}]}),
            baseline_state,
            "2026-08-26T18:10:00Z",
        )
        self.assertEqual([event["features"]["change_kind"] for event in missing_events], ["missing-expected"])
        first_missing_id = missing_events[0]["id"]

        retry_events, _ = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "other/model"}]}),
            baseline_state,
            "2026-08-26T18:11:00Z",
        )
        self.assertEqual(retry_events[0]["id"], first_missing_id)

        restored_events, restored_state = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "must/exist"}, {"id": "other/model"}]}),
            missing_state,
            "2026-08-26T18:20:00Z",
        )
        self.assertEqual(
            [event["features"]["change_kind"] for event in restored_events],
            ["expected-restored"],
        )

        second_missing_events, _ = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "other/model"}]}),
            restored_state,
            "2026-08-26T18:30:00Z",
        )
        self.assertEqual([event["features"]["change_kind"] for event in second_missing_events], ["missing-expected"])
        self.assertNotEqual(second_missing_events[0]["id"], first_missing_id)

    def test_json_value_reports_unexpected_and_recovery(self) -> None:
        cfg = {
            "id": "status",
            "label": "Service status",
            "adapter": "json-value",
            "url": "https://status.example.com/api.json",
            "source": "example:status",
            "value_path": ["status", "indicator"],
            "detail_path": ["status", "description"],
            "expected_value": "none",
            "report_missing_on_baseline": True,
            "tags": [],
        }
        incident = self.observation({"status": {"indicator": "minor", "description": "Incident"}})
        first_events, first_state = collect_external.compare_json_value(
            cfg,
            incident,
            None,
            "2026-08-26T18:00:00Z",
        )
        self.assertEqual([event["features"]["change_kind"] for event in first_events], ["unexpected-value"])
        self.assertTrue(first_state["unexpected"])
        first_incident_id = first_events[0]["id"]

        retry_events, _ = collect_external.compare_json_value(
            cfg,
            incident,
            None,
            "2026-08-26T18:01:00Z",
        )
        self.assertEqual(retry_events[0]["id"], first_incident_id)

        recovered_events, recovered_state = collect_external.compare_json_value(
            cfg,
            self.observation({"status": {"indicator": "none", "description": "OK"}}),
            first_state,
            "2026-08-26T18:10:00Z",
        )
        self.assertEqual(
            [event["features"]["change_kind"] for event in recovered_events],
            ["expected-restored"],
        )
        self.assertFalse(recovered_state["unexpected"])

        second_incident_events, _ = collect_external.compare_json_value(
            cfg,
            incident,
            recovered_state,
            "2026-08-26T18:20:00Z",
        )
        self.assertEqual(
            [event["features"]["change_kind"] for event in second_incident_events],
            ["unexpected-value"],
        )
        self.assertNotEqual(second_incident_events[0]["id"], first_incident_id)

    def test_generic_json_value_reports_change_without_expected_value(self) -> None:
        cfg = {
            "id": "version",
            "label": "Version",
            "adapter": "json-value",
            "url": "https://example.com/version.json",
            "source": "example:version",
            "value_path": ["version"],
            "tags": [],
        }
        _, first_state = collect_external.compare_json_value(
            cfg,
            self.observation({"version": "1"}),
            None,
            "2026-08-26T18:00:00Z",
        )
        events, _ = collect_external.compare_json_value(
            cfg,
            self.observation({"version": "2"}),
            first_state,
            "2026-08-26T18:10:00Z",
        )
        self.assertEqual([event["features"]["change_kind"] for event in events], ["changed"])

    def test_event_id_is_observation_time_independent(self) -> None:
        cfg = dict(self.set_cfg)
        first = collect_external.make_event(
            source_cfg=cfg,
            change="removed",
            identity="x",
            summary="x",
            observed_at="2026-08-26T18:00:00Z",
            evidence_sha256="a" * 64,
            previous_observed_at=None,
            fingerprint="f" * 64,
        )
        second = collect_external.make_event(
            source_cfg=cfg,
            change="removed",
            identity="x",
            summary="x",
            observed_at="2026-08-26T19:00:00Z",
            evidence_sha256="b" * 64,
            previous_observed_at=None,
            fingerprint="f" * 64,
        )
        self.assertEqual(first["id"], second["id"])
        self.assertNotEqual(first["ts"], second["ts"])

    def test_load_config_rejects_unknown_adapter(self) -> None:
        config = {
            "schema_version": 1,
            "allowed_hosts": ["example.com"],
            "sources": [
                {
                    "id": "bad",
                    "adapter": "crawler",
                    "url": "https://example.com",
                    "source": "example",
                }
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaises(collect_external.CollectorError):
                collect_external.load_config(path)


if __name__ == "__main__":
    unittest.main()
