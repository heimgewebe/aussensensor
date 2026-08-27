#!/usr/bin/env python3
"""Bounded external-evidence collector for Aussensensor.

The collector turns explicitly allow-listed HTTPS JSON sources into stable
`aussen.event` observations. It is deliberately small: it does not crawl the
web, make policy decisions, or trigger work. It only observes configured
external facts, compares them with the last successful observation, and emits
NDJSON evidence for Chronik.
"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import socket
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

STATE_SCHEMA_VERSION = 1
CONFIG_SCHEMA_VERSION = 1
DEFAULT_MAX_BYTES = 8 * 1024 * 1024
DEFAULT_TIMEOUT_SECONDS = 15.0
USER_AGENT = "heimgewebe-aussensensor/1"


class CollectorError(RuntimeError):
    """Fail-closed collector error."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def resolve_path(value: Any, path: Iterable[Any]) -> Any:
    current = value
    for segment in path:
        if isinstance(current, dict) and isinstance(segment, str):
            if segment not in current:
                raise CollectorError(f"JSON-Pfad fehlt: {segment!r}")
            current = current[segment]
        elif isinstance(current, list) and isinstance(segment, int):
            try:
                current = current[segment]
            except IndexError as exc:
                raise CollectorError(f"JSON-Index außerhalb des Bereichs: {segment}") from exc
        else:
            raise CollectorError(f"JSON-Pfad passt nicht zur Struktur: {segment!r}")
    return current


def stable_event_id(source_id: str, change: str, identity: str, fingerprint: str) -> str:
    material = canonical_json(
        {
            "source_id": source_id,
            "change": change,
            "identity": identity,
            "fingerprint": fingerprint,
        }
    )
    return f"aussen:{sha256_text(material)}"


def transition_fingerprint(before: Any, after: Any) -> str:
    return sha256_text(canonical_json({"before": before, "after": after}))


def episode_fingerprint(previous_observed_at: str | None, identity: str, before: Any, after: Any) -> str:
    return transition_fingerprint(
        {"anchor": previous_observed_at, "identity": identity, "state": before},
        {"identity": identity, "state": after},
    )


def normalized_tags(tags: Iterable[str], change: str) -> list[str]:
    out: list[str] = []
    for tag in [*tags, "external-evidence", f"change:{change}"]:
        if not isinstance(tag, str) or not tag or tag[0].isspace():
            raise CollectorError(f"Ungültiger Tag: {tag!r}")
        tag = tag[:64]
        if tag not in out:
            out.append(tag)
    if len(out) > 64:
        raise CollectorError("Mehr als 64 Tags sind nicht erlaubt")
    return out


def make_event(
    *,
    source_cfg: dict[str, Any],
    change: str,
    identity: str,
    summary: str,
    observed_at: str,
    evidence_sha256: str,
    previous_observed_at: str | None,
    fingerprint: str,
    detail: Any = None,
) -> dict[str, Any]:
    label = str(source_cfg.get("label") or source_cfg["id"])
    source = str(source_cfg["source"])
    title = f"{label}: {change} {identity}"[:300]
    event = {
        "id": stable_event_id(str(source_cfg["id"]), change, identity, fingerprint),
        "type": str(source_cfg.get("event_type", "alert")),
        "source": source,
        "title": title,
        "summary": summary[:2000],
        "url": str(source_cfg["url"]),
        "tags": normalized_tags(source_cfg.get("tags", []), change),
        "ts": observed_at,
        "features": {
            "change_kind": change,
            "severity": source_cfg.get("severity_by_change", {}).get(change, source_cfg.get("severity", "medium")),
        },
        "meta": {
            "adapter": source_cfg["adapter"],
            "source_id": source_cfg["id"],
            "observed_at": observed_at,
            "previous_observed_at": previous_observed_at,
            "evidence_sha256": evidence_sha256,
        },
    }
    if detail is not None:
        event["meta"]["detail"] = detail
    return event


def _host_is_public(hostname: str) -> None:
    """Reject literal/local/private hosts before opening a connection.

    Host allow-listing is the primary SSRF boundary. This additional check
    catches accidental localhost/private targets. DNS answers are checked too,
    but this is not claimed as a complete DNS-rebinding defense.
    """
    lowered = hostname.rstrip(".").lower()
    if lowered in {"localhost", "localhost.localdomain"} or lowered.endswith(".local"):
        raise CollectorError(f"Lokaler Host ist nicht erlaubt: {hostname}")
    try:
        addresses = socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise CollectorError(f"DNS-Auflösung fehlgeschlagen für {hostname}: {exc}") from exc
    for entry in addresses:
        ip = ipaddress.ip_address(entry[4][0])
        if not ip.is_global:
            raise CollectorError(f"Nicht-öffentliche Zieladresse ist nicht erlaubt: {hostname} -> {ip}")


