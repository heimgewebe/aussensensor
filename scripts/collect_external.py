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
import math
import os
import signal
import socket
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable

STATE_SCHEMA_VERSION = 1
CONFIG_SCHEMA_VERSION = 1
SET_IDENTITY_ENCODING = "canonical-json-scalar-v3-exact-decimal"
JSON_NUMBER_ENCODING = "exact-decimal-v1"
DEFAULT_MAX_BYTES = 8 * 1024 * 1024
DEFAULT_TIMEOUT_SECONDS = 15.0
USER_AGENT = "heimgewebe-aussensensor/1"


class CollectorError(RuntimeError):
    """Fail-closed collector error."""


class FetchDeadlineExceeded(TimeoutError):
    """A source exceeded the configured end-to-end wall-clock deadline."""


@contextmanager
def wall_clock_deadline(timeout_seconds: float):
    """Bound one fetch, including DNS/connect/read, by elapsed wall-clock time.

    urllib/socket timeouts bound individual blocking operations.  A peer that
    continuously trickles data can otherwise keep resetting that per-operation
    budget.  On the Linux/Unix runtime used by Aussensensor, ITIMER_REAL
    interrupts the whole synchronous fetch.  We fail closed rather than silently
    weakening the contract when that primitive is unavailable or already owned.
    """
    required = ("SIGALRM", "ITIMER_REAL", "getitimer", "setitimer")
    if any(not hasattr(signal, name) for name in required):
        raise CollectorError("Wall-Clock-Deadline wird auf dieser Plattform nicht unterstützt")

    try:
        previous_delay, previous_interval = signal.getitimer(signal.ITIMER_REAL)
    except (OSError, ValueError) as exc:
        raise CollectorError(f"Wall-Clock-Deadline kann nicht gelesen werden: {exc}") from exc
    if previous_delay > 0 or previous_interval > 0:
        raise CollectorError("Aktiver Prozess-Timer verhindert eine sichere Wall-Clock-Deadline")

    previous_handler = signal.getsignal(signal.SIGALRM)

    def _deadline_handler(_signum, _frame):
        raise FetchDeadlineExceeded(f"Gesamtzeitlimit von {timeout_seconds:g}s überschritten")

    try:
        signal.signal(signal.SIGALRM, _deadline_handler)
        signal.setitimer(signal.ITIMER_REAL, timeout_seconds)
    except (OSError, ValueError) as exc:
        try:
            signal.signal(signal.SIGALRM, previous_handler)
        except (OSError, ValueError):
            pass
        raise CollectorError(f"Wall-Clock-Deadline kann nicht aktiviert werden: {exc}") from exc

    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _reject_nonfinite_json_constant(value: str) -> Any:
    raise ValueError(f"Nicht-endliche JSON-Zahl ist nicht erlaubt: {value}")


def _parse_finite_json_decimal(value: str) -> Decimal:
    try:
        parsed = Decimal(value)
    except InvalidOperation as exc:
        raise ValueError(f"Ungültige JSON-Zahl: {value}") from exc
    if not parsed.is_finite():
        raise ValueError(f"Nicht-endliche JSON-Zahl ist nicht erlaubt: {value}")
    # Preserve the previous bounded-number contract: values that overflow the
    # runtime's ordinary float range are rejected, but accepted decimals keep
    # their exact lexical precision as Decimal instead of being rounded.
    try:
        binary_float = float(parsed)
    except (OverflowError, ValueError) as exc:
        raise ValueError(f"Nicht-endliche JSON-Zahl ist nicht erlaubt: {value}") from exc
    if not math.isfinite(binary_float):
        raise ValueError(f"Nicht-endliche JSON-Zahl ist nicht erlaubt: {value}")
    return parsed


def strict_json_loads(value: str) -> Any:
    return json.loads(
        value,
        parse_constant=_reject_nonfinite_json_constant,
        parse_float=_parse_finite_json_decimal,
    )


