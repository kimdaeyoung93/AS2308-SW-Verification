"""Standalone self-check for the AI test case validator."""

from __future__ import annotations

import csv
import json
import tempfile
from copy import deepcopy
from pathlib import Path

from validate_test_cases import load_candidates, validate_candidates, write_results


def _valid_candidate() -> dict[str, object]:
    return {
        "candidate_id": "SYN-VALID-001",
        "requirement_id": "REQ-TRK-001",
        "test_objective": "Check stable convergence for a constant reference",
        "precondition": "Controller and reduced-order plant are initialized",
        "input_type": "constant",
        "input_values": [7.5],
        "expected_behavior": "MotorSpeed converges stably to SpeedRef",
        "test_design_technique": "Equivalence Partitioning",
        "rationale": "Exercises valid constant-reference tracking",
        "test_scope": "nominal",
    }


def main() -> int:
    valid = _valid_candidate()

    bad_requirement = deepcopy(valid)
    bad_requirement["candidate_id"] = "SYN-BAD-REQ"
    bad_requirement["requirement_id"] = "REQ-NOT-DEFINED"

    out_of_range = deepcopy(valid)
    out_of_range["candidate_id"] = "SYN-BAD-RANGE"
    out_of_range["input_values"] = [500]

    missing_field = deepcopy(valid)
    missing_field["candidate_id"] = "SYN-MISSING-FIELD"
    del missing_field["expected_behavior"]

    duplicate = deepcopy(valid)
    duplicate["candidate_id"] = "SYN-DUPLICATE"

    candidates = [
        valid,
        bad_requirement,
        out_of_range,
        missing_field,
        duplicate,
    ]
    expected_statuses = ["VALID", "REJECTED", "REJECTED", "REJECTED", "REJECTED"]

    self_check_parent = Path(__file__).resolve().parent / "output"
    self_check_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="as2308_ai_validator_", dir=self_check_parent
    ) as directory:
        temporary_directory = Path(directory)
        candidate_path = temporary_directory / "ai_candidates.json"
        validation_path = temporary_directory / "ai_validation_results.csv"
        validated_path = temporary_directory / "ai_validated_candidates.csv"
        candidate_path.write_text(
            json.dumps(candidates, indent=2), encoding="utf-8"
        )

        loaded = load_candidates(candidate_path)
        records = validate_candidates(loaded)
        write_results(records, validation_path, validated_path)

        actual_statuses = [record.status for record in records]
        assert actual_statuses == expected_statuses, (
            f"Unexpected statuses: {actual_statuses}"
        )
        assert "Unsupported Requirement ID" in records[1].rejection_reason
        assert "|SpeedRef| < 20 rps" in records[2].rejection_reason
        assert "Missing required field" in records[3].rejection_reason
        assert "Exact duplicate candidate" in records[4].rejection_reason

        with validation_path.open("r", encoding="utf-8-sig", newline="") as file:
            validation_rows = list(csv.DictReader(file))
        with validated_path.open("r", encoding="utf-8-sig", newline="") as file:
            validated_rows = list(csv.DictReader(file))
        assert len(validation_rows) == 5
        assert len(validated_rows) == 1

    labels = (
        "normal candidate",
        "unknown Requirement ID",
        "nominal SpeedRef = 500 rps",
        "missing required field",
        "duplicate candidate",
    )
    for label, record in zip(labels, records):
        reason = f" - {record.rejection_reason}" if record.rejection_reason else ""
        print(f"{label}: {record.status}{reason}")
    print("SELF-CHECK PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