def validate_external_url(url: str, allowed_hosts: set[str]) -> urllib.parse.ParseResult:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme.lower() != "https":
        raise CollectorError(f"Nur HTTPS-Quellen sind erlaubt: {url}")
    if parsed.username or parsed.password:
        raise CollectorError("Credentials in Quell-URLs sind nicht erlaubt")
    try:
        port = parsed.port
    except ValueError as exc:
        raise CollectorError(f"Ungültiger HTTPS-Port in Quell-URL: {url}") from exc
    if port not in (None, 443):
        raise CollectorError(f"Nur HTTPS-Standardport 443 ist erlaubt: {url}")
    hostname = (parsed.hostname or "").lower()
    if not hostname or hostname not in allowed_hosts:
        raise CollectorError(f"Host ist nicht explizit freigegeben: {hostname or '<leer>'}")
    _host_is_public(hostname)
    return parsed


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, allowed_hosts: set[str]):
        super().__init__()
        self.allowed_hosts = allowed_hosts

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[override]
        validate_external_url(newurl, self.allowed_hosts)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


@dataclass(frozen=True)
class Observation:
    payload: Any
    evidence_sha256: str
    byte_count: int


def fetch_json(
    url: str,
    *,
    allowed_hosts: set[str],
    timeout_seconds: float,
    max_bytes: int,
) -> Observation:
    validate_external_url(url, allowed_hosts)
    opener = urllib.request.build_opener(SafeRedirectHandler(allowed_hosts))
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": USER_AGENT},
        method="GET",
    )
    try:
        with opener.open(request, timeout=timeout_seconds) as response:
            length = response.headers.get("Content-Length")
            if length is not None and int(length) > max_bytes:
                raise CollectorError(f"Antwort überschreitet Maximalgröße ({length} > {max_bytes})")
            raw = response.read(max_bytes + 1)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        raise CollectorError(f"Abruf fehlgeschlagen für {url}: {exc}") from exc
    if len(raw) > max_bytes:
        raise CollectorError(f"Antwort überschreitet Maximalgröße ({len(raw)} > {max_bytes})")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CollectorError(f"Quelle liefert kein gültiges UTF-8-JSON: {url}: {exc}") from exc
    return Observation(payload=payload, evidence_sha256=hashlib.sha256(raw).hexdigest(), byte_count=len(raw))


def _identity_set(source_cfg: dict[str, Any], payload: Any) -> list[str]:
    items = resolve_path(payload, source_cfg["items_path"])
    if not isinstance(items, list):
        raise CollectorError(f"{source_cfg['id']}: items_path liefert keine Liste")
    identities: set[str] = set()
    for item in items:
        identity = resolve_path(item, source_cfg["identity_path"])
        if not isinstance(identity, (str, int, float)) or isinstance(identity, bool):
            raise CollectorError(f"{source_cfg['id']}: Identität ist kein skalarer Wert")
        identities.add(str(identity))
    return sorted(identities)


