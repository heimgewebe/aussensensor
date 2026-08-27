from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def collect_from_scoped_state(self, previous_cfg, source_cfg, previous_state, payload):
        previous_state = dict(previous_state)
        previous_state["observation_scope_sha256"] = (
            collect_external.observation_scope_sha256(previous_cfg)
        )
        config = {"allowed_hosts": ["example.com"], "sources": [source_cfg]}
        state = {
            "schema_version": collect_external.STATE_SCHEMA_VERSION,
            "sources": {"source": previous_state},
        }
        with patch.object(collect_external, "fetch_json", return_value=self.observation(payload)):
            return collect_external.collect(config, state, "2026-08-27T15:12:00Z")

    def test_collect_resets_previous_state_when_adapter_changes(self) -> None:
        value_cfg = {
            "id": "source", "label": "Source", "adapter": "json-value",
            "url": "https://example.com/data", "source": "example:source",
            "value_path": ["value"], "tags": [],
        }
        set_cfg = {
            "id": "source", "label": "Source", "adapter": "json-set",
            "url": "https://example.com/data", "source": "example:source",
            "items_path": ["items"], "identity_path": ["id"],
            "report_added": True, "report_removed": True, "tags": [],
        }
        value_state = {
            "adapter": "json-value", "observed_at": "2026-08-27T14:00:00Z",
            "value": "old", "fingerprint": "stale", "unexpected": False,
        }
        set_state = {
            "adapter": "json-set", "observed_at": "2026-08-27T14:00:00Z",
            "items": ["old"], "missing_expected": [],
        }
        cases = [
            (value_cfg, set_cfg, value_state, {"items": [{"id": "new"}]}),
            (set_cfg, value_cfg, set_state, {"value": "current"}),
        ]
        for previous_cfg, source_cfg, previous_state, payload in cases:
            with self.subTest(adapter=source_cfg["adapter"]):
                events, next_state = self.collect_from_scoped_state(
                    previous_cfg, source_cfg, previous_state, payload
                )
                self.assertEqual(events, [])
                self.assertEqual(
                    next_state["sources"]["source"]["observation_scope_sha256"],
                    collect_external.observation_scope_sha256(source_cfg),
                )

    def test_collect_resets_previous_state_when_observation_scope_changes(self) -> None:
        value_cfg = {
            "id": "source", "label": "Source", "adapter": "json-value",
            "url": "https://example.com/data", "source": "example:source",
            "value_path": ["value"], "tags": [],
        }
        set_cfg = {
            "id": "source", "label": "Source", "adapter": "json-set",
            "url": "https://example.com/data", "source": "example:source",
            "items_path": ["items"], "identity_path": ["id"],
            "report_added": True, "report_removed": True, "tags": [],
        }
        value_state = {
            "adapter": "json-value", "observed_at": "2026-08-27T14:00:00Z",
            "value": "old", "fingerprint": "stale", "unexpected": False,
        }
        set_state = {
            "adapter": "json-set", "observed_at": "2026-08-27T14:00:00Z",
            "items": ["old"], "missing_expected": [],
        }
        cases = [
            (value_cfg, {**value_cfg, "value_path": ["other"]}, value_state, {"other": "current"}, "value_path"),
            (set_cfg, {**set_cfg, "items_path": ["other_items"]}, set_state, {"other_items": [{"id": "new"}]}, "items_path"),
            (set_cfg, {**set_cfg, "identity_path": ["name"]}, set_state, {"items": [{"id": "old", "name": "new"}]}, "identity_path"),
            (value_cfg, {**value_cfg, "url": "https://example.com/other"}, value_state, {"value": "current"}, "url"),
        ]
        for previous_cfg, source_cfg, previous_state, payload, field in cases:
            with self.subTest(field=field):
                events, next_state = self.collect_from_scoped_state(
                    previous_cfg, source_cfg, previous_state, payload
                )
                self.assertEqual(events, [])
                self.assertEqual(
                    next_state["sources"]["source"]["observation_scope_sha256"],
                    collect_external.observation_scope_sha256(source_cfg),
                )

    def test_observation_scope_ignores_expectation_and_reporting_edits(self) -> None:
        value_cfg = {
            "adapter": "json-value", "url": "https://example.com/data",
            "value_path": ["value"], "expected_value": "ok",
            "detail_path": ["detail"], "report_missing_on_baseline": True,
        }
        edited_value = {
            **value_cfg, "expected_value": "other", "detail_path": ["message"],
            "report_missing_on_baseline": False,
        }
        set_cfg = {
            "adapter": "json-set", "url": "https://example.com/data",
            "items_path": ["items"], "identity_path": ["id"],
            "expected_items": ["required"], "report_added": False, "report_removed": True,
        }
        edited_set = {
            **set_cfg, "expected_items": ["other"], "report_added": True, "report_removed": False,
        }
        self.assertEqual(
            collect_external.observation_scope_sha256(value_cfg),
            collect_external.observation_scope_sha256(edited_value),
        )
        self.assertEqual(
            collect_external.observation_scope_sha256(set_cfg),
            collect_external.observation_scope_sha256(edited_set),
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

    def test_removing_expectation_does_not_emit_false_restoration(self) -> None:
        missing_events, missing_state = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "other/model"}]}),
            None,
            "2026-08-27T05:00:00Z",
        )
        self.assertEqual([event["features"]["change_kind"] for event in missing_events], ["missing-expected"])

        no_longer_expected = dict(self.set_cfg)
        no_longer_expected["expected_items"] = []
        events, state = collect_external.compare_json_set(
            no_longer_expected,
            self.observation({"data": [{"id": "other/model"}]}),
            missing_state,
            "2026-08-27T05:10:00Z",
        )
        self.assertEqual(events, [])
        self.assertEqual(state["missing_expected"], [])

    def test_expected_restore_with_report_added_emits_only_restoration(self) -> None:
        cfg = dict(self.set_cfg)
        cfg["report_added"] = True
        _, baseline_state = collect_external.compare_json_set(
            cfg,
            self.observation({"data": [{"id": "must/exist"}, {"id": "other/model"}]}),
            None,
            "2026-08-27T14:00:00Z",
        )
        _, missing_state = collect_external.compare_json_set(
            cfg,
            self.observation({"data": [{"id": "other/model"}]}),
            baseline_state,
            "2026-08-27T14:01:00Z",
        )
        events, _ = collect_external.compare_json_set(
            cfg,
            self.observation({"data": [{"id": "must/exist"}, {"id": "other/model"}]}),
            missing_state,
            "2026-08-27T14:02:00Z",
        )
        self.assertEqual(
            [event["features"]["change_kind"] for event in events],
            ["expected-restored"],
        )

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

    def test_missing_expected_retry_id_ignores_unrelated_catalog_drift(self) -> None:
        _, baseline_state = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "must/exist"}, {"id": "other/a"}]}),
            None,
            "2026-08-26T18:00:00Z",
        )
        first_events, _ = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "other/a"}]}),
            baseline_state,
            "2026-08-26T18:10:00Z",
        )
        retry_events, _ = collect_external.compare_json_set(
            self.set_cfg,
            self.observation({"data": [{"id": "other/b"}]}),
            baseline_state,
            "2026-08-26T18:11:00Z",
        )
        first_missing = next(event for event in first_events if event["features"]["change_kind"] == "missing-expected")
        retry_missing = next(event for event in retry_events if event["features"]["change_kind"] == "missing-expected")
        self.assertEqual(first_missing["id"], retry_missing["id"])

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

        escalated_events, escalated_state = collect_external.compare_json_value(
            cfg,
            self.observation({"status": {"indicator": "major", "description": "Major incident"}}),
            first_state,
            "2026-08-26T18:05:00Z",
        )
        self.assertEqual(
            [event["features"]["change_kind"] for event in escalated_events],
            ["unexpected-value"],
        )
        self.assertNotEqual(escalated_events[0]["id"], first_incident_id)

        repeated_escalation_events, _ = collect_external.compare_json_value(
            cfg,
            self.observation({"status": {"indicator": "major", "description": "Major incident updated"}}),
            escalated_state,
            "2026-08-26T18:06:00Z",
        )
        self.assertEqual(repeated_escalation_events, [])

        recovered_events, recovered_state = collect_external.compare_json_value(
            cfg,
            self.observation({"status": {"indicator": "none", "description": "OK"}}),
            escalated_state,
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

    def test_removing_expected_value_does_not_emit_false_restoration(self) -> None:
        cfg = {
            "id": "status",
            "label": "Service status",
            "adapter": "json-value",
            "url": "https://status.example.com/api.json",
            "source": "example:status",
            "value_path": ["status", "indicator"],
            "expected_value": "none",
            "report_missing_on_baseline": True,
            "tags": [],
        }
        events, state = collect_external.compare_json_value(
            cfg,
            self.observation({"status": {"indicator": "minor"}}),
            None,
            "2026-08-27T05:00:00Z",
        )
        self.assertEqual([event["features"]["change_kind"] for event in events], ["unexpected-value"])

        no_expectation = dict(cfg)
        no_expectation.pop("expected_value")
        events, next_state = collect_external.compare_json_value(
            no_expectation,
            self.observation({"status": {"indicator": "minor"}}),
            state,
            "2026-08-27T05:10:00Z",
        )
        self.assertEqual(events, [])
        self.assertFalse(next_state["unexpected"])

    def test_json_value_object_retry_id_is_canonical_across_key_order(self) -> None:
        cfg = {
            "id": "object-status",
            "label": "Object status",
            "adapter": "json-value",
            "url": "https://status.example.com/api.json",
            "source": "example:object-status",
            "value_path": ["value"],
            "expected_value": {"state": "ok"},
            "report_missing_on_baseline": True,
            "tags": [],
        }
        first_events, first_state = collect_external.compare_json_value(
            cfg,
            self.observation({"value": {"b": 2, "a": 1}}),
            None,
            "2026-08-27T14:20:00Z",
        )
        retry_events, retry_state = collect_external.compare_json_value(
            cfg,
            self.observation({"value": {"a": 1, "b": 2}}),
            None,
            "2026-08-27T14:21:00Z",
        )
        self.assertEqual(len(first_events), 1)
        self.assertEqual(len(retry_events), 1)
        self.assertEqual(first_events[0]["id"], retry_events[0]["id"])
        self.assertEqual(first_state["fingerprint"], retry_state["fingerprint"])

    def test_expected_json_value_comparison_distinguishes_booleans_from_numbers(self) -> None:
        cases = [
            (1, True),
            ({"flag": 1}, {"flag": True}),
            ([0], [False]),
        ]
        for expected_value, current_value in cases:
            with self.subTest(expected_value=expected_value, current_value=current_value):
                cfg = {
                    "id": "typed-status",
                    "label": "Typed status",
                    "adapter": "json-value",
                    "url": "https://status.example.com/api.json",
                    "source": "example:typed-status",
                    "value_path": ["value"],
                    "expected_value": expected_value,
                    "report_missing_on_baseline": True,
                    "tags": [],
                }
                events, state = collect_external.compare_json_value(
                    cfg,
                    self.observation({"value": current_value}),
                    None,
                    "2026-08-27T14:22:00Z",
                )
                self.assertEqual(
                    [event["features"]["change_kind"] for event in events],
                    ["unexpected-value"],
                )
                self.assertTrue(state["unexpected"])

    def test_unexpected_boolean_to_number_transition_is_not_suppressed(self) -> None:
        cfg = {
            "id": "typed-transition",
            "label": "Typed transition",
            "adapter": "json-value",
            "url": "https://status.example.com/api.json",
            "source": "example:typed-transition",
            "value_path": ["value"],
            "expected_value": 2,
            "report_missing_on_baseline": True,
            "tags": [],
        }
        _, state = collect_external.compare_json_value(
            cfg,
            self.observation({"value": True}),
            None,
            "2026-08-27T14:23:00Z",
        )
        events, next_state = collect_external.compare_json_value(
            cfg,
            self.observation({"value": 1}),
            state,
            "2026-08-27T14:24:00Z",
        )
        self.assertEqual(
            [event["features"]["change_kind"] for event in events],
            ["unexpected-value"],
        )
        self.assertTrue(next_state["unexpected"])

    def test_expectation_edit_matching_unchanged_value_does_not_emit_recovery(self) -> None:
        cfg = {
            "id": "status",
            "label": "Service status",
            "adapter": "json-value",
            "url": "https://status.example.com/api.json",
            "source": "example:status",
            "value_path": ["status", "indicator"],
            "expected_value": "none",
            "report_missing_on_baseline": True,
            "tags": [],
        }
        _, state = collect_external.compare_json_value(
            cfg,
            self.observation({"status": {"indicator": "minor"}}),
            None,
            "2026-08-27T14:10:00Z",
        )
        changed_expectation = dict(cfg)
        changed_expectation["expected_value"] = "minor"
        events, next_state = collect_external.compare_json_value(
            changed_expectation,
            self.observation({"status": {"indicator": "minor"}}),
            state,
            "2026-08-27T14:11:00Z",
        )
        self.assertEqual(events, [])
        self.assertFalse(next_state["unexpected"])

    def test_explicit_null_expected_value_is_a_real_expectation(self) -> None:
        cfg = {
            "id": "nullable",
            "label": "Nullable",
            "adapter": "json-value",
            "url": "https://example.com/value.json",
            "source": "example:value",
            "value_path": ["value"],
            "expected_value": None,
            "report_missing_on_baseline": True,
            "tags": [],
        }
        events, _ = collect_external.compare_json_value(
            cfg,
            self.observation({"value": "unexpected"}),
            None,
            "2026-08-27T05:00:00Z",
        )
        self.assertEqual([event["features"]["change_kind"] for event in events], ["unexpected-value"])

    def test_explicit_null_expectation_uses_only_expectation_events(self) -> None:
        cfg = {
            "id": "nullable",
            "label": "Nullable",
            "adapter": "json-value",
            "url": "https://example.com/value.json",
            "source": "example:value",
            "value_path": ["value"],
            "expected_value": None,
            "report_missing_on_baseline": True,
            "tags": [],
        }
        first_events, first_state = collect_external.compare_json_value(
            cfg, self.observation({"value": "bad-a"}), None, "2026-08-27T06:00:00Z"
        )
        self.assertEqual([e["features"]["change_kind"] for e in first_events], ["unexpected-value"])

        changed_events, changed_state = collect_external.compare_json_value(
            cfg, self.observation({"value": "bad-b"}), first_state, "2026-08-27T06:01:00Z"
        )
        self.assertEqual([e["features"]["change_kind"] for e in changed_events], ["unexpected-value"])

        restored_events, _ = collect_external.compare_json_value(
            cfg, self.observation({"value": None}), changed_state, "2026-08-27T06:02:00Z"
        )
        self.assertEqual([e["features"]["change_kind"] for e in restored_events], ["expected-restored"])

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

    def test_generic_json_value_ignores_detail_only_change(self) -> None:
        cfg = {
            "id": "version",
            "label": "Version",
            "adapter": "json-value",
            "url": "https://example.com/version.json",
            "source": "example:version",
            "value_path": ["version"],
            "detail_path": ["description"],
            "tags": [],
        }
        _, first_state = collect_external.compare_json_value(
            cfg,
            self.observation({"version": "1", "description": "first"}),
            None,
            "2026-08-26T18:00:00Z",
        )
        events, second_state = collect_external.compare_json_value(
            cfg,
            self.observation({"version": "1", "description": "wording changed"}),
            first_state,
            "2026-08-26T18:10:00Z",
        )
        self.assertEqual(events, [])
        self.assertEqual(first_state["fingerprint"], second_state["fingerprint"])

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