def _canonical_decimal_number(value: Decimal) -> str:
    """Return a compact exact JSON number for one finite Decimal value."""
    if not value.is_finite():
        raise CollectorError(f"Nicht-endliche JSON-Zahl ist nicht erlaubt: {value}")
    sign, raw_digits, exponent = value.as_tuple()
    digits = list(raw_digits)
    if not any(digits):
        return "0"
    while len(digits) > 1 and digits[-1] == 0:
        digits.pop()
        exponent += 1
    coefficient = "".join(str(digit) for digit in digits)
    adjusted = exponent + len(coefficient) - 1
    prefix = "-" if sign else ""

    # Fixed notation keeps common values readable without allowing compact tiny
    # exponents such as 1e-1000000 to explode into enormous serialized strings.
    if -6 <= adjusted <= 20:
        point = len(coefficient) + exponent
        if point <= 0:
            return prefix + "0." + ("0" * (-point)) + coefficient
        if point >= len(coefficient):
            return prefix + coefficient + ("0" * (point - len(coefficient)))
        return prefix + coefficient[:point] + "." + coefficient[point:]

    mantissa = coefficient[0]
    if len(coefficient) > 1:
        mantissa += "." + coefficient[1:]
    return f"{prefix}{mantissa}e{adjusted:+d}"


def _strict_json_number(value: int | float | Decimal) -> str:
    if isinstance(value, bool):
        raise CollectorError("Boolescher Wert ist keine JSON-Zahl")
    if isinstance(value, int):
        # Canonicalize integers together with decimal/exponent spellings while
        # keeping arbitrarily large JSON integers round-trippable.
        try:
            if math.isfinite(float(value)):
                return _canonical_decimal_number(Decimal(value))
        except OverflowError:
            pass
        return str(value)
    if isinstance(value, Decimal):
        return _canonical_decimal_number(value)
    if not math.isfinite(value):
        raise CollectorError(f"Nicht-endliche JSON-Zahl ist nicht erlaubt: {value}")
    return _canonical_decimal_number(Decimal(repr(value)))


def strict_json_dumps(
    value: Any, *, sort_keys: bool = False, indent: int | None = None
) -> str:
    """Serialize strict JSON while preserving lossless Decimal number tokens."""
    if indent is not None and indent < 0:
        raise CollectorError("JSON-Einrückung darf nicht negativ sein")

    def encode(current: Any, level: int) -> str:
        if current is None:
            return "null"
        if current is True:
            return "true"
        if current is False:
            return "false"
        if isinstance(current, str):
            return json.dumps(current, ensure_ascii=False)
        if isinstance(current, (int, float, Decimal)) and not isinstance(current, bool):
            return _strict_json_number(current)
        if isinstance(current, (list, tuple)):
            if not current:
                return "[]"
            rendered = [encode(item, level + 1) for item in current]
            if indent is None:
                return "[" + ",".join(rendered) + "]"
            child_pad = " " * (indent * (level + 1))
            pad = " " * (indent * level)
            return "[\n" + child_pad + (",\n" + child_pad).join(rendered) + "\n" + pad + "]"
        if isinstance(current, dict):
            items = list(current.items())
            if any(not isinstance(key, str) for key, _ in items):
                raise CollectorError("JSON-Objektschlüssel müssen Strings sein")
            if sort_keys:
                items.sort(key=lambda item: item[0])
            if not items:
                return "{}"
            rendered = [
                (json.dumps(key, ensure_ascii=False), encode(item, level + 1))
                for key, item in items
            ]
            if indent is None:
                return "{" + ",".join(key + ":" + item for key, item in rendered) + "}"
            child_pad = " " * (indent * (level + 1))
            pad = " " * (indent * level)
            body = (",\n" + child_pad).join(key + ": " + item for key, item in rendered)
            return "{\n" + child_pad + body + "\n" + pad + "}"
        raise CollectorError(
            f"Wert vom Typ {type(current).__name__} ist nicht strikt JSON-serialisierbar"
        )

    return encode(value, 0)


def canonical_json(value: Any) -> str:
    return strict_json_dumps(value, sort_keys=True)


