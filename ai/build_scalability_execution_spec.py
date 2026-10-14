"""Resolve the frozen 100-candidate scalability pool for MIL execution.

The adapter preserves candidate intent and input values. It writes execution
data only; it does not run MATLAB, Simulink, an Oracle, or Mutation Testing.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import tempfile
from pathlib import Path
from typing import Any, Iterable

from build_ai_execution_spec import (
    ORACLE_MAPPING,
    SAMPLE_TIME_S,
    SEGMENT_DURATION_S,
    TERMINAL_EVALUATION_WINDOW_S,
    evaluation_resolution,
    resolved_waveform,
)


ROOT = Path(__file__).resolve().parents[1]
RESULT_ROOT = ROOT / "results" / "scalability_extension_v1"
INPUT_PATH = RESULT_ROOT / "candidate_pool_frozen.csv"
OUTPUT_PATH = RESULT_ROOT / "candidate_execution_spec_resolved.csv"
METADATA_PATH = RESULT_ROOT / "candidate_execution_spec_metadata.json"
EXPECTED_COUNT = 100

OUTPUT_FIELDS = (
    "selection_order",
    "candidate_id",
    "extension_candidate_id",
    "batch_id",
    "original_candidate_id",
    "requirement_id",
    "test_scope",
    "test_design_technique",
    "test_objective",
    "precondition",
    "input_type",
    "original_input_values",
    "expected_behavior",
    "rationale",
    "waveform_type",
    "segment_count",
    "segment_duration_s",
    "total_duration_s",
    "sample_time_s",
    "resolved_waveform",
    "oracle_mapping",
    "applicability_check_required",
    "evaluation_scope",
    "evaluation_window_s",
    "evaluation_intervals_s",
    "ambiguity_status",
    "execution_status",
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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


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


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
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


def parse_values(raw: str, candidate_id: str) -> list[float]:
    try:
        values = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError(f"{candidate_id}: input_values is not valid JSON") from error
    if not isinstance(values, list) or not values:
        raise ValueError(f"{candidate_id}: input_values must be a nonempty array")
    parsed: list[float] = []
    for value in values:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"{candidate_id}: input_values must be numeric")
        numeric = float(value)
        if not math.isfinite(numeric):
            raise ValueError(f"{candidate_id}: input_values must be finite")
        parsed.append(numeric)
    return parsed


def load_frozen_rows() -> tuple[list[dict[str, str]], str]:
    if not INPUT_PATH.is_file():
        raise FileNotFoundError(f"Frozen candidate pool not found: {INPUT_PATH}")
    with INPUT_PATH.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != EXPECTED_COUNT:
        raise ValueError(f"Expected {EXPECTED_COUNT} frozen candidates, found {len(rows)}")
    orders = [int(row["selection_order"]) for row in rows]
    if orders != list(range(1, EXPECTED_COUNT + 1)):
        raise ValueError("selection_order must be the integers 1 through 100")
    ids = [row["extension_candidate_id"].strip() for row in rows]
    if any(not value for value in ids) or len(ids) != len(set(ids)):
        raise ValueError("extension_candidate_id values must be nonempty and unique")
    hashes = {row.get("frozen_pool_sha256", "").strip() for row in rows}
    if len(hashes) != 1 or not next(iter(hashes)):
        raise ValueError("Frozen pool rows must contain one nonempty pool hash")
    return rows, next(iter(hashes))


def resolve_row(row: dict[str, str]) -> dict[str, Any]:
    candidate_id = row["extension_candidate_id"].strip()
    requirement_id = row["requirement_id"].strip()
    values = parse_values(row["input_values"], candidate_id)
    segment_count = int(row["segment_count"])
    if segment_count != len(values):
        raise ValueError(f"{candidate_id}: segment_count does not match input_values")
    if requirement_id not in ORACLE_MAPPING:
        raise ValueError(f"{candidate_id}: unsupported Requirement ID {requirement_id}")

    scope, window_s, intervals, gate_required = evaluation_resolution(requirement_id, values)
    waveform = resolved_waveform(values)
    return {
        "selection_order": int(row["selection_order"]),
        "candidate_id": candidate_id,
        "extension_candidate_id": candidate_id,
        "batch_id": row["batch_id"],
        "original_candidate_id": row["original_candidate_id"],
        "requirement_id": requirement_id,
        "test_scope": row["test_scope"],
        "test_design_technique": row["test_design_technique"],
        "test_objective": row["test_objective"],
        "precondition": row["precondition"],
        "input_type": row["input_type"],
        "original_input_values": row["input_values"],
        "expected_behavior": row["expected_behavior"],
        "rationale": row["rationale"],
        "waveform_type": row["waveform_type"],
        "segment_count": segment_count,
        "segment_duration_s": SEGMENT_DURATION_S,
        "total_duration_s": segment_count * SEGMENT_DURATION_S,
        "sample_time_s": SAMPLE_TIME_S,
        "resolved_waveform": canonical_json(waveform),
        "oracle_mapping": ORACLE_MAPPING[requirement_id],
        "applicability_check_required": str(gate_required).lower(),
        "evaluation_scope": scope,
        "evaluation_window_s": window_s,
        "evaluation_intervals_s": canonical_json(intervals),
        "ambiguity_status": "NO_UNRESOLVED_AMBIGUITY",
        "execution_status": "NOT_EXECUTED",
        "frozen_pool_sha256": row["frozen_pool_sha256"],
    }


def build_rows(source_rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    rows = [resolve_row(row) for row in source_rows]
    if any(row["execution_status"] != "NOT_EXECUTED" for row in rows):
        raise AssertionError("Execution spec generation must not assign test results")
    return rows


def self_check() -> None:
    base = {
        "selection_order": "1",
        "extension_candidate_id": "EXT-B01-SYNTHETIC",
        "batch_id": "B01",
        "original_candidate_id": "SYNTHETIC",
        "test_scope": "nominal",
        "test_design_technique": "Scenario-Based",
        "test_objective": "Synthetic adapter check",
        "precondition": "Healthy baseline",
        "input_type": "piecewise constant",
        "expected_behavior": "Follow the requirement",
        "rationale": "Self-check only",
        "waveform_type": "REVERSAL_SEQUENCE",
        "frozen_pool_sha256": "SYNTHETIC_HASH",
    }
    checks = (
        ("REQ-VOLT-001", "[5]", "1", "Voltage Oracle"),
        ("REQ-TRK-001", "[2]", "1", "Tracking Oracle"),
        ("REQ-DIR-001", "[-5]", "1", "Direction Oracle"),
        ("REQ-REV-001", "[5,-5]", "2", "Direction + Tracking"),
    )
    for index, (requirement, values, segments, oracle) in enumerate(checks, start=1):
        row = {
            **base,
            "selection_order": str(index),
            "extension_candidate_id": f"EXT-SYN-{index}",
            "requirement_id": requirement,
            "input_values": values,
            "segment_count": segments,
        }
        resolved = resolve_row(row)
        assert resolved["oracle_mapping"] == oracle
        assert resolved["segment_duration_s"] == 2.0
        if requirement != "REQ-VOLT-001":
            assert resolved["evaluation_window_s"] == 0.05
    print("Scalability execution adapter synthetic self-check: PASS")
    print("2.0 s segment semantics: PASS")
    print("0.05 s terminal window semantics: PASS")
    print("Requirement-to-Oracle mapping: PASS")
    print("files written: false")


def dry_run() -> None:
    print("Scalability execution spec builder - DRY RUN")
    print(f"input: {INPUT_PATH}")
    print(f"input exists: {str(INPUT_PATH.is_file()).lower()}")
    print(f"output: {OUTPUT_PATH}")
    print(f"expected candidate count: {EXPECTED_COUNT}")
    print(f"segment duration: {SEGMENT_DURATION_S} s")
    print(f"terminal evaluation window: {TERMINAL_EVALUATION_WINDOW_S} s")
    print("MATLAB/Simulink execution performed: false")
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
        source_rows, frozen_hash = load_frozen_rows()
        rows = build_rows(source_rows)
        atomic_write_csv(OUTPUT_PATH, OUTPUT_FIELDS, rows)
        metadata = {
            "status": "RESOLVED_EXECUTION_SPEC_READY",
            "candidate_count": len(rows),
            "segment_duration_s": SEGMENT_DURATION_S,
            "terminal_evaluation_window_s": TERMINAL_EVALUATION_WINDOW_S,
            "sample_time_s": SAMPLE_TIME_S,
            "frozen_pool_sha256": frozen_hash,
            "input_file": str(INPUT_PATH.relative_to(ROOT)),
            "input_file_sha256": sha256_file(INPUT_PATH),
            "output_file": str(OUTPUT_PATH.relative_to(ROOT)),
            "output_file_sha256": sha256_file(OUTPUT_PATH),
        }
        atomic_write_json(METADATA_PATH, metadata)
        print(f"resolved candidate count: {len(rows)}")
        print(f"frozen pool hash: {frozen_hash}")
        print(f"resolved execution spec: {OUTPUT_PATH}")
        print("MATLAB/Simulink execution performed: false")
        return 0
    except Exception as error:
        print(f"ERROR: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