def compare_json_set(
    source_cfg: dict[str, Any],
    observation: Observation,
    previous: dict[str, Any] | None,
    observed_at: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    current_items = _identity_set(source_cfg, observation.payload)
    current_set = set(current_items)
    previous_items = set(previous.get("items", [])) if previous else set()
    previous_missing = set(previous.get("missing_expected", [])) if previous else set()
    expected = {str(value) for value in source_cfg.get("expected_items", [])}
    current_missing = expected - current_set
    previous_observed_at = previous.get("observed_at") if previous else None
    events: list[dict[str, Any]] = []
    if previous:
        if source_cfg.get("report_added", False):
            for identity in sorted(current_set - previous_items):
                events.append(
                    make_event(
                        source_cfg=source_cfg,
                        change="added",
                        identity=identity,
                        summary=f"{identity!r} ist neu in {source_cfg['source']} sichtbar.",
                        observed_at=observed_at,
                        evidence_sha256=observation.evidence_sha256,
                        previous_observed_at=previous_observed_at,
                        fingerprint=episode_fingerprint(previous_observed_at, identity, "absent", "present"),
                    )
                )
        if source_cfg.get("report_removed", True):
            for identity in sorted(previous_items - current_set):
                if identity in expected:
                    continue
                events.append(
                    make_event(
                        source_cfg=source_cfg,
                        change="removed",
                        identity=identity,
                        summary=f"{identity!r} ist aus {source_cfg['source']} verschwunden.",
                        observed_at=observed_at,
                        evidence_sha256=observation.evidence_sha256,
                        previous_observed_at=previous_observed_at,
                        fingerprint=episode_fingerprint(previous_observed_at, identity, "present", "absent"),
                    )
                )

    newly_missing = current_missing - previous_missing if previous else current_missing
    if previous or source_cfg.get("report_missing_on_baseline", True):
        for identity in sorted(newly_missing):
            events.append(
                make_event(
                    source_cfg=source_cfg,
                    change="missing-expected",
                    identity=identity,
                    summary=f"Erwarteter Wert {identity!r} fehlt in {source_cfg['source']}.",
                    observed_at=observed_at,
                    evidence_sha256=observation.evidence_sha256,
                    previous_observed_at=previous_observed_at,
                    fingerprint=episode_fingerprint(previous_observed_at, identity, "expected", "missing"),
                )
            )

    if previous:
        restored_expected = (previous_missing - current_missing) & expected & current_set
        for identity in sorted(restored_expected):
            events.append(
                make_event(
                    source_cfg=source_cfg,
                    change="expected-restored",
                    identity=identity,
                    summary=f"Erwarteter Wert {identity!r} ist in {source_cfg['source']} wieder vorhanden.",
                    observed_at=observed_at,
                    evidence_sha256=observation.evidence_sha256,
                    previous_observed_at=previous_observed_at,
                    fingerprint=episode_fingerprint(previous_observed_at, identity, "missing", "expected"),
                )
            )

    state = {
        "adapter": "json-set",
        "observed_at": observed_at,
        "evidence_sha256": observation.evidence_sha256,
        "item_count": len(current_items),
        "items": current_items,
        "missing_expected": sorted(current_missing),
    }
    return events, state


def compare_json_value(
    source_cfg: dict[str, Any],
    observation: Observation,
    previous: dict[str, Any] | None,
    observed_at: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    current_value = resolve_path(observation.payload, source_cfg["value_path"])
    detail = None
    if source_cfg.get("detail_path") is not None:
        detail = resolve_path(observation.payload, source_cfg["detail_path"])
    fingerprint = sha256_text(canonical_json({"value": current_value}))
    previous_observed_at = previous.get("observed_at") if previous else None
    events: list[dict[str, Any]] = []
    expected_value = source_cfg.get("expected_value", None)
    if expected_value is None and previous and previous.get("fingerprint") != fingerprint:
        before = previous.get("value")
        events.append(
            make_event(
                source_cfg=source_cfg,
                change="changed",
                identity=f"{before!r} -> {current_value!r}",
                summary=f"{source_cfg['source']} änderte sich von {before!r} auf {current_value!r}.",
                observed_at=observed_at,
                evidence_sha256=observation.evidence_sha256,
                previous_observed_at=previous_observed_at,
                fingerprint=episode_fingerprint(previous_observed_at, repr(before), before, current_value),
                detail=detail,
            )
        )

    is_unexpected = expected_value is not None and current_value != expected_value
    was_unexpected = bool(previous and previous.get("unexpected", False))
    unexpected_value_changed = bool(previous and was_unexpected and previous.get("value") != current_value)
    if is_unexpected and (previous or source_cfg.get("report_missing_on_baseline", True)) and (
        not was_unexpected or unexpected_value_changed
    ):
        events.append(
            make_event(
                source_cfg=source_cfg,
                change="unexpected-value",
                identity=repr(current_value),
                summary=f"{source_cfg['source']} meldet {current_value!r}; erwartet ist {expected_value!r}.",
                observed_at=observed_at,
                evidence_sha256=observation.evidence_sha256,
                previous_observed_at=previous_observed_at,
                fingerprint=episode_fingerprint(previous_observed_at, repr(current_value), previous.get("value") if previous else expected_value, current_value),
                detail=detail,
            )
        )
    elif previous and was_unexpected and not is_unexpected:
        events.append(
            make_event(
                source_cfg=source_cfg,
                change="expected-restored",
                identity=repr(current_value),
                summary=f"{source_cfg['source']} entspricht wieder dem erwarteten Wert {expected_value!r}.",
                observed_at=observed_at,
                evidence_sha256=observation.evidence_sha256,
                previous_observed_at=previous_observed_at,
                fingerprint=episode_fingerprint(previous_observed_at, repr(current_value), previous.get("value"), current_value),
                detail=detail,
            )
        )

    state = {
        "adapter": "json-value",
        "observed_at": observed_at,
        "evidence_sha256": observation.evidence_sha256,
        "value": current_value,
        "detail": detail,
        "fingerprint": fingerprint,
        "unexpected": is_unexpected,
    }
    return events, state


def load_config(path: Path) -> dict[str, Any]:
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CollectorError(f"Konfiguration kann nicht gelesen werden: {path}: {exc}") from exc
    if not isinstance(config, dict) or config.get("schema_version") != CONFIG_SCHEMA_VERSION:
        raise CollectorError(f"Nicht unterstützte config schema_version in {path}")
    sources = config.get("sources")
    allowed_hosts = config.get("allowed_hosts")
    if not isinstance(sources, list) or not sources:
        raise CollectorError("Konfiguration braucht mindestens eine Quelle")
    if not isinstance(allowed_hosts, list) or not allowed_hosts:
        raise CollectorError("Konfiguration braucht allowed_hosts")
    ids: set[str] = set()
    for source in sources:
        if not isinstance(source, dict):
            raise CollectorError("Jede Quelle muss ein Objekt sein")
        for key in ("id", "adapter", "url", "source"):
            if not isinstance(source.get(key), str) or not source[key]:
                raise CollectorError(f"Quelle braucht nicht-leeres Feld {key}")
        if source["id"] in ids:
            raise CollectorError(f"Doppelte source id: {source['id']}")
        ids.add(source["id"])
        if source["adapter"] == "json-set":
            if not isinstance(source.get("items_path"), list) or not isinstance(source.get("identity_path"), list):
                raise CollectorError(f"{source['id']}: json-set braucht items_path und identity_path")
        elif source["adapter"] == "json-value":
            if not isinstance(source.get("value_path"), list):
                raise CollectorError(f"{source['id']}: json-value braucht value_path")
        else:
            raise CollectorError(f"Unbekannter Adapter: {source['adapter']}")
    return config


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schema_version": STATE_SCHEMA_VERSION, "sources": {}}
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CollectorError(f"State kann nicht gelesen werden: {path}: {exc}") from exc
    if not isinstance(state, dict) or state.get("schema_version") != STATE_SCHEMA_VERSION:
        raise CollectorError(f"Nicht unterstützte state schema_version in {path}")
    if not isinstance(state.get("sources"), dict):
        raise CollectorError("State enthält kein sources-Objekt")
    return state


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent), text=True)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass


