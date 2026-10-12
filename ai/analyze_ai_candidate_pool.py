"""Analyze the distribution of the validated AI test-candidate pool.

This script is intentionally limited to the AI candidate artifacts.  It does
not select a final suite, change validator results, or use Manual, mutation,
coverage, characterization, anti-windup, solver-history, or test assets.
"""

from __future__ import annotations

import csv
import json
import math
import re
from collections import Counter
from difflib import SequenceMatcher
from itertools import combinations
from pathlib import Path
from typing import Any

from tc_schema import (
    ALLOWED_REQUIREMENT_IDS,
    ALLOWED_TEST_DESIGN_TECHNIQUES,
    ALLOWED_TEST_SCOPES,
)


AI_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = AI_DIR / "output"
VALIDATED_CSV = OUTPUT_DIR / "ai_validated_candidates.csv"
CANDIDATES_JSON = OUTPUT_DIR / "ai_candidates.json"

SUMMARY_CSV = OUTPUT_DIR / "ai_candidate_pool_summary.csv"
REQUIREMENT_DISTRIBUTION_CSV = (
    OUTPUT_DIR / "ai_candidate_requirement_distribution.csv"
)
TECHNIQUE_DISTRIBUTION_CSV = (
    OUTPUT_DIR / "ai_candidate_technique_distribution.csv"
)

REQUIREMENT_ORDER = (
    "REQ-VOLT-001",
    "REQ-TRK-001",
    "REQ-DIR-001",
    "REQ-REV-001",
)
TECHNIQUE_ORDER = (
    "Equivalence Partitioning",
    "Boundary Value Analysis",
    "State Transition",
    "Scenario-Based",
)
SCOPE_ORDER = ("nominal", "stress")

# These are analysis-only similarity cutoffs.  They are not product
# requirements, acceptance thresholds, or Validator rejection criteria.
NEAR_DUPLICATE_OBJECTIVE_SIMILARITY = 0.85
NEAR_DUPLICATE_INPUT_SIMILARITY = 0.90


def load_validated_candidates() -> list[dict[str, Any]]:
    """Load the existing VALID candidate CSV without re-validating it."""

    with VALIDATED_CSV.open("r", encoding="utf-8-sig", newline="") as handle:
        candidates = list(csv.DictReader(handle))

    for candidate in candidates:
        values = json.loads(candidate["input_values"])
        if not isinstance(values, list):
            raise ValueError(
                f"{candidate['candidate_id']}: input_values must be a JSON array"
            )
        candidate["input_values"] = [float(value) for value in values]

    return candidates


def check_json_csv_consistency(candidates: list[dict[str, Any]]) -> None:
    """Confirm the two allowed candidate artifacts identify the same pool."""

    with CANDIDATES_JSON.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    json_candidates = payload.get("candidates", [])
    csv_ids = [candidate["candidate_id"] for candidate in candidates]
    json_ids = [str(candidate.get("candidate_id", "")) for candidate in json_candidates]

    if csv_ids != json_ids:
        raise ValueError(
            "ai_validated_candidates.csv and ai_candidates.json do not contain "
            "the same ordered candidate IDs"
        )


def sign_pattern(values: list[float]) -> tuple[int, ...]:
    """Return the ordered -1/0/+1 sign pattern for SpeedRef values."""

    return tuple(1 if value > 0 else -1 if value < 0 else 0 for value in values)


def is_reversal(values: list[float]) -> bool:
    """Detect a sign transition, ignoring any intervening exact zero values."""

    nonzero_signs = [sign for sign in sign_pattern(values) if sign != 0]
    return any(left != right for left, right in zip(nonzero_signs, nonzero_signs[1:]))


def format_number(value: float) -> str:
    if value == 0:
        return "0"
    return f"{value:+g}"


def speedref_summary(values: list[float]) -> str:
    return " -> ".join(f"{format_number(value)} rps" for value in values)


def input_form(values: list[float]) -> str:
    if len(values) == 1:
        return "constant"
    if is_reversal(values):
        transitions = sum(
            left != right
            for left, right in zip(
                [sign for sign in sign_pattern(values) if sign != 0],
                [sign for sign in sign_pattern(values) if sign != 0][1:],
            )
        )
        return "repeated_reversal" if transitions > 1 else "single_reversal"
    return "multi_segment_no_reversal"


