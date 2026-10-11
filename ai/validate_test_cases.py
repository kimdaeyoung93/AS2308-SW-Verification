"""Validate AI-assisted MIL test case candidates.

Default usage from the repository root:

    python ai/validate_test_cases.py

The default input and outputs are:
    ai/output/ai_candidates.json
    ai/output/ai_validation_results.csv
    ai/output/ai_validated_candidates.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from tc_schema import (
    ALLOWED_REQUIREMENT_IDS,
    ALLOWED_TEST_DESIGN_TECHNIQUES,
    ALLOWED_TEST_SCOPES,
    TestCaseCandidate,
)


NOMINAL_SPEEDREF_LIMIT_RPS = 20.0
TEXT_FIELDS = (
    "candidate_id",
    "requirement_id",
    "test_objective",
    "precondition",
    "input_type",
    "expected_behavior",
    "test_design_technique",
    "rationale",
)
OUTPUT_FIELDS = (*TestCaseCandidate.REQUIRED_FIELDS, "test_scope")

# The basis defines no numerical performance limits for these measures.
# The detector is intentionally conservative and searches candidate prose,
# not numeric SpeedRef stimulus values. REQ-VOLT-001's +/-12 V bound is an
# explicit requirement and is therefore not treated as unsupported.
UNSUPPORTED_THRESHOLD_PATTERNS = (
    re.compile(
        r"(?:overshoot|settling(?:\s+time)?|reversal(?:\s+time)?|"
        r"recovery(?:\s+time)?|steady[-\s]*state\s+error|"
        r"tracking\s+error|tolerance)"
        r".{0,40}?\d+(?:\.\d+)?\s*(?:%|ms|s|sec(?:ond)?s?|rps)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:within|under|below|less\s+than|no\s+more\s+than|"
        r"<=|>=|<|>)\s*\d+(?:\.\d+)?\s*(?:%|ms|s|sec(?:ond)?s?|rps)\b",
        re.IGNORECASE,
    ),
)


@dataclass(slots=True)
class ValidationRecord:
    raw_candidate: dict[str, Any]
    status: str
    rejection_reason: str
    candidate: TestCaseCandidate | None = None


def _normalize_text(value: Any) -> str:
    return " ".join(str(value).strip().lower().split())


def _canonical_input_values(values: Iterable[float]) -> tuple[float, ...]:
    return tuple(float(value) for value in values)


def _unsupported_threshold(candidate: dict[str, Any]) -> bool:
    prose = " ".join(
        str(candidate.get(field_name, ""))
        for field_name in (
            "test_objective",
            "precondition",
            "expected_behavior",
            "rationale",
        )
    )
    return any(pattern.search(prose) for pattern in UNSUPPORTED_THRESHOLD_PATTERNS)


def _validate_one(candidate: Any) -> tuple[list[str], TestCaseCandidate | None]:
    reasons: list[str] = []
    if not isinstance(candidate, dict):
        return ["Candidate must be a JSON object"], None

    missing = [
        field_name
        for field_name in TestCaseCandidate.REQUIRED_FIELDS
        if field_name not in candidate
        or candidate[field_name] is None
        or (
            isinstance(candidate[field_name], str)
            and not candidate[field_name].strip()
        )
    ]
    if missing:
        reasons.append("Missing required field(s): " + ", ".join(missing))

    requirement_id = str(candidate.get("requirement_id", "")).strip()
    if requirement_id and requirement_id not in ALLOWED_REQUIREMENT_IDS:
        reasons.append(f"Unsupported Requirement ID: {requirement_id}")

    technique = str(candidate.get("test_design_technique", "")).strip()
    if technique and technique not in ALLOWED_TEST_DESIGN_TECHNIQUES:
        reasons.append(f"Unsupported test design technique: {technique}")

    test_scope = str(candidate.get("test_scope", "nominal")).strip().lower()
    if test_scope not in ALLOWED_TEST_SCOPES:
        reasons.append(f"Unsupported test scope: {test_scope}")

    numeric_values: list[float] = []
    input_values = candidate.get("input_values")
    if input_values is not None:
        if not isinstance(input_values, list) or not input_values:
            reasons.append("input_values must be a nonempty list of numbers")
        else:
            for index, value in enumerate(input_values):
                if isinstance(value, bool) or not isinstance(value, (int, float)):
                    reasons.append(
                        f"SpeedRef value at index {index} is not numeric"
                    )
                    continue
                numeric_value = float(value)
                if not math.isfinite(numeric_value):
                    reasons.append(
                        f"SpeedRef value at index {index} must be finite"
                    )
                    continue
                numeric_values.append(numeric_value)

    if (
        test_scope == "nominal"
        and numeric_values
        and any(abs(value) >= NOMINAL_SPEEDREF_LIMIT_RPS for value in numeric_values)
    ):
        reasons.append(
            "Nominal SpeedRef must satisfy |SpeedRef| < 20 rps"
        )

    if _unsupported_threshold(candidate):
        reasons.append("Possible unsupported product performance threshold")

    if reasons:
        return reasons, None

    try:
        parsed = TestCaseCandidate.from_mapping(candidate)
    except (KeyError, TypeError, ValueError) as error:
        return [str(error)], None
    return [], parsed


def validate_candidates(candidates: list[Any]) -> list[ValidationRecord]:
    """Classify candidates as VALID or REJECTED without external test data."""

    records: list[ValidationRecord] = []
    seen_ids: set[str] = set()
    seen_exact_payloads: set[str] = set()
    seen_obvious_keys: set[tuple[str, tuple[float, ...], str]] = set()

    for raw_candidate in candidates:
        display_candidate = raw_candidate if isinstance(raw_candidate, dict) else {}
        reasons, parsed = _validate_one(raw_candidate)

        if parsed is not None:
            candidate_id_key = _normalize_text(parsed.candidate_id)
            payload = parsed.to_dict()
            payload.pop("candidate_id")
            exact_key = json.dumps(
                payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            )
            obvious_key = (
                parsed.requirement_id,
                _canonical_input_values(parsed.input_values),
                _normalize_text(parsed.test_objective),
            )

            if candidate_id_key in seen_ids:
                reasons.append("Duplicate candidate_id")
            if exact_key in seen_exact_payloads:
                reasons.append("Exact duplicate candidate")
            if obvious_key in seen_obvious_keys:
                reasons.append(
                    "Duplicate Requirement/input/objective combination"
                )

            if not reasons:
                seen_ids.add(candidate_id_key)
                seen_exact_payloads.add(exact_key)
                seen_obvious_keys.add(obvious_key)

        if reasons:
            records.append(
                ValidationRecord(
                    raw_candidate=display_candidate,
                    status="REJECTED",
                    rejection_reason="; ".join(dict.fromkeys(reasons)),
                )
            )
        else:
            records.append(
                ValidationRecord(
                    raw_candidate=display_candidate,
                    status="VALID",
                    rejection_reason="",
                    candidate=parsed,
                )
            )

    return records


def _csv_row(candidate: dict[str, Any]) -> dict[str, str]:
    row: dict[str, str] = {}
    for field_name in OUTPUT_FIELDS:
        value = candidate.get(field_name, "nominal" if field_name == "test_scope" else "")
        if field_name == "input_values" and isinstance(value, list):
            row[field_name] = json.dumps(value, separators=(",", ":"))
        else:
            row[field_name] = str(value)
    return row


def write_results(
    records: list[ValidationRecord],
    validation_results_path: Path,
    validated_candidates_path: Path,
) -> None:
    """Write full validation results and the accepted-candidate subset."""

    validation_results_path.parent.mkdir(parents=True, exist_ok=True)
    validated_candidates_path.parent.mkdir(parents=True, exist_ok=True)

    with validation_results_path.open("w", newline="", encoding="utf-8-sig") as file:
        writer = csv.DictWriter(
            file,
            fieldnames=[*OUTPUT_FIELDS, "validation_status", "rejection_reason"],
        )
        writer.writeheader()
        for record in records:
            row = _csv_row(record.raw_candidate)
            row["validation_status"] = record.status
            row["rejection_reason"] = record.rejection_reason
            writer.writerow(row)

    with validated_candidates_path.open(
        "w", newline="", encoding="utf-8-sig"
    ) as file:
        writer = csv.DictWriter(file, fieldnames=list(OUTPUT_FIELDS))
        writer.writeheader()
        for record in records:
            if record.status == "VALID" and record.candidate is not None:
                writer.writerow(_csv_row(record.candidate.to_dict()))


def load_candidates(path: Path) -> list[Any]:
    """Load either a JSON list or an object containing a candidates list."""

    with path.open("r", encoding="utf-8") as file:
        payload = json.load(file)
    if isinstance(payload, dict) and "candidates" in payload:
        payload = payload["candidates"]
    if not isinstance(payload, list):
        raise ValueError("Candidate JSON must be a list or contain a candidates list")
    return payload


def main() -> int:
    ai_directory = Path(__file__).resolve().parent
    output_directory = ai_directory / "output"
    parser = argparse.ArgumentParser(
        description="Validate AI-assisted MIL test case candidates."
    )
    parser.add_argument(
        "candidate_json",
        nargs="?",
        type=Path,
        default=output_directory / "ai_candidates.json",
    )
    parser.add_argument(
        "--validation-results",
        type=Path,
        default=output_directory / "ai_validation_results.csv",
    )
    parser.add_argument(
        "--validated-candidates",
        type=Path,
        default=output_directory / "ai_validated_candidates.csv",
    )
    arguments = parser.parse_args()

    candidates = load_candidates(arguments.candidate_json)
    records = validate_candidates(candidates)
    write_results(
        records,
        arguments.validation_results,
        arguments.validated_candidates,
    )
    valid_count = sum(record.status == "VALID" for record in records)
    rejected_count = len(records) - valid_count
    print(f"Validated {len(records)} candidates: {valid_count} VALID, "
          f"{rejected_count} REJECTED")
    print(f"Validation results: {arguments.validation_results}")
    print(f"Validated candidates: {arguments.validated_candidates}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