def render_ndjson(events: list[dict[str, Any]]) -> str:
    if not events:
        return ""
    return "".join(canonical_json(event) + "\n" for event in events)


def collect(config: dict[str, Any], state: dict[str, Any], observed_at: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    allowed_hosts = {str(host).lower() for host in config["allowed_hosts"]}
    timeout = float(config.get("timeout_seconds", DEFAULT_TIMEOUT_SECONDS))
    max_bytes = int(config.get("max_response_bytes", DEFAULT_MAX_BYTES))
    if timeout <= 0 or timeout > 60:
        raise CollectorError("timeout_seconds muss >0 und <=60 sein")
    if max_bytes <= 0 or max_bytes > 32 * 1024 * 1024:
        raise CollectorError("max_response_bytes muss >0 und <=32 MiB sein")

    observations: dict[str, Observation] = {}
    enabled_sources = [source for source in config["sources"] if source.get("enabled", True)]
    for source_cfg in enabled_sources:
        observations[source_cfg["id"]] = fetch_json(
            source_cfg["url"],
            allowed_hosts=allowed_hosts,
            timeout_seconds=timeout,
            max_bytes=max_bytes,
        )

    next_state = {"schema_version": STATE_SCHEMA_VERSION, "sources": dict(state["sources"])}
    all_events: list[dict[str, Any]] = []
    for source_cfg in enabled_sources:
        source_id = source_cfg["id"]
        previous = state["sources"].get(source_id)
        observation = observations[source_id]
        if source_cfg["adapter"] == "json-set":
            events, source_state = compare_json_set(source_cfg, observation, previous, observed_at)
        else:
            events, source_state = compare_json_value(source_cfg, observation, previous, observed_at)
        all_events.extend(events)
        next_state["sources"][source_id] = source_state
    return all_events, next_state


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Collect bounded external evidence as aussen.event NDJSON")
    parser.add_argument("--config", default="config/external-sources.json", help="JSON source configuration")
    parser.add_argument("--state", default=".state/external-evidence.json", help="Persistent comparison state")
    parser.add_argument("--next-state", default=None, help="Write candidate state here without advancing --state")
    parser.add_argument("--output", default="-", help="NDJSON output path, or - for stdout")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(list(argv if argv is not None else sys.argv[1:]))
    try:
        config = load_config(Path(args.config))
        state = load_state(Path(args.state))
        observed_at = utc_now()
        events, next_state = collect(config, state, observed_at)
        rendered = render_ndjson(events)
        if args.output == "-":
            sys.stdout.write(rendered)
            sys.stdout.flush()
        else:
            atomic_write_text(Path(args.output), rendered)
        state_target = Path(args.next_state or args.state)
        atomic_write_text(state_target, json.dumps(next_state, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
        print(
            f"aussensensor: sources={len(next_state['sources'])} events={len(events)} state={state_target}",
            file=sys.stderr,
        )
        return 0
    except CollectorError as exc:
        print(f"aussensensor: Fehler: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