def normalize_text(text: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", " ", text.lower())
    return " ".join(normalized.split())


def objective_similarity(left: str, right: str) -> float:
    return SequenceMatcher(
        None, normalize_text(left), normalize_text(right)
    ).ratio()


def input_similarity(left: dict[str, Any], right: dict[str, Any]) -> float:
    """Compare ordered input type, sign pattern, and numeric SpeedRef values."""

    if normalize_text(left["input_type"]) != normalize_text(right["input_type"]):
        return 0.0

    left_values = left["input_values"]
    right_values = right["input_values"]
    if len(left_values) != len(right_values):
        return 0.0
    if sign_pattern(left_values) != sign_pattern(right_values):
        return 0.0

    similarities: list[float] = []
    for left_value, right_value in zip(left_values, right_values):
        scale = max(abs(left_value), abs(right_value), 1.0)
        similarities.append(max(0.0, 1.0 - abs(left_value - right_value) / scale))
    return sum(similarities) / len(similarities) if similarities else 0.0


def find_near_duplicates(
    candidates: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Flag, but never remove or reject, highly similar same-requirement pairs."""

    pairs: list[dict[str, Any]] = []
    for left, right in combinations(candidates, 2):
        if left["requirement_id"] != right["requirement_id"]:
            continue

        objective_score = objective_similarity(
            left["test_objective"], right["test_objective"]
        )
        input_score = input_similarity(left, right)
        if (
            objective_score >= NEAR_DUPLICATE_OBJECTIVE_SIMILARITY
            and input_score >= NEAR_DUPLICATE_INPUT_SIMILARITY
        ):
            pairs.append(
                {
                    "left_candidate_id": left["candidate_id"],
                    "right_candidate_id": right["candidate_id"],
                    "requirement_id": left["requirement_id"],
                    "objective_similarity": objective_score,
                    "input_similarity": input_score,
                    "combined_similarity": math.sqrt(objective_score * input_score),
                }
            )
    return pairs


def write_distribution(
    path: Path,
    header_name: str,
    order: tuple[str, ...],
    counts: Counter[str],
    total: int,
) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=[header_name, "Count", "Percentage"]
        )
        writer.writeheader()
        for name in order:
            count = counts.get(name, 0)
            writer.writerow(
                {
                    header_name: name,
                    "Count": count,
                    "Percentage": round(100.0 * count / total, 2) if total else 0.0,
                }
            )


def summary_row(**updates: Any) -> dict[str, Any]:
    row = {
        "RecordType": "",
        "Metric": "",
        "Category": "",
        "Count": "",
        "CandidateID": "",
        "RequirementID": "",
        "TestDesignTechnique": "",
        "TestScope": "",
        "InputType": "",
        "InputForm": "",
        "InputValuesRps": "",
        "SpeedRefSummary": "",
        "HasPositive": "",
        "HasNegative": "",
        "HasZero": "",
        "IsReversal": "",
        "IsMultiSegment": "",
        "PairedCandidateID": "",
        "ObjectiveSimilarity": "",
        "InputSimilarity": "",
        "CombinedSimilarity": "",
        "Notes": "",
    }
    row.update(updates)
    return row


def write_summary(
    candidates: list[dict[str, Any]],
    scope_counts: Counter[str],
    near_duplicates: list[dict[str, Any]],
) -> None:
    rows: list[dict[str, Any]] = []
    rows.append(
        summary_row(
            RecordType="OVERALL",
            Metric="total_candidates",
            Count=len(candidates),
            Notes="Existing Validator results are unchanged.",
        )
    )
    rows.append(
        summary_row(
            RecordType="OVERALL",
            Metric="near_duplicate_pair_count",
            Count=len(near_duplicates),
            Notes=(
                "Analysis-only pairs; candidates are not removed or rejected. "
                f"Objective similarity >= {NEAR_DUPLICATE_OBJECTIVE_SIMILARITY:.2f} "
                f"and input similarity >= {NEAR_DUPLICATE_INPUT_SIMILARITY:.2f}."
            ),
        )
    )

    for scope in SCOPE_ORDER:
        rows.append(
            summary_row(
                RecordType="SCOPE_DISTRIBUTION",
                Metric="test_scope",
                Category=scope,
                Count=scope_counts.get(scope, 0),
            )
        )

    characteristic_counts = {
        "has_positive": sum(any(value > 0 for value in c["input_values"]) for c in candidates),
        "has_negative": sum(any(value < 0 for value in c["input_values"]) for c in candidates),
        "has_zero": sum(any(value == 0 for value in c["input_values"]) for c in candidates),
        "reversal": sum(is_reversal(c["input_values"]) for c in candidates),
        "multi_segment": sum(len(c["input_values"]) > 1 for c in candidates),
    }
    for characteristic, count in characteristic_counts.items():
        rows.append(
            summary_row(
                RecordType="INPUT_CHARACTERISTIC",
                Metric="candidate_count",
                Category=characteristic,
                Count=count,
            )
        )

    duplicate_map: dict[str, list[str]] = {}
    for pair in near_duplicates:
        duplicate_map.setdefault(pair["left_candidate_id"], []).append(
            pair["right_candidate_id"]
        )
        duplicate_map.setdefault(pair["right_candidate_id"], []).append(
            pair["left_candidate_id"]
        )

    for candidate in candidates:
        values = candidate["input_values"]
        rows.append(
            summary_row(
                RecordType="CANDIDATE_DETAIL",
                CandidateID=candidate["candidate_id"],
                RequirementID=candidate["requirement_id"],
                TestDesignTechnique=candidate["test_design_technique"],
                TestScope=candidate["test_scope"],
                InputType=candidate["input_type"],
                InputForm=input_form(values),
                InputValuesRps=json.dumps(values, separators=(",", ":")),
                SpeedRefSummary=speedref_summary(values),
                HasPositive=any(value > 0 for value in values),
                HasNegative=any(value < 0 for value in values),
                HasZero=any(value == 0 for value in values),
                IsReversal=is_reversal(values),
                IsMultiSegment=len(values) > 1,
                PairedCandidateID=";".join(duplicate_map.get(candidate["candidate_id"], [])),
            )
        )

    for pair in near_duplicates:
        rows.append(
            summary_row(
                RecordType="NEAR_DUPLICATE_PAIR",
                CandidateID=pair["left_candidate_id"],
                RequirementID=pair["requirement_id"],
                PairedCandidateID=pair["right_candidate_id"],
                ObjectiveSimilarity=round(pair["objective_similarity"], 4),
                InputSimilarity=round(pair["input_similarity"], 4),
                CombinedSimilarity=round(pair["combined_similarity"], 4),
                Notes="Analysis flag only; VALID status is unchanged.",
            )
        )

    with SUMMARY_CSV.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def ordered_counts(
    counts: Counter[str], preferred_order: tuple[str, ...]
) -> dict[str, int]:
    result = {name: counts.get(name, 0) for name in preferred_order}
    for name in sorted(set(counts) - set(preferred_order)):
        result[name] = counts[name]
    return result


def main() -> int:
    candidates = load_validated_candidates()
    check_json_csv_consistency(candidates)
    total = len(candidates)

    requirement_counts = Counter(c["requirement_id"] for c in candidates)
    technique_counts = Counter(c["test_design_technique"] for c in candidates)
    scope_counts = Counter(c["test_scope"] for c in candidates)
    near_duplicates = find_near_duplicates(candidates)

    # Keep schema-defined categories visible even when their count is zero.
    requirement_order = tuple(
        name for name in REQUIREMENT_ORDER if name in ALLOWED_REQUIREMENT_IDS
    )
    technique_order = tuple(
        name for name in TECHNIQUE_ORDER if name in ALLOWED_TEST_DESIGN_TECHNIQUES
    )
    scope_order = tuple(name for name in SCOPE_ORDER if name in ALLOWED_TEST_SCOPES)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    write_distribution(
        REQUIREMENT_DISTRIBUTION_CSV,
        "RequirementID",
        requirement_order,
        requirement_counts,
        total,
    )
    write_distribution(
        TECHNIQUE_DISTRIBUTION_CSV,
        "TestDesignTechnique",
        technique_order,
        technique_counts,
        total,
    )
    write_summary(candidates, scope_counts, near_duplicates)

    print(f"total candidates: {total}")
    print(
        "requirement distribution: "
        + json.dumps(
            ordered_counts(requirement_counts, requirement_order),
            ensure_ascii=False,
        )
    )
    print(
        "technique distribution: "
        + json.dumps(
            ordered_counts(technique_counts, technique_order),
            ensure_ascii=False,
        )
    )
    print(
        "scope distribution: "
        + json.dumps(ordered_counts(scope_counts, scope_order), ensure_ascii=False)
    )
    print(f"near-duplicate pair count: {len(near_duplicates)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