def display_json(value: Any) -> str:
    return canonical_json(value)


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def observation_scope_sha256(source_cfg: dict[str, Any]) -> str:
    """Bind comparison state to the upstream and selectors that define its value."""
    adapter = source_cfg["adapter"]
    if adapter == "json-set":
        scope = {
            "adapter": adapter,
            "url": source_cfg["url"],
            "items_path": source_cfg["items_path"],
            "identity_path": source_cfg["identity_path"],
            "identity_encoding": SET_IDENTITY_ENCODING,
            "json_number_encoding": JSON_NUMBER_ENCODING,
        }
    elif adapter == "json-value":
        scope = {
            "adapter": adapter,
            "url": source_cfg["url"],
            "value_path": source_cfg["value_path"],
            "json_number_encoding": JSON_NUMBER_ENCODING,
        }
    else:
        raise CollectorError(f"Unbekannter Adapter: {adapter}")
    return sha256_text(canonical_json(scope))


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


def stable_event_id(
    source_id: str,
    change: str,
    identity: str,
    fingerprint: str,
    observation_scope_sha256_value: str,
) -> str:
    material = canonical_json(
        {
            "source_id": source_id,
            "change": change,
            "identity": identity,
            "fingerprint": fingerprint,
            "observation_scope_sha256": observation_scope_sha256_value,
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
    scope_sha256 = observation_scope_sha256(source_cfg)
    title = f"{label}: {change} {identity}"[:300]
    event = {
        "id": stable_event_id(
            str(source_cfg["id"]), change, identity, fingerprint, scope_sha256
        ),
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
            "observation_scope_sha256": scope_sha256,
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
    observed_at: str | None = None


def fetch_json(
    url: str,
    *,
    allowed_hosts: set[str],
    timeout_seconds: float,
    max_bytes: int,
) -> Observation:
    try:
        with wall_clock_deadline(timeout_seconds):
            validate_external_url(url, allowed_hosts)
            opener = urllib.request.build_opener(SafeRedirectHandler(allowed_hosts))
            request = urllib.request.Request(
                url,
                headers={"Accept": "application/json", "User-Agent": USER_AGENT},
                method="GET",
            )
            with opener.open(request, timeout=timeout_seconds) as response:
                length = response.headers.get("Content-Length")
                if length is not None and int(length) > max_bytes:
                    raise CollectorError(f"Antwort überschreitet Maximalgröße ({length} > {max_bytes})")
                raw = response.read(max_bytes + 1)
                observed_at = utc_now()
    except CollectorError:
        raise
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        raise CollectorError(f"Abruf fehlgeschlagen für {url}: {exc}") from exc
    if len(raw) > max_bytes:
        raise CollectorError(f"Antwort überschreitet Maximalgröße ({len(raw)} > {max_bytes})")
    try:
        payload = strict_json_loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise CollectorError(f"Quelle liefert kein gültiges UTF-8-JSON: {url}: {exc}") from exc
    return Observation(
        payload=payload,
        evidence_sha256=hashlib.sha256(raw).hexdigest(),
        byte_count=len(raw),
        observed_at=observed_at,
    )


def _identity_token(source_cfg: dict[str, Any], identity: Any, *, label: str) -> str:
    if not isinstance(identity, (str, int, float, Decimal)) or isinstance(identity, bool):
        raise CollectorError(f"{source_cfg['id']}: {label} ist kein skalarer JSON-Wert")
    return canonical_json(identity)


def _identity_index(source_cfg: dict[str, Any], payload: Any) -> dict[str, Any]:
    items = resolve_path(payload, source_cfg["items_path"])
    if not isinstance(items, list):
        raise CollectorError(f"{source_cfg['id']}: items_path liefert keine Liste")
    identities: dict[str, Any] = {}
    for item in items:
        identity = resolve_path(item, source_cfg["identity_path"])
        token = _identity_token(source_cfg, identity, label="Identität")
        identities[token] = identity
    return identities


def _identity_value_index(
    source_cfg: dict[str, Any], values: Any, *, label: str
) -> dict[str, Any]:
    if not isinstance(values, list):
        raise CollectorError(f"{source_cfg['id']}: {label} muss eine Liste sein")
    indexed: dict[str, Any] = {}
    for value in values:
        token = _identity_token(source_cfg, value, label=label)
        indexed[token] = value
    return indexed


def compare_json_set(
    source_cfg: dict[str, Any],
    observation: Observation,
    previous: dict[str, Any] | None,
    observed_at: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    current_items = _identity_index(source_cfg, observation.payload)
    current_set = set(current_items)
    previous_items = (
        _identity_value_index(source_cfg, previous.get("items", []), label="State items")
        if previous
        else {}
    )
    previous_set = set(previous_items)
    previous_missing_items = (
        _identity_value_index(
            source_cfg, previous.get("missing_expected", []), label="State missing_expected"
        )
        if previous
        else {}
    )
    previous_missing = set(previous_missing_items)
    expected_items = _identity_value_index(
        source_cfg, source_cfg.get("expected_items", []), label="expected_items"
    )
    expected = set(expected_items)
    current_missing = expected - current_set
    previous_observed_at = previous.get("observed_at") if previous else None
    events: list[dict[str, Any]] = []
    if previous:
        if source_cfg.get("report_added", False):
            for token in sorted(current_set - previous_set):
                if token in expected:
                    continue
                identity = current_items[token]
                events.append(
                    make_event(
                        source_cfg=source_cfg,
                        change="added",
                        identity=token,
                        summary=f"{display_json(identity)} ist neu in {source_cfg['source']} sichtbar.",
                        observed_at=observed_at,
                        evidence_sha256=observation.evidence_sha256,
                        previous_observed_at=previous_observed_at,
                        fingerprint=episode_fingerprint(
                            previous_observed_at, token, "absent", "present"
                        ),
                    )
                )
        if source_cfg.get("report_removed", True):
            for token in sorted(previous_set - current_set):
                if token in expected:
                    continue
                identity = previous_items[token]
                events.append(
                    make_event(
                        source_cfg=source_cfg,
                        change="removed",
                        identity=token,
                        summary=f"{display_json(identity)} ist aus {source_cfg['source']} verschwunden.",
                        observed_at=observed_at,
                        evidence_sha256=observation.evidence_sha256,
                        previous_observed_at=previous_observed_at,
                        fingerprint=episode_fingerprint(
                            previous_observed_at, token, "present", "absent"
                        ),
                    )
                )

    newly_missing = current_missing - previous_missing if previous else current_missing
    if previous or source_cfg.get("report_missing_on_baseline", True):
        for token in sorted(newly_missing):
            identity = expected_items[token]
            events.append(
                make_event(
                    source_cfg=source_cfg,
                    change="missing-expected",
                    identity=token,
                    summary=f"Erwarteter Wert {display_json(identity)} fehlt in {source_cfg['source']}.",
                    observed_at=observed_at,
                    evidence_sha256=observation.evidence_sha256,
                    previous_observed_at=previous_observed_at,
                    fingerprint=episode_fingerprint(
                        previous_observed_at, token, "expected", "missing"
                    ),
                )
            )

    if previous:
        restored_expected = (previous_missing - current_missing) & expected & current_set
        for token in sorted(restored_expected):
            identity = current_items[token]
            events.append(
                make_event(
                    source_cfg=source_cfg,
                    change="expected-restored",
                    identity=token,
                    summary=f"Erwarteter Wert {display_json(identity)} ist in {source_cfg['source']} wieder vorhanden.",
                    observed_at=observed_at,
                    evidence_sha256=observation.evidence_sha256,
                    previous_observed_at=previous_observed_at,
                    fingerprint=episode_fingerprint(
                        previous_observed_at, token, "missing", "expected"
                    ),
                )
            )

    state = {
        "adapter": "json-set",
        "observed_at": observed_at,
        "evidence_sha256": observation.evidence_sha256,
        "item_count": len(current_items),
        "items": [current_items[token] for token in sorted(current_set)],
        "missing_expected": [expected_items[token] for token in sorted(current_missing)],
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
    current_token = canonical_json(current_value)
    fingerprint = sha256_text(canonical_json({"value": current_value}))
    previous_observed_at = previous.get("observed_at") if previous else None
    previous_value = previous.get("value") if previous else None
    previous_token = canonical_json(previous_value) if previous else None
    events: list[dict[str, Any]] = []
    expected_configured = "expected_value" in source_cfg
    expected_value = source_cfg.get("expected_value")
    expected_token = canonical_json(expected_value) if expected_configured else None
    value_changed = bool(previous and previous_token != current_token)
    if not expected_configured and previous and previous.get("fingerprint") != fingerprint:
        before = previous_value
        transition_identity = f"{previous_token} -> {current_token}"
        events.append(
            make_event(
                source_cfg=source_cfg,
                change="changed",
                identity=transition_identity,
                summary=f"{source_cfg['source']} änderte sich von {display_json(before)} auf {display_json(current_value)}.",
                observed_at=observed_at,
                evidence_sha256=observation.evidence_sha256,
                previous_observed_at=previous_observed_at,
                fingerprint=episode_fingerprint(
                    previous_observed_at, transition_identity, before, current_value
                ),
                detail=detail,
            )
        )

    is_unexpected = expected_configured and current_token != expected_token
    was_unexpected = bool(previous and previous.get("unexpected", False))
    unexpected_value_changed = bool(previous and was_unexpected and value_changed)
    if is_unexpected and (previous or source_cfg.get("report_missing_on_baseline", True)) and (
        not was_unexpected or unexpected_value_changed
    ):
        events.append(
            make_event(
                source_cfg=source_cfg,
                change="unexpected-value",
                identity=current_token,
                summary=f"{source_cfg['source']} meldet {display_json(current_value)}; erwartet ist {display_json(expected_value)}.",
                observed_at=observed_at,
                evidence_sha256=observation.evidence_sha256,
                previous_observed_at=previous_observed_at,
                fingerprint=episode_fingerprint(
                    previous_observed_at,
                    current_token,
                    previous_value if previous else expected_value,
                    current_value,
                ),
                detail=detail,
            )
        )
    elif (
        previous
        and expected_configured
        and was_unexpected
        and not is_unexpected
        and value_changed
    ):
        events.append(
            make_event(
                source_cfg=source_cfg,
                change="expected-restored",
                identity=current_token,
                summary=f"{source_cfg['source']} entspricht wieder dem erwarteten Wert {display_json(expected_value)}.",
                observed_at=observed_at,
                evidence_sha256=observation.evidence_sha256,
                previous_observed_at=previous_observed_at,
                fingerprint=episode_fingerprint(
                    previous_observed_at, current_token, previous_value, current_value
                ),
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
        config = strict_json_loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
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
        state = strict_json_loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
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


def collect(
    config: dict[str, Any],
    state: dict[str, Any],
    observed_at: str | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
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
        scope_sha256 = observation_scope_sha256(source_cfg)
        previous = state["sources"].get(source_id)
        if previous is not None and previous.get("observation_scope_sha256") != scope_sha256:
            previous = None
        observation = observations[source_id]
        source_observed_at = observed_at or observation.observed_at or utc_now()
        if source_cfg["adapter"] == "json-set":
            events, source_state = compare_json_set(
                source_cfg, observation, previous, source_observed_at
            )
        else:
            events, source_state = compare_json_value(
                source_cfg, observation, previous, source_observed_at
            )
        source_state["observation_scope_sha256"] = scope_sha256
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
        events, next_state = collect(config, state)
        rendered = render_ndjson(events)
        if args.output == "-":
            sys.stdout.write(rendered)
            sys.stdout.flush()
        else:
            atomic_write_text(Path(args.output), rendered)
        state_target = Path(args.next_state or args.state)
        atomic_write_text(state_target, strict_json_dumps(next_state, sort_keys=True, indent=2) + "\n")
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
