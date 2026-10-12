"""Deterministic selector for Official AI Test Suite V1.

Official selection is performed only with ``--select``.  ``--check-input``
and ``--self-check`` do not evaluate the official 9-candidate selection and
do not create selection output files.

The selector reads only:
  - ai/output/ai_validated_candidates.csv
  - ai/output/ai_candidates.json

It does not discover or read Manual, mutation, or coverage artifacts.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
from collections import Counter
from dataclasses import dataclass, replace
from itertools import combinations, product
from pathlib import Path
from typing import Iterable, Iterator, Sequence


AI_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = AI_DIR / "output"
VALIDATED_CSV = OUTPUT_DIR / "ai_validated_candidates.csv"
CANDIDATES_JSON = OUTPUT_DIR / "ai_candidates.json"
SELECTED_CSV = OUTPUT_DIR / "ai_suite_v1_selected.csv"
SELECTION_SUMMARY_CSV = OUTPUT_DIR / "ai_suite_v1_selection_summary.csv"

TOTAL_CANDIDATES = 25
TOTAL_SELECTED = 9

REQUIREMENT_ORDER = (
    "REQ-VOLT-001",
    "REQ-TRK-001",
    "REQ-DIR-001",
    "REQ-REV-001",
)
REQUIREMENT_POOL_COUNTS = {
    "REQ-VOLT-001": 6,
    "REQ-TRK-001": 7,
    "REQ-DIR-001": 6,
    "REQ-REV-001": 6,
}
REQUIREMENT_QUOTAS = {
    "REQ-VOLT-001": 2,
    "REQ-TRK-001": 3,
    "REQ-DIR-001": 2,
    "REQ-REV-001": 2,
}

SCOPE_TARGETS = {"nominal": 5, "stress": 4}
TECHNIQUE_ORDER = (
    "Boundary Value Analysis",
    "Equivalence Partitioning",
    "State Transition",
    "Scenario-Based",
)
TECHNIQUE_TARGETS = {
    "Boundary Value Analysis": 4,
    "Equivalence Partitioning": 2,
    "State Transition": 1,
    "Scenario-Based": 2,
}


@dataclass(frozen=True, slots=True)
class Candidate:
    candidate_id: str
    requirement_id: str
    test_objective: str
    input_type: str
    input_values: tuple[float, ...]
    test_design_technique: str
    test_scope: str


@dataclass(frozen=True, slots=True)
class SelectionMetrics:
    scope_deviation: int
    technique_deviation: int
    polarity_coverage: int
    includes_reversal: bool
    includes_multi_segment: bool
    unique_input_signatures: int
    candidate_ids: tuple[str, ...]
    nominal_count: int
    stress_count: int
    technique_counts: tuple[tuple[str, int], ...]

    def objective_key(self) -> tuple[object, ...]:
        """Return the frozen lexicographic minimization key."""

        return (
            self.scope_deviation,
            self.technique_deviation,
            -self.polarity_coverage,
            -int(self.includes_reversal),
            -int(self.includes_multi_segment),
            -self.unique_input_signatures,
            self.candidate_ids,
        )


def parse_input_values(raw: str, candidate_id: str) -> tuple[float, ...]:
    values = json.loads(raw)
    if not isinstance(values, list) or not values:
        raise ValueError(f"{candidate_id}: input_values must be a non-empty array")
    parsed = tuple(float(value) for value in values)
    if not all(math.isfinite(value) for value in parsed):
        raise ValueError(f"{candidate_id}: input_values contain NaN or Inf")
    return parsed


def load_candidate_pool() -> list[Candidate]:
    """Load and cross-check the two explicitly allowed candidate files."""

    with VALIDATED_CSV.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))

    candidates = [
        Candidate(
            candidate_id=row["candidate_id"].strip(),
            requirement_id=row["requirement_id"].strip(),
            test_objective=row["test_objective"].strip(),
            input_type=row["input_type"].strip(),
            input_values=parse_input_values(
                row["input_values"], row["candidate_id"].strip()
            ),
            test_design_technique=row["test_design_technique"].strip(),
            test_scope=row["test_scope"].strip(),
        )
        for row in rows
    ]

    with CANDIDATES_JSON.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    json_candidates = payload.get("candidates", [])
    json_ids = [str(item.get("candidate_id", "")).strip() for item in json_candidates]
    csv_ids = [candidate.candidate_id for candidate in candidates]

    if csv_ids != json_ids:
        raise ValueError(
            "Validated CSV and candidate JSON do not contain the same ordered IDs"
        )
    if len(candidates) != TOTAL_CANDIDATES:
        raise ValueError(
            f"Expected {TOTAL_CANDIDATES} candidates, found {len(candidates)}"
        )
    if len(set(csv_ids)) != len(csv_ids):
        raise ValueError("Candidate IDs are not unique")

    requirement_counts = Counter(c.requirement_id for c in candidates)
    if dict(requirement_counts) != REQUIREMENT_POOL_COUNTS:
        raise ValueError(
            "Requirement distribution differs from the frozen Candidate Set V1: "
            f"{dict(requirement_counts)}"
        )

    return candidates


def sign_pattern(values: Sequence[float]) -> tuple[int, ...]:
    return tuple(1 if value > 0 else -1 if value < 0 else 0 for value in values)


def contains_reversal(candidate: Candidate) -> bool:
    nonzero_signs = [sign for sign in sign_pattern(candidate.input_values) if sign]
    return any(left != right for left, right in zip(nonzero_signs, nonzero_signs[1:]))


def is_multi_segment(candidate: Candidate) -> bool:
    return len(candidate.input_values) > 1


def normalize_input_type(value: str) -> str:
    return " ".join(re.sub(r"[^a-z0-9]+", " ", value.lower()).split())


def input_signature(candidate: Candidate) -> tuple[str, tuple[float, ...]]:
    return normalize_input_type(candidate.input_type), candidate.input_values


def polarity_label(candidate: Candidate) -> str:
    has_positive = any(value > 0 for value in candidate.input_values)
    has_negative = any(value < 0 for value in candidate.input_values)
    has_zero = any(value == 0 for value in candidate.input_values)
    labels = []
    if has_positive:
        labels.append("positive")
    if has_negative:
        labels.append("negative")
    if has_zero:
        labels.append("zero")
    return "+".join(labels) if labels else "none"


def format_value(value: float) -> str:
    if value == 0:
        return "0"
    return f"{value:+g}"


def input_summary(candidate: Candidate) -> str:
    return " -> ".join(f"{format_value(value)} rps" for value in candidate.input_values)


def requirement_counts(candidates: Iterable[Candidate]) -> Counter[str]:
    return Counter(candidate.requirement_id for candidate in candidates)


def meets_requirement_quota(candidates: Sequence[Candidate]) -> bool:
    return dict(requirement_counts(candidates)) == REQUIREMENT_QUOTAS


def calculate_combination_count(candidates: Sequence[Candidate]) -> int:
    counts = requirement_counts(candidates)
    total = 1
    for requirement_id in REQUIREMENT_ORDER:
        total *= math.comb(
            counts.get(requirement_id, 0), REQUIREMENT_QUOTAS[requirement_id]
        )
    return total


def iter_quota_combinations(
    candidates: Sequence[Candidate],
) -> Iterator[tuple[Candidate, ...]]:
    grouped = {
        requirement_id: sorted(
            (
                candidate
                for candidate in candidates
                if candidate.requirement_id == requirement_id
            ),
            key=lambda candidate: candidate.candidate_id,
        )
        for requirement_id in REQUIREMENT_ORDER
    }
    per_requirement = [
        combinations(grouped[requirement_id], REQUIREMENT_QUOTAS[requirement_id])
        for requirement_id in REQUIREMENT_ORDER
    ]
    for grouped_choice in product(*per_requirement):
        yield tuple(candidate for group in grouped_choice for candidate in group)


def evaluate_combination(candidates: Sequence[Candidate]) -> SelectionMetrics:
    if len(candidates) != TOTAL_SELECTED:
        raise ValueError(f"Expected {TOTAL_SELECTED} selected candidates")
    if not meets_requirement_quota(candidates):
        raise ValueError("Candidate combination does not satisfy the hard quota")

    scope_counts = Counter(candidate.test_scope for candidate in candidates)
    scope_deviation = sum(
        abs(scope_counts.get(scope, 0) - target)
        for scope, target in SCOPE_TARGETS.items()
    )

    technique_counts = Counter(
        candidate.test_design_technique for candidate in candidates
    )
    technique_deviation = sum(
        abs(technique_counts.get(technique, 0) - target)
        for technique, target in TECHNIQUE_TARGETS.items()
    )

    has_positive = any(
        value > 0 for candidate in candidates for value in candidate.input_values
    )
    has_negative = any(
        value < 0 for candidate in candidates for value in candidate.input_values
    )

    return SelectionMetrics(
        scope_deviation=scope_deviation,
        technique_deviation=technique_deviation,
        polarity_coverage=int(has_positive) + int(has_negative),
        includes_reversal=any(contains_reversal(c) for c in candidates),
        includes_multi_segment=any(is_multi_segment(c) for c in candidates),
        unique_input_signatures=len({input_signature(c) for c in candidates}),
        candidate_ids=tuple(sorted(c.candidate_id for c in candidates)),
        nominal_count=scope_counts.get("nominal", 0),
        stress_count=scope_counts.get("stress", 0),
        technique_counts=tuple(
            (technique, technique_counts.get(technique, 0))
            for technique in TECHNIQUE_ORDER
        ),
    )


def select_best_combination(
    candidates: Sequence[Candidate],
) -> tuple[tuple[Candidate, ...], SelectionMetrics, int]:
    best_candidates: tuple[Candidate, ...] | None = None
    best_metrics: SelectionMetrics | None = None
    evaluated = 0

    for choice in iter_quota_combinations(candidates):
        metrics = evaluate_combination(choice)
        evaluated += 1
        if best_metrics is None or metrics.objective_key() < best_metrics.objective_key():
            best_candidates = choice
            best_metrics = metrics

    if best_candidates is None or best_metrics is None:
        raise RuntimeError("No combination satisfies the frozen Requirement quota")

    return tuple(sorted(best_candidates, key=lambda c: c.candidate_id)), best_metrics, evaluated


def selection_reason(candidate: Candidate) -> str:
    characteristics = []
    if contains_reversal(candidate):
        characteristics.append("reversal")
    if is_multi_segment(candidate):
        characteristics.append("multi-segment")
    suffix = f"; input characteristics: {', '.join(characteristics)}" if characteristics else ""
    return (
        "Selected by the frozen deterministic lexicographic protocol within "
        f"the {candidate.requirement_id} quota{suffix}."
    )


def write_selection_outputs(
    selected: Sequence[Candidate], metrics: SelectionMetrics, evaluated: int
) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with SELECTED_CSV.open("w", encoding="utf-8-sig", newline="") as handle:
        fieldnames = [
            "selection_order",
            "candidate_id",
            "requirement_id",
            "test_scope",
            "test_design_technique",
            "input_summary",
            "polarity",
            "reversal",
            "multi_segment",
            "selection_reason",
        ]
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for index, candidate in enumerate(selected, start=1):
            writer.writerow(
                {
                    "selection_order": index,
                    "candidate_id": candidate.candidate_id,
                    "requirement_id": candidate.requirement_id,
                    "test_scope": candidate.test_scope,
                    "test_design_technique": candidate.test_design_technique,
                    "input_summary": input_summary(candidate),
                    "polarity": polarity_label(candidate),
                    "reversal": contains_reversal(candidate),
                    "multi_segment": is_multi_segment(candidate),
                    "selection_reason": selection_reason(candidate),
                }
            )

    technique_counts = dict(metrics.technique_counts)
    summary_rows = [
        ("selected_execution_count", len(selected), TOTAL_SELECTED, 0, ""),
        ("evaluated_combination_count", evaluated, "", "", ""),
        (
            "nominal_count",
            metrics.nominal_count,
            SCOPE_TARGETS["nominal"],
            abs(metrics.nominal_count - SCOPE_TARGETS["nominal"]),
            "",
        ),
        (
            "stress_count",
            metrics.stress_count,
            SCOPE_TARGETS["stress"],
            abs(metrics.stress_count - SCOPE_TARGETS["stress"]),
            "",
        ),
    ]
    summary_rows.extend(
        (
            f"technique_{technique}",
            technique_counts[technique],
            TECHNIQUE_TARGETS[technique],
            abs(technique_counts[technique] - TECHNIQUE_TARGETS[technique]),
            "",
        )
        for technique in TECHNIQUE_ORDER
    )
    summary_rows.extend(
        [
            ("scope_deviation", metrics.scope_deviation, 0, metrics.scope_deviation, ""),
            (
                "technique_deviation",
                metrics.technique_deviation,
                0,
                metrics.technique_deviation,
                "",
            ),
            ("polarity_coverage", metrics.polarity_coverage, 2, 2 - metrics.polarity_coverage, ""),
            ("includes_reversal", metrics.includes_reversal, True, "", ""),
            ("includes_multi_segment", metrics.includes_multi_segment, True, "", ""),
            ("unique_input_signatures", metrics.unique_input_signatures, "maximize", "", ""),
        ]
    )

    with SELECTION_SUMMARY_CSV.open(
        "w", encoding="utf-8-sig", newline=""
    ) as handle:
        writer = csv.writer(handle)
        writer.writerow(["Metric", "Value", "Target", "AbsoluteDeviation", "Notes"])
        writer.writerows(summary_rows)


def synthetic_candidate(
    candidate_id: str,
    requirement_id: str,
    value: float,
) -> Candidate:
    return Candidate(
        candidate_id=candidate_id,
        requirement_id=requirement_id,
        test_objective="Synthetic self-check only",
        input_type="Constant SpeedRef",
        input_values=(value,),
        test_design_technique="Boundary Value Analysis",
        test_scope="nominal",
    )


def run_self_check() -> None:
    """Check frozen ordering using synthetic data only."""

    exact = SelectionMetrics(
        scope_deviation=0,
        technique_deviation=0,
        polarity_coverage=2,
        includes_reversal=True,
        includes_multi_segment=True,
        unique_input_signatures=9,
        candidate_ids=("A",),
        nominal_count=5,
        stress_count=4,
        technique_counts=tuple(TECHNIQUE_TARGETS.items()),
    )
    assert exact.objective_key() < replace(exact, scope_deviation=2).objective_key()
    assert exact.objective_key() < replace(exact, technique_deviation=2).objective_key()
    assert exact.objective_key() < replace(exact, polarity_coverage=1).objective_key()
    assert exact.objective_key() < replace(exact, includes_reversal=False).objective_key()
    assert exact.objective_key() < replace(exact, includes_multi_segment=False).objective_key()
    assert exact.objective_key() < replace(exact, unique_input_signatures=8).objective_key()
    assert exact.objective_key() < replace(exact, candidate_ids=("B",)).objective_key()

    assert contains_reversal(synthetic_candidate("R", "REQ-REV-001", 1.0)) is False
    reversal = Candidate(
        "R2",
        "REQ-REV-001",
        "Synthetic",
        "Sequence",
        (1.0, -1.0),
        "State Transition",
        "nominal",
    )
    assert contains_reversal(reversal)
    assert is_multi_segment(reversal)

    synthetic = [
        synthetic_candidate("V-A", "REQ-VOLT-001", 1.0),
        synthetic_candidate("V-B", "REQ-VOLT-001", 2.0),
        synthetic_candidate("V-C", "REQ-VOLT-001", 3.0),
        synthetic_candidate("T-A", "REQ-TRK-001", 1.0),
        synthetic_candidate("T-B", "REQ-TRK-001", 2.0),
        synthetic_candidate("T-C", "REQ-TRK-001", 3.0),
        synthetic_candidate("D-A", "REQ-DIR-001", 1.0),
        synthetic_candidate("D-B", "REQ-DIR-001", 2.0),
        Candidate(
            "R-A",
            "REQ-REV-001",
            "Synthetic",
            "Sequence",
            (1.0, -1.0),
            "State Transition",
            "stress",
        ),
        Candidate(
            "R-B",
            "REQ-REV-001",
            "Synthetic",
            "Sequence",
            (-1.0, 1.0),
            "Scenario-Based",
            "stress",
        ),
    ]
    assert calculate_combination_count(synthetic) == 3
    selected, _, evaluated = select_best_combination(synthetic)
    assert evaluated == 3
    assert len(selected) == TOTAL_SELECTED
    assert meets_requirement_quota(selected)
    assert {c.candidate_id for c in selected if c.requirement_id == "REQ-VOLT-001"} == {
        "V-A",
        "V-B",
    }

    official_shape = [
        *[synthetic_candidate(f"V{i}", "REQ-VOLT-001", float(i)) for i in range(1, 7)],
        *[synthetic_candidate(f"T{i}", "REQ-TRK-001", float(i)) for i in range(1, 8)],
        *[synthetic_candidate(f"D{i}", "REQ-DIR-001", float(i)) for i in range(1, 7)],
        *[synthetic_candidate(f"R{i}", "REQ-REV-001", float(i)) for i in range(1, 7)],
    ]
    assert calculate_combination_count(official_shape) == 118_125
    print("selection logic self-check: PASS")
    print("synthetic constrained search combinations: 3")
    print("official-shape combination count check: 118125")
    print("official candidate selection performed: false")


def run_input_check() -> None:
    candidates = load_candidate_pool()
    counts = requirement_counts(candidates)
    print(f"validated CSV candidate count: {len(candidates)}")
    print(f"candidate JSON count: {len(candidates)}")
    print("candidate ID order match: true")
    print(
        "requirement distribution: "
        + json.dumps(
            {name: counts[name] for name in REQUIREMENT_ORDER}, ensure_ascii=False
        )
    )
    print(f"quota-constrained combination count: {calculate_combination_count(candidates)}")
    print("official candidate selection performed: false")
    print("selection output files written: false")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check-input",
        action="store_true",
        help="Read the two allowed input files and calculate search-space size only.",
    )
    mode.add_argument(
        "--self-check",
        action="store_true",
        help="Run synthetic selection-logic checks without reading official inputs.",
    )
    mode.add_argument(
        "--select",
        action="store_true",
        help="Perform official selection and write the two selection CSV files.",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.check_input:
        run_input_check()
        return 0
    if args.self_check:
        run_self_check()
        return 0
    if args.select:
        candidates = load_candidate_pool()
        selected, metrics, evaluated = select_best_combination(candidates)
        write_selection_outputs(selected, metrics, evaluated)
        print(f"official selection completed: {len(selected)} candidates")
        print(f"evaluated combinations: {evaluated}")
        print(f"selected output: {SELECTED_CSV}")
        print(f"summary output: {SELECTION_SUMMARY_CSV}")
        return 0

    parser.print_help()
    print("\nNo action performed. Use --select only for the later official selection step.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
