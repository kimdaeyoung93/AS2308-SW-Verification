"""Build the deterministic Scalability Extension candidate pool.

The script consumes only extension batch artifacts and V1 validation/execution
rules. It does not read Manual, Mutation-result, Coverage, or SIL-result data.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import tempfile
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable

from build_ai_execution_spec import evaluation_resolution
from generate_test_cases import DEFAULT_MODEL, REASONING_EFFORT, build_candidate_schema
from tc_schema import (
    ALLOWED_REQUIREMENT_IDS,
    ALLOWED_TEST_DESIGN_TECHNIQUES,
    ALLOWED_TEST_SCOPES,
    TestCaseCandidate,
)
from validate_test_cases import validate_candidates


ROOT = Path(__file__).resolve().parents[1]
RESULT_ROOT = ROOT / "results" / "scalability_extension_v1"
BATCH_DIR = RESULT_ROOT / "candidate_batches"
PROTOCOL_PATH = ROOT / "docs" / "07_AI_Verification_Scalability_Protocol.md"
TEST_BASIS_PATH = ROOT / "ai" / "01_AI_Test_Basis.md"
PROMPT_PATH = ROOT / "ai" / "prompt" / "tc_generation_prompt.txt"
SCHEMA_PATH = ROOT / "ai" / "tc_schema.py"

BASE_BATCH_IDS = tuple(f"B{index:02d}" for index in range(1, 6))
FALLBACK_BATCH_ID = "B06"
REQUIREMENT_ORDER = (
    "REQ-VOLT-001",
    "REQ-TRK-001",
    "REQ-DIR-001",
    "REQ-REV-001",
)
FROZEN_POOL_SIZE = 100
BUDGETS = (10, 25, 50, 75, 100)
ORDERING_RULE_VERSION = "requirement-round-robin_sha256-v1"

RAW_JSON_PATH = RESULT_ROOT / "candidate_pool_raw.json"
RAW_CSV_PATH = RESULT_ROOT / "candidate_pool_raw.csv"
VALIDATION_PATH = RESULT_ROOT / "candidate_validation_results.csv"
SUMMARY_PATH = RESULT_ROOT / "candidate_validation_summary.csv"
DUPLICATE_PATH = RESULT_ROOT / "duplicate_report.csv"
RESOLUTION_PATH = RESULT_ROOT / "executable_resolution_results.csv"
FROZEN_POOL_PATH = RESULT_ROOT / "candidate_pool_frozen.csv"
BUDGET_PATH = RESULT_ROOT / "budget_definition.csv"
METADATA_PATH = RESULT_ROOT / "candidate_pool_metadata.json"

EXPECTED_FIELDS = (*TestCaseCandidate.REQUIRED_FIELDS, "test_scope")
RAW_CSV_FIELDS = (
    "batch_id",
    "batch_index",
    "provider",
    "model",
    "reasoning_effort",
    "response_id",
    "original_candidate_id",
    *EXPECTED_FIELDS,
)
VALIDATION_FIELDS = (
    "batch_id",
    "original_candidate_id",
    "extension_candidate_id",
    "schema_status",
    "semantic_status",
    "validation_status",
    "rejection_reason",
    "requirement_id",
    "test_scope",
    "test_design_technique",
    "input_values",
)
FROZEN_FIELDS = (
    "selection_order",
    "extension_candidate_id",
    "candidate_id",
    "batch_id",
    "original_candidate_id",
    "requirement_id",
    "test_scope",
    "test_design_technique",
    "test_objective",
    "precondition",
    "input_type",
    "input_values",
    "expected_behavior",
    "rationale",
    "waveform_type",
    "segment_count",
    "normalized_speed_values",
    "polarity_signature",
    "canonical_duplicate_key_sha256",
    "ordering_hash",
    "frozen_pool_sha256",
)


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest().upper()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def atomic_write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False, allow_nan=False)
            handle.write("\n")
            temporary_path = Path(handle.name)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def atomic_write_csv(path: Path, fieldnames: Iterable[str], rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8-sig",
            newline="",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as handle:
            writer = csv.DictWriter(handle, fieldnames=list(fieldnames), extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
            temporary_path = Path(handle.name)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def batch_paths(batch_id: str) -> tuple[Path, Path]:
    number = int(batch_id[1:])
    return (
        BATCH_DIR / f"batch_{number:02d}_raw.json",
        BATCH_DIR / f"batch_{number:02d}_metadata.json",
    )


def discover_batch_ids() -> tuple[str, ...]:
    for path in sorted(BATCH_DIR.glob("batch_*_raw.json")):
        match = re.fullmatch(r"batch_(\d{2})_raw\.json", path.name)
        if match and int(match.group(1)) > 6:
            raise ValueError(f"B07 or later is prohibited: {path}")
    missing = [batch_id for batch_id in BASE_BATCH_IDS if not batch_paths(batch_id)[0].is_file()]
    if missing:
        raise FileNotFoundError("Missing required base batch raw files: " + ", ".join(missing))
    ids = list(BASE_BATCH_IDS)
    fallback_raw, _ = batch_paths(FALLBACK_BATCH_ID)
    if fallback_raw.is_file():
        ids.append(FALLBACK_BATCH_ID)
    return tuple(ids)


def load_batch_rows(batch_ids: tuple[str, ...]) -> tuple[list[dict[str, Any]], dict[str, str]]:
    rows: list[dict[str, Any]] = []
    source_hashes: dict[str, str] = {}
    for batch_id in batch_ids:
        raw_path, metadata_path = batch_paths(batch_id)
        if not metadata_path.is_file():
            raise FileNotFoundError(f"Missing metadata for {batch_id}: {metadata_path}")
        raw_payload = json.loads(raw_path.read_text(encoding="utf-8"))
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        if raw_payload.get("batch_id") != batch_id or metadata.get("batch_id") != batch_id:
            raise ValueError(f"Batch identity mismatch in {batch_id} artifacts")
        if (
            metadata.get("provider") != "OpenAI"
            or metadata.get("api_type") != "Responses API"
            or metadata.get("model") != DEFAULT_MODEL
            or metadata.get("reasoning_effort") != REASONING_EFFORT
        ):
            raise ValueError(f"{batch_id} does not use the frozen V1 generation configuration")
        if not str(metadata.get("response_id", "")).strip():
            raise ValueError(f"{batch_id} metadata has no response_id")
        candidates = raw_payload.get("candidates")
        if not isinstance(candidates, list) or len(candidates) != 25:
            raise ValueError(f"{batch_id} must contain exactly 25 candidates")
        if metadata.get("candidate_count_returned") != 25:
            raise ValueError(f"{batch_id} metadata candidate count is not 25")
        source_hashes[str(raw_path.relative_to(ROOT))] = sha256_file(raw_path)
        source_hashes[str(metadata_path.relative_to(ROOT))] = sha256_file(metadata_path)
        for index, raw_candidate in enumerate(candidates, start=1):
            if not isinstance(raw_candidate, dict):
                raw_candidate = {"_invalid_raw_value": raw_candidate}
            candidate = {key: raw_candidate.get(key) for key in EXPECTED_FIELDS}
            original_id = raw_candidate.get("original_candidate_id", raw_candidate.get("candidate_id", ""))
            rows.append(
                {
                    "batch_id": batch_id,
                    "batch_index": index,
                    "provider": metadata.get("provider", ""),
                    "model": metadata.get("model", ""),
                    "reasoning_effort": metadata.get("reasoning_effort", ""),
                    "response_id": metadata.get("response_id", ""),
                    "original_candidate_id": str(original_id),
                    "candidate": candidate,
                    "raw_keys": sorted(raw_candidate.keys()),
                }
            )
    return rows, source_hashes


def filename_safe(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip()).strip("-.")
    if not safe:
        raise ValueError("candidate_id cannot be converted to a safe global ID")
    return safe


def extension_id(batch_id: str, original_id: str) -> str:
    return f"EXT-{batch_id}-{filename_safe(original_id)}"


def schema_errors(candidate: dict[str, Any], raw_keys: list[str]) -> list[str]:
    errors: list[str] = []
    allowed_raw_keys = set(EXPECTED_FIELDS) | {"original_candidate_id"}
    unexpected = sorted(set(raw_keys) - allowed_raw_keys)
    missing = [field for field in EXPECTED_FIELDS if candidate.get(field) is None]
    if unexpected:
        errors.append("Unexpected field(s): " + ", ".join(unexpected))
    if missing:
        errors.append("Missing schema field(s): " + ", ".join(missing))
    for field in set(EXPECTED_FIELDS) - {"input_values"}:
        value = candidate.get(field)
        if value is not None and (not isinstance(value, str) or not value.strip()):
            errors.append(f"{field} must be nonempty text")
    values = candidate.get("input_values")
    if values is not None:
        if not isinstance(values, list) or not values:
            errors.append("input_values must be a nonempty array")
        elif any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            for value in values
        ):
            errors.append("input_values must contain only finite numbers")
    if candidate.get("requirement_id") not in ALLOWED_REQUIREMENT_IDS:
        errors.append("requirement_id is outside the V1 schema enum")
    if candidate.get("test_scope") not in ALLOWED_TEST_SCOPES:
        errors.append("test_scope is outside the V1 schema enum")
    if candidate.get("test_design_technique") not in ALLOWED_TEST_DESIGN_TECHNIQUES:
        errors.append("test_design_technique is outside the V1 schema enum")
    return list(dict.fromkeys(errors))


def normalize_number(value: float) -> str:
    try:
        decimal_value = Decimal(str(value))
    except InvalidOperation as error:
        raise ValueError(f"Cannot normalize SpeedRef value: {value!r}") from error
    if not decimal_value.is_finite():
        raise ValueError("SpeedRef values must be finite")
    if decimal_value == 0:
        return "0"
    normalized = format(decimal_value.normalize(), "f")
    return normalized.rstrip("0").rstrip(".") if "." in normalized else normalized


def sign_name(value: float) -> str:
    return "POSITIVE" if value > 0 else "NEGATIVE" if value < 0 else "ZERO"


def waveform_type(values: list[float]) -> str:
    if len(values) == 1:
        return "CONSTANT"
    nonzero_signs = [1 if value > 0 else -1 for value in values if value != 0]
    if any(a != b for a, b in zip(nonzero_signs, nonzero_signs[1:])):
        return "REVERSAL_SEQUENCE"
    return "MULTI_SEGMENT_CONSTANT_SEQUENCE"


def enrich_record(record: dict[str, Any]) -> dict[str, Any]:
    candidate = record["parsed_candidate"].to_dict()
    values = candidate["input_values"]
    normalized = [normalize_number(value) for value in values]
    kind = waveform_type(values)
    duplicate_key = (
        candidate["requirement_id"],
        kind,
        normalized,
        len(values),
    )
    enriched = {
        **record,
        "candidate": candidate,
        "normalized_speed_values": normalized,
        "waveform_type": kind,
        "segment_count": len(values),
        "polarity_signature": [sign_name(value) for value in values],
        "duplicate_key": duplicate_key,
        "canonical_duplicate_key_sha256": sha256_text(canonical_json(duplicate_key)),
    }
    return enriched


def validate_and_normalize(raw_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    seen_extension_ids: set[str] = set()
    seen_original_ids_by_batch: set[tuple[str, str]] = set()
    for raw in raw_rows:
        candidate = raw["candidate"]
        original_id = raw["original_candidate_id"].strip()
        errors = schema_errors(candidate, raw["raw_keys"])
        if original_id != str(candidate.get("candidate_id", "")).strip():
            errors.append("original_candidate_id does not match candidate_id")
        global_id = ""
        try:
            global_id = extension_id(raw["batch_id"], original_id)
        except ValueError as error:
            errors.append(str(error))
        local_id_key = (raw["batch_id"], original_id.casefold())
        if local_id_key in seen_original_ids_by_batch:
            errors.append("Duplicate original_candidate_id within batch")
        if global_id and global_id in seen_extension_ids:
            errors.append("extension_candidate_id collision")
        seen_original_ids_by_batch.add(local_id_key)
        if global_id:
            seen_extension_ids.add(global_id)

        record: dict[str, Any] = {
            **raw,
            "extension_candidate_id": global_id,
            "schema_status": "VALID" if not errors else "REJECTED",
            "semantic_status": "NOT_EVALUATED",
            "validation_status": "REJECTED" if errors else "PENDING",
            "rejection_reason": "; ".join(errors),
        }
        if not errors:
            semantic = validate_candidates([candidate])[0]
            record["semantic_status"] = semantic.status
            if semantic.status != "VALID" or semantic.candidate is None:
                record["validation_status"] = "REJECTED"
                record["rejection_reason"] = semantic.rejection_reason
            else:
                record["validation_status"] = "VALID"
                record["parsed_candidate"] = semantic.candidate
                record = enrich_record(record)
        output.append(record)
    return output


def apply_duplicate_detection(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    valid = [record for record in records if record["validation_status"] == "VALID"]
    valid.sort(key=lambda row: (row["batch_id"], row["original_candidate_id"]))
    representatives: dict[str, str] = {}
    for record in valid:
        key_hash = record["canonical_duplicate_key_sha256"]
        representative = representatives.get(key_hash)
        if representative is None:
            representatives[key_hash] = record["extension_candidate_id"]
            record["duplicate_status"] = "UNIQUE"
            record["representative_candidate_id"] = record["extension_candidate_id"]
        else:
            record["duplicate_status"] = "DUPLICATE"
            record["representative_candidate_id"] = representative
    for record in records:
        record.setdefault("duplicate_status", "NOT_EVALUATED")
        record.setdefault("representative_candidate_id", "")
    return records


def apply_executable_check(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    for record in records:
        if record["validation_status"] != "VALID":
            record["executable_status"] = "NOT_EVALUATED_INVALID"
            record["executable_reason"] = record["rejection_reason"]
            continue
        if record["duplicate_status"] == "DUPLICATE":
            record["executable_status"] = "NOT_EVALUATED_DUPLICATE"
            record["executable_reason"] = "Duplicate of " + record["representative_candidate_id"]
            continue
        candidate = record["candidate"]
        try:
            evaluation_resolution(candidate["requirement_id"], candidate["input_values"])
        except (TypeError, ValueError) as error:
            record["executable_status"] = "REJECTED"
            record["executable_reason"] = str(error)
        else:
            record["executable_status"] = "ELIGIBLE"
            record["executable_reason"] = ""
    return records


def ordering_hash(record: dict[str, Any]) -> str:
    candidate = record["candidate"]
    payload = {
        "requirement_id": candidate["requirement_id"],
        "test_scope": candidate["test_scope"],
        "test_design_technique": candidate["test_design_technique"],
        "waveform_type": record["waveform_type"],
        "normalized_ordered_speedref_sequence": record["normalized_speed_values"],
        "segment_count": record["segment_count"],
        "extension_candidate_id": record["extension_candidate_id"],
    }
    return sha256_text(canonical_json(payload))


def order_eligible(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    buckets: dict[str, list[dict[str, Any]]] = {requirement: [] for requirement in REQUIREMENT_ORDER}
    for record in records:
        if record.get("executable_status") != "ELIGIBLE":
            continue
        record["ordering_hash"] = ordering_hash(record)
        buckets[record["candidate"]["requirement_id"]].append(record)
    for bucket in buckets.values():
        bucket.sort(key=lambda row: (row["ordering_hash"], row["extension_candidate_id"]))

    ordered: list[dict[str, Any]] = []
    positions = {requirement: 0 for requirement in REQUIREMENT_ORDER}
    while True:
        added = False
        for requirement in REQUIREMENT_ORDER:
            position = positions[requirement]
            bucket = buckets[requirement]
            if position < len(bucket):
                ordered.append(bucket[position])
                positions[requirement] += 1
                added = True
        if not added:
            break
    return ordered


def process_rows(raw_rows: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    records = validate_and_normalize(raw_rows)
    records = apply_duplicate_detection(records)
    records = apply_executable_check(records)
    return records, order_eligible(records)


def pool_hash(frozen: list[dict[str, Any]]) -> str:
    payload = [
        {
            "selection_order": index,
            "extension_candidate_id": row["extension_candidate_id"],
            "candidate": row["candidate"],
            "canonical_duplicate_key_sha256": row["canonical_duplicate_key_sha256"],
            "ordering_hash": row["ordering_hash"],
        }
        for index, row in enumerate(frozen, start=1)
    ]
    return sha256_text(canonical_json(payload))


def raw_output_rows(raw_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for row in raw_rows:
        candidate = row["candidate"]
        output.append(
            {
                **{key: row[key] for key in RAW_CSV_FIELDS if key in row and key not in EXPECTED_FIELDS},
                **candidate,
                "input_values": canonical_json(candidate.get("input_values")),
            }
        )
    return output


def raw_json_rows(raw_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "batch_id": row["batch_id"],
            "batch_index": row["batch_index"],
            "provider": row["provider"],
            "model": row["model"],
            "reasoning_effort": row["reasoning_effort"],
            "response_id": row["response_id"],
            "original_candidate_id": row["original_candidate_id"],
            **row["candidate"],
        }
        for row in raw_rows
    ]


def validation_output_rows(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows = []
    for record in records:
        candidate = record["candidate"]
        rows.append(
            {
                "batch_id": record["batch_id"],
                "original_candidate_id": record["original_candidate_id"],
                "extension_candidate_id": record["extension_candidate_id"],
                "schema_status": record["schema_status"],
                "semantic_status": record["semantic_status"],
                "validation_status": record["validation_status"],
                "rejection_reason": record["rejection_reason"],
                "requirement_id": candidate.get("requirement_id", ""),
                "test_scope": candidate.get("test_scope", ""),
                "test_design_technique": candidate.get("test_design_technique", ""),
                "input_values": canonical_json(candidate.get("input_values")),
            }
        )
    return rows


def duplicate_output_rows(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    fields = (
        "extension_candidate_id",
        "representative_candidate_id",
        "duplicate_status",
        "canonical_duplicate_key_sha256",
        "requirement_id",
        "waveform_type",
        "normalized_speed_values",
        "segment_count",
    )
    rows = []
    for record in records:
        if record["validation_status"] != "VALID":
            continue
        rows.append(
            {
                "extension_candidate_id": record["extension_candidate_id"],
                "representative_candidate_id": record["representative_candidate_id"],
                "duplicate_status": record["duplicate_status"],
                "canonical_duplicate_key_sha256": record["canonical_duplicate_key_sha256"],
                "requirement_id": record["candidate"]["requirement_id"],
                "waveform_type": record["waveform_type"],
                "normalized_speed_values": canonical_json(record["normalized_speed_values"]),
                "segment_count": record["segment_count"],
            }
        )
    return list(fields), rows


def resolution_output_rows(records: list[dict[str, Any]]) -> tuple[list[str], list[dict[str, Any]]]:
    fields = [
        "extension_candidate_id",
        "requirement_id",
        "duplicate_status",
        "executable_status",
        "executable_reason",
        "waveform_type",
        "segment_count",
        "input_values",
    ]
    rows = []
    for record in records:
        candidate = record["candidate"]
        rows.append(
            {
                "extension_candidate_id": record["extension_candidate_id"],
                "requirement_id": candidate.get("requirement_id", ""),
                "duplicate_status": record["duplicate_status"],
                "executable_status": record["executable_status"],
                "executable_reason": record["executable_reason"],
                "waveform_type": record.get("waveform_type", ""),
                "segment_count": record.get("segment_count", ""),
                "input_values": canonical_json(candidate.get("input_values")),
            }
        )
    return fields, rows


def frozen_output_rows(frozen: list[dict[str, Any]], frozen_hash: str) -> list[dict[str, Any]]:
    rows = []
    for index, record in enumerate(frozen, start=1):
        candidate = record["candidate"]
        rows.append(
            {
                "selection_order": index,
                "extension_candidate_id": record["extension_candidate_id"],
                "candidate_id": record["extension_candidate_id"],
                "batch_id": record["batch_id"],
                "original_candidate_id": record["original_candidate_id"],
                "requirement_id": candidate["requirement_id"],
                "test_scope": candidate["test_scope"],
                "test_design_technique": candidate["test_design_technique"],
                "test_objective": candidate["test_objective"],
                "precondition": candidate["precondition"],
                "input_type": candidate["input_type"],
                "input_values": canonical_json(candidate["input_values"]),
                "expected_behavior": candidate["expected_behavior"],
                "rationale": candidate["rationale"],
                "waveform_type": record["waveform_type"],
                "segment_count": record["segment_count"],
                "normalized_speed_values": canonical_json(record["normalized_speed_values"]),
                "polarity_signature": canonical_json(record["polarity_signature"]),
                "canonical_duplicate_key_sha256": record["canonical_duplicate_key_sha256"],
                "ordering_hash": record["ordering_hash"],
                "frozen_pool_sha256": frozen_hash,
            }
        )
    return rows


def write_artifacts(
    batch_ids: tuple[str, ...],
    raw_rows: list[dict[str, Any]],
    records: list[dict[str, Any]],
    ordered: list[dict[str, Any]],
    source_hashes: dict[str, str],
) -> str:
    result_status: str
    fallback_allowed = len(batch_ids) == 5 and len(ordered) < FROZEN_POOL_SIZE
    if len(ordered) >= FROZEN_POOL_SIZE:
        result_status = "FROZEN_POOL_READY"
    elif fallback_allowed:
        result_status = "B06_REQUIRED"
    else:
        result_status = "POOL_TARGET_NOT_MET"

    raw_payload = {
        "batch_ids": list(batch_ids),
        "candidate_count": len(raw_rows),
        "candidates": raw_json_rows(raw_rows),
    }
    atomic_write_json(RAW_JSON_PATH, raw_payload)
    atomic_write_csv(RAW_CSV_PATH, RAW_CSV_FIELDS, raw_output_rows(raw_rows))
    atomic_write_csv(VALIDATION_PATH, VALIDATION_FIELDS, validation_output_rows(records))

    duplicate_fields, duplicate_rows = duplicate_output_rows(records)
    atomic_write_csv(DUPLICATE_PATH, duplicate_fields, duplicate_rows)
    resolution_fields, resolution_rows = resolution_output_rows(records)
    atomic_write_csv(RESOLUTION_PATH, resolution_fields, resolution_rows)

    schema_valid = sum(row["schema_status"] == "VALID" for row in records)
    semantic_valid = sum(row["semantic_status"] == "VALID" for row in records)
    duplicate_count = sum(row["duplicate_status"] == "DUPLICATE" for row in records)
    frozen_hash = ""
    frozen_count = 0
    if result_status == "FROZEN_POOL_READY":
        frozen = ordered[:FROZEN_POOL_SIZE]
        frozen_hash = pool_hash(frozen)
        frozen_count = len(frozen)
        atomic_write_csv(FROZEN_POOL_PATH, FROZEN_FIELDS, frozen_output_rows(frozen, frozen_hash))
        budget_rows = [
            {
                "budget": budget,
                "start_index": 1,
                "end_index": budget,
                "selection_rule": "ordered_prefix",
                "frozen_pool_sha256": frozen_hash,
            }
            for budget in BUDGETS
        ]
        atomic_write_csv(
            BUDGET_PATH,
            ("budget", "start_index", "end_index", "selection_rule", "frozen_pool_sha256"),
            budget_rows,
        )

    source_files = (PROTOCOL_PATH, TEST_BASIS_PATH, PROMPT_PATH, SCHEMA_PATH)
    for path in source_files:
        if not path.is_file():
            raise FileNotFoundError(f"Required source file not found: {path}")
        source_hashes[str(path.relative_to(ROOT))] = sha256_file(path)
    summary = {
        "status": result_status,
        "batch_ids": ",".join(batch_ids),
        "batch_count": len(batch_ids),
        "raw_candidate_count": len(raw_rows),
        "schema_valid_count": schema_valid,
        "semantic_valid_count": semantic_valid,
        "duplicate_count": duplicate_count,
        "eligible_unique_executable_count": len(ordered),
        "frozen_candidate_count": frozen_count,
        "fallback_b06_allowed": str(fallback_allowed).lower(),
        "frozen_pool_sha256": frozen_hash,
        "ordering_rule_version": ORDERING_RULE_VERSION,
    }
    atomic_write_csv(SUMMARY_PATH, summary.keys(), [summary])
    metadata = {
        **summary,
        "source_file_sha256": dict(sorted(source_hashes.items())),
        "artifact_sha256": {
            str(path.relative_to(ROOT)): sha256_file(path)
            for path in (
                RAW_JSON_PATH,
                RAW_CSV_PATH,
                VALIDATION_PATH,
                SUMMARY_PATH,
                DUPLICATE_PATH,
                RESOLUTION_PATH,
            )
        },
    }
    if result_status == "FROZEN_POOL_READY":
        metadata["artifact_sha256"][str(FROZEN_POOL_PATH.relative_to(ROOT))] = sha256_file(FROZEN_POOL_PATH)
        metadata["artifact_sha256"][str(BUDGET_PATH.relative_to(ROOT))] = sha256_file(BUDGET_PATH)
    atomic_write_json(METADATA_PATH, metadata)
    return result_status


def synthetic_candidate(candidate_id: str, requirement: str, values: list[float]) -> dict[str, Any]:
    return {
        "candidate_id": candidate_id,
        "requirement_id": requirement,
        "test_objective": f"Exercise {requirement}",
        "precondition": "Frozen healthy MIL baseline is available",
        "input_type": "piecewise constant" if len(values) > 1 else "constant",
        "input_values": values,
        "expected_behavior": "Behavior follows the referenced requirement",
        "test_design_technique": "Scenario-Based",
        "rationale": "Synthetic deterministic pipeline check",
        "test_scope": "stress" if requirement == "REQ-VOLT-001" else "nominal",
    }


def self_check() -> None:
    rows: list[dict[str, Any]] = []
    for batch_index, requirement in enumerate(REQUIREMENT_ORDER, start=1):
        values = [5.0, -5.0] if requirement == "REQ-REV-001" else [float(batch_index)]
        for suffix in ("A", "B"):
            candidate = synthetic_candidate(f"TC-{batch_index}-{suffix}", requirement, values if suffix == "A" else [value + 0.25 for value in values])
            rows.append(
                {
                    "batch_id": "B01",
                    "batch_index": len(rows) + 1,
                    "provider": "OpenAI",
                    "model": "synthetic",
                    "reasoning_effort": "medium",
                    "response_id": "synthetic",
                    "original_candidate_id": candidate["candidate_id"],
                    "candidate": candidate,
                    "raw_keys": sorted(candidate),
                }
            )
    duplicate = synthetic_candidate("TC-DUP", "REQ-VOLT-001", [1.0])
    rows.append(
        {
            "batch_id": "B02",
            "batch_index": 1,
            "provider": "OpenAI",
            "model": "synthetic",
            "reasoning_effort": "medium",
            "response_id": "synthetic",
            "original_candidate_id": duplicate["candidate_id"],
            "candidate": duplicate,
            "raw_keys": sorted(duplicate),
        }
    )
    _, first = process_rows(rows)
    _, second = process_rows(rows)
    assert [row["extension_candidate_id"] for row in first] == [row["extension_candidate_id"] for row in second]
    assert len(first) == 8
    assert [row["candidate"]["requirement_id"] for row in first[:4]] == list(REQUIREMENT_ORDER)
    processed, _ = process_rows(rows)
    assert sum(row["duplicate_status"] == "DUPLICATE" for row in processed) == 1
    print("Scalability candidate pool synthetic self-check: PASS")
    print("deterministic ordering: PASS")
    print("protocol duplicate detection: PASS")
    print("files written: false")


def dry_run() -> None:
    schema = build_candidate_schema()
    assert schema["properties"]["candidates"]["minItems"] == 25
    for path in (PROTOCOL_PATH, TEST_BASIS_PATH, PROMPT_PATH, SCHEMA_PATH):
        if not path.is_file():
            raise FileNotFoundError(f"Required file not found: {path}")
    available = []
    if BATCH_DIR.is_dir():
        available = sorted(path.name for path in BATCH_DIR.glob("batch_*_raw.json"))
    print("Scalability candidate pool builder - DRY RUN")
    print(f"batch input directory: {BATCH_DIR}")
    print(f"available raw batches: {', '.join(available) if available else 'none'}")
    print(f"frozen pool target: {FROZEN_POOL_SIZE}")
    print(f"budgets: {', '.join(map(str, BUDGETS))}")
    print(f"ordering rule: {ORDERING_RULE_VERSION}")
    print("V1 schema availability: PASS")
    print("files written: false")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--dry-run", action="store_true")
    actions.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    try:
        if args.dry_run:
            dry_run()
            return 0
        if args.self_check:
            self_check()
            return 0
        batch_ids = discover_batch_ids()
        raw_rows, source_hashes = load_batch_rows(batch_ids)
        if FALLBACK_BATCH_ID in batch_ids:
            base_rows = [row for row in raw_rows if row["batch_id"] in BASE_BATCH_IDS]
            _, base_ordered = process_rows(base_rows)
            if len(base_ordered) >= FROZEN_POOL_SIZE:
                raise ValueError(
                    "B06 is not permitted because B01-B05 already provide "
                    f"{len(base_ordered)} eligible unique executable candidates"
                )
        records, ordered = process_rows(raw_rows)
        status = write_artifacts(batch_ids, raw_rows, records, ordered, source_hashes)
        print(f"candidate pool status: {status}")
        print(f"raw candidates: {len(raw_rows)}")
        print(f"eligible unique executable candidates: {len(ordered)}")
        print(f"results: {RESULT_ROOT}")
        return 0 if status in {"FROZEN_POOL_READY", "B06_REQUIRED"} else 2
    except Exception as error:
        print(f"ERROR: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
