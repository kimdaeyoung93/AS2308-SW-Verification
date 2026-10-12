"""Build the resolved execution specification for Official AI Suite V1.

The script reads only ``ai/output/ai_suite_v1_execution_spec.csv`` and writes
``ai/output/ai_suite_v1_resolved_execution_spec.csv``.  It does not run
Simulink or evaluate an Oracle.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Any


AI_DIR = Path(__file__).resolve().parent
INPUT_PATH = AI_DIR / "output" / "ai_suite_v1_execution_spec.csv"
OUTPUT_PATH = AI_DIR / "output" / "ai_suite_v1_resolved_execution_spec.csv"

EXPECTED_CANDIDATE_COUNT = 9
SEGMENT_DURATION_S = 2.0
SAMPLE_TIME_S = 0.0004
TERMINAL_EVALUATION_WINDOW_S = 0.05

ORACLE_MAPPING = {
    "REQ-VOLT-001": "Voltage Oracle",
    "REQ-DIR-001": "Direction Oracle",
    "REQ-TRK-001": "Tracking Oracle",
    "REQ-REV-001": "Direction + Tracking",
}

OUTPUT_FIELDS = [
    "selection_order",
    "candidate_id",
    "requirement_id",
    "original_input_values",
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
]


def parse_values(raw: str, candidate_id: str) -> list[float]:
    try:
        values = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{candidate_id}: invalid input_values JSON") from exc
    if not isinstance(values, list) or not values:
        raise ValueError(f"{candidate_id}: input_values must be a non-empty array")
    parsed = [float(value) for value in values]
    if not all(math.isfinite(value) for value in parsed):
        raise ValueError(f"{candidate_id}: input_values contain NaN or Inf")
    return parsed


def load_source_rows() -> list[dict[str, str]]:
    with INPUT_PATH.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))

    if len(rows) != EXPECTED_CANDIDATE_COUNT:
        raise ValueError(
            f"Expected {EXPECTED_CANDIDATE_COUNT} frozen candidates, found {len(rows)}"
        )

    ids = [row["candidate_id"].strip() for row in rows]
    if len(set(ids)) != len(ids):
        raise ValueError("candidate_id values are not unique")

    orders = [int(row["selection_order"]) for row in rows]
    if orders != list(range(1, EXPECTED_CANDIDATE_COUNT + 1)):
        raise ValueError("selection_order must be the ordered integers 1 through 9")

    return rows


def sign(value: float) -> int:
    return 1 if value > 0 else -1 if value < 0 else 0


def resolved_waveform(values: list[float]) -> list[dict[str, Any]]:
    waveform = []
    for index, value in enumerate(values, start=1):
        waveform.append(
            {
                "segment_index": index,
                "start_s": (index - 1) * SEGMENT_DURATION_S,
                "end_s": index * SEGMENT_DURATION_S,
                "speed_ref_rps": value,
            }
        )
    return waveform


def terminal_interval(segment_index: int) -> dict[str, Any]:
    end_s = segment_index * SEGMENT_DURATION_S
    return {
        "segment_index": segment_index,
        "start_s": end_s - TERMINAL_EVALUATION_WINDOW_S,
        "end_s": end_s,
    }


def reversal_target_segments(values: list[float]) -> list[int]:
    targets = []
    previous_nonzero_sign: int | None = None
    for segment_index, value in enumerate(values, start=1):
        current_sign = sign(value)
        if current_sign == 0:
            continue
        if previous_nonzero_sign is not None and current_sign != previous_nonzero_sign:
            targets.append(segment_index)
        previous_nonzero_sign = current_sign
    return targets


def evaluation_resolution(
    requirement_id: str, values: list[float]
) -> tuple[str, float, list[dict[str, Any]], bool]:
    total_duration_s = len(values) * SEGMENT_DURATION_S

    if requirement_id == "REQ-VOLT-001":
        return (
            "complete_simulation_interval",
            total_duration_s,
            [{"start_s": 0.0, "end_s": total_duration_s}],
            False,
        )
    if requirement_id == "REQ-DIR-001":
        return (
            "final_plateau_terminal_window",
            TERMINAL_EVALUATION_WINDOW_S,
            [terminal_interval(len(values))],
            False,
        )
    if requirement_id == "REQ-TRK-001":
        return (
            "each_plateau_terminal_window",
            TERMINAL_EVALUATION_WINDOW_S,
            [terminal_interval(index) for index in range(1, len(values) + 1)],
            True,
        )
    if requirement_id == "REQ-REV-001":
        target_segments = reversal_target_segments(values)
        if not target_segments:
            raise ValueError("REQ-REV-001 candidate contains no sign reversal")
        return (
            "each_post_reversal_plateau_terminal_window",
            TERMINAL_EVALUATION_WINDOW_S,
            [terminal_interval(index) for index in target_segments],
            False,
        )
    raise ValueError(f"Unsupported requirement_id: {requirement_id}")


def resolve_row(row: dict[str, str]) -> dict[str, Any]:
    candidate_id = row["candidate_id"].strip()
    requirement_id = row["requirement_id"].strip()
    values = parse_values(row["input_values"], candidate_id)

    declared_segment_count = int(row["segment_count"])
    if declared_segment_count != len(values):
        raise ValueError(
            f"{candidate_id}: declared segment_count does not match input_values"
        )
    if row["explicit_duration_present"].strip().lower() != "false":
        raise ValueError(
            f"{candidate_id}: explicit duration conflicts with the frozen adapter protocol"
        )
    if requirement_id not in ORACLE_MAPPING:
        raise ValueError(f"{candidate_id}: unsupported requirement_id {requirement_id}")

    scope, window_s, intervals, gate_required = evaluation_resolution(
        requirement_id, values
    )
    waveform = resolved_waveform(values)

    return {
        "selection_order": int(row["selection_order"]),
        "candidate_id": candidate_id,
        "requirement_id": requirement_id,
        "original_input_values": row["input_values"],
        "segment_count": len(values),
        "segment_duration_s": SEGMENT_DURATION_S,
        "total_duration_s": len(values) * SEGMENT_DURATION_S,
        "sample_time_s": SAMPLE_TIME_S,
        "resolved_waveform": json.dumps(waveform, separators=(",", ":")),
        "oracle_mapping": ORACLE_MAPPING[requirement_id],
        "applicability_check_required": str(gate_required).lower(),
        "evaluation_scope": scope,
        "evaluation_window_s": window_s,
        "evaluation_intervals_s": json.dumps(intervals, separators=(",", ":")),
        "ambiguity_status": "NO_UNRESOLVED_AMBIGUITY",
        "execution_status": "NOT_EXECUTED",
    }


def build_resolved_rows() -> list[dict[str, Any]]:
    rows = [resolve_row(row) for row in load_source_rows()]
    if any(row["execution_status"] != "NOT_EXECUTED" for row in rows):
        raise AssertionError("Adapter build must not assign execution results")
    return rows


def write_output(rows: list[dict[str, Any]]) -> None:
    with OUTPUT_PATH.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def print_summary(rows: list[dict[str, Any]], wrote_output: bool) -> None:
    for row in rows:
        print(
            f"{row['selection_order']}: {row['candidate_id']} | "
            f"duration={row['total_duration_s']:.1f}s | "
            f"oracle={row['oracle_mapping']} | "
            f"tracking_gate={row['applicability_check_required']}"
        )
    print(f"resolved candidate count: {len(rows)}")
    print(
        "applicability gate candidate count: "
        f"{sum(row['applicability_check_required'] == 'true' for row in rows)}"
    )
    print(
        "unresolved ambiguity count: "
        f"{sum(row['ambiguity_status'] != 'NO_UNRESOLVED_AMBIGUITY' for row in rows)}"
    )
    print("Simulink execution performed: false")
    print(f"resolved CSV written: {str(wrote_output).lower()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Resolve and validate in memory without writing the output CSV.",
    )
    args = parser.parse_args()

    rows = build_resolved_rows()
    if not args.check_only:
        write_output(rows)
    print_summary(rows, wrote_output=not args.check_only)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
