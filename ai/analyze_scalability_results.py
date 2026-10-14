"""Aggregate frozen scalability-extension results by ordered test budget.

This script is a deterministic post-processor. It does not call an AI API,
MATLAB, Simulink, or a mutation executor.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULT_DIR = ROOT / "results" / "scalability_extension_v1"
BUDGETS = (10, 25, 50, 75, 100)
FROZEN_MUTANTS = tuple(f"MUT-{index:03d}" for index in range(1, 7))
HEALTHY_STATUSES = {
    "PASS",
    "FAIL",
    "INCONCLUSIVE_PRECONDITION",
    "EXECUTION_ERROR",
}
MUTANT_STATUSES = {
    "PASS",
    "FAIL",
    "INCONCLUSIVE_PRECONDITION",
    "EXECUTION_ERROR",
}

INPUT_FILES = {
    "pool": "candidate_pool_frozen.csv",
    "budgets": "budget_definition.csv",
    "healthy": "healthy_execution_results.csv",
    "mutation": "mutation_execution_results.csv",
    "matrix": "mutation_kill_matrix.csv",
    "runtime": "runtime_summary.csv",
    "metadata": "metadata.txt",
}

SUMMARY_FIELDS = (
    "budget",
    "test_count",
    "healthy_pass_count",
    "healthy_pass_rate_percent",
    "healthy_fail_count",
    "healthy_inconclusive_precondition_count",
    "healthy_execution_error_count",
    "mutation_eligible_test_count",
    "valid_mutants",
    "mutants_killed",
    "mutation_score_percent",
    "kill_cells",
    "cumulative_kill_cells",
    "marginal_kill_cell_gain",
    "total_test_mutant_cells",
    "kill_density_percent",
    "inconclusive_mutation_cells",
    "mutation_execution_error_cells",
    "zero_kill_test_count",
    "no_new_mutant_test_count",
    "healthy_elapsed_time_s",
    "mutation_elapsed_time_s",
    "total_elapsed_time_s",
    "completed_execution_count",
    "average_time_per_completed_execution_s",
    "all_killable_mutants_first_killed_index",
    "all_killable_mutants_first_killed_budget",
)

PER_MUTANT_FIELDS = (
    "mutation_id",
    "killed_within_100",
    "first_kill_test_index",
    "first_killing_candidate",
    "first_kill_budget",
    "total_kill_cells",
)

PER_TEST_FIELDS = (
    "ordered_index",
    "extension_candidate_id",
    "requirement_id",
    "healthy_status",
    "mutation_eligible",
    "killed_mutant_count",
    "newly_killed_mutant_count",
    "cumulative_unique_mutants_killed",
    "zero_kill",
    "no_new_mutant",
)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def require_columns(rows: list[dict[str, str]], required: Iterable[str], label: str) -> None:
    if not rows:
        raise ValueError(f"{label} is empty")
    missing = set(required) - set(rows[0])
    if missing:
        raise ValueError(f"{label} is missing columns: {', '.join(sorted(missing))}")


def parse_int(value: str, label: str) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{label} must be an integer: {value!r}") from error
    return parsed


def parse_float(value: str, label: str) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{label} must be numeric: {value!r}") from error
    if not math.isfinite(parsed):
        raise ValueError(f"{label} must be finite")
    return parsed


def parse_bool(value: str, label: str) -> bool:
    normalized = str(value).strip().lower()
    if normalized in {"true", "1"}:
        return True
    if normalized in {"false", "0"}:
        return False
    raise ValueError(f"{label} must be true/false or 1/0: {value!r}")


def safe_percent(numerator: int, denominator: int) -> float:
    return 0.0 if denominator == 0 else 100.0 * numerator / denominator


def containing_budget(index: int | None) -> int | str:
    if index is None:
        return ""
    for budget in BUDGETS:
        if index <= budget:
            return budget
    raise ValueError(f"ordered index is outside frozen budgets: {index}")


def matlab_variable_name(candidate_id: str) -> str:
    """Mirror makeValidName for the frozen EXT-* ASCII identifiers."""
    converted = re.sub(r"[^A-Za-z0-9_]", "_", candidate_id)
    if not converted or not converted[0].isalpha():
        converted = "x" + converted
    return converted


def normalize_inputs(
    pool_rows: list[dict[str, str]],
    budget_rows: list[dict[str, str]],
    healthy_rows: list[dict[str, str]],
    mutation_rows: list[dict[str, str]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], tuple[str, ...]]:
    require_columns(
        pool_rows,
        ("selection_order", "extension_candidate_id", "requirement_id", "frozen_pool_sha256"),
        "candidate_pool_frozen.csv",
    )
    if len(pool_rows) != 100:
        raise ValueError(f"frozen pool row count must be 100, got {len(pool_rows)}")
    pool: list[dict[str, Any]] = []
    for row in pool_rows:
        pool.append(
            {
                **row,
                "ordered_index": parse_int(row["selection_order"], "selection_order"),
                "extension_candidate_id": row["extension_candidate_id"].strip(),
                "requirement_id": row["requirement_id"].strip(),
            }
        )
    indices = [row["ordered_index"] for row in pool]
    if indices != list(range(1, 101)) or len(set(indices)) != 100:
        raise ValueError("frozen pool must be uniquely ordered 1 through 100")
    candidate_ids = [row["extension_candidate_id"] for row in pool]
    if len(set(candidate_ids)) != 100 or any(not value for value in candidate_ids):
        raise ValueError("frozen pool candidate IDs must be nonempty and unique")
    pool_hashes = {row["frozen_pool_sha256"].strip() for row in pool}
    if len(pool_hashes) != 1 or "" in pool_hashes:
        raise ValueError("frozen pool hash is missing or inconsistent")

    require_columns(
        budget_rows,
        ("budget", "start_index", "end_index", "selection_rule", "frozen_pool_sha256"),
        "budget_definition.csv",
    )
    parsed_budgets = [parse_int(row["budget"], "budget") for row in budget_rows]
    if parsed_budgets != list(BUDGETS):
        raise ValueError(f"budget definitions must be exactly {list(BUDGETS)}")
    expected_hash = next(iter(pool_hashes))
    for row, budget in zip(budget_rows, BUDGETS):
        if (
            parse_int(row["start_index"], "start_index") != 1
            or parse_int(row["end_index"], "end_index") != budget
            or row["selection_rule"].strip() != "ordered_prefix"
            or row["frozen_pool_sha256"].strip() != expected_hash
        ):
            raise ValueError(f"budget {budget} is not the frozen ordered prefix")

    require_columns(
        healthy_rows,
        (
            "run_id",
            "ordered_index",
            "extension_candidate_id",
            "requirement_id",
            "status",
            "elapsed_time_s",
        ),
        "healthy_execution_results.csv",
    )
    if len(healthy_rows) != 100:
        raise ValueError(f"healthy result row count must be 100, got {len(healthy_rows)}")
    healthy: list[dict[str, Any]] = []
    for row in healthy_rows:
        status = row["status"].strip()
        if status not in HEALTHY_STATUSES:
            raise ValueError(f"unknown healthy status: {status}")
        healthy.append(
            {
                **row,
                "ordered_index": parse_int(row["ordered_index"], "healthy ordered_index"),
                "extension_candidate_id": row["extension_candidate_id"].strip(),
                "requirement_id": row["requirement_id"].strip(),
                "status": status,
                "elapsed_time_s": parse_float(row["elapsed_time_s"], "healthy elapsed_time_s"),
            }
        )
    if [row["ordered_index"] for row in healthy] != indices:
        raise ValueError("healthy results do not preserve frozen ordered indices")
    if [row["extension_candidate_id"] for row in healthy] != candidate_ids:
        raise ValueError("healthy results do not preserve frozen candidate identity/order")
    if [row["requirement_id"] for row in healthy] != [row["requirement_id"] for row in pool]:
        raise ValueError("healthy requirement IDs differ from the frozen pool")
    if len({row["run_id"].strip() for row in healthy}) != 1:
        raise ValueError("healthy results contain inconsistent run_id values")

    require_columns(
        mutation_rows,
        (
            "run_id",
            "mutation_id",
            "ordered_index",
            "extension_candidate_id",
            "requirement_id",
            "healthy_status",
            "mutant_status",
            "kill",
            "elapsed_time_s",
        ),
        "mutation_execution_results.csv",
    )
    mutation: list[dict[str, Any]] = []
    valid_mutant_ids: set[str] = set()
    seen_cells: set[tuple[str, str]] = set()
    healthy_by_id = {row["extension_candidate_id"]: row for row in healthy}
    for row in mutation_rows:
        mutation_id = row["mutation_id"].strip()
        if mutation_id not in FROZEN_MUTANTS:
            raise ValueError(f"mutation ID is outside frozen MUT-001..006: {mutation_id}")
        candidate_id = row["extension_candidate_id"].strip()
        if candidate_id not in healthy_by_id:
            raise ValueError(f"mutation result references unknown candidate: {candidate_id}")
        healthy_row = healthy_by_id[candidate_id]
        mutant_status = row["mutant_status"].strip()
        if mutant_status not in MUTANT_STATUSES:
            raise ValueError(f"unknown mutant status: {mutant_status}")
        cell = (mutation_id, candidate_id)
        if cell in seen_cells:
            raise ValueError(f"duplicate mutation cell: {mutation_id}/{candidate_id}")
        seen_cells.add(cell)
        healthy_status = row["healthy_status"].strip()
        kill = parse_bool(row["kill"], "kill")
        expected_kill = healthy_status == "PASS" and mutant_status == "FAIL"
        if healthy_status != healthy_row["status"] or healthy_status != "PASS":
            raise ValueError(
                f"non-PASS healthy candidate entered mutation denominator: {candidate_id}"
            )
        if kill != expected_kill:
            raise ValueError(
                f"KILL must be Healthy PASS -> Mutant FAIL: {mutation_id}/{candidate_id}"
            )
        ordered_index = parse_int(row["ordered_index"], "mutation ordered_index")
        if ordered_index != healthy_row["ordered_index"]:
            raise ValueError(f"mutation ordered index mismatch for {candidate_id}")
        if row["requirement_id"].strip() != healthy_row["requirement_id"]:
            raise ValueError(f"mutation requirement mismatch for {candidate_id}")
        mutation.append(
            {
                **row,
                "mutation_id": mutation_id,
                "ordered_index": ordered_index,
                "extension_candidate_id": candidate_id,
                "healthy_status": healthy_status,
                "mutant_status": mutant_status,
                "kill": kill,
                "elapsed_time_s": parse_float(row["elapsed_time_s"], "mutation elapsed_time_s"),
            }
        )
        valid_mutant_ids.add(mutation_id)

    valid_mutants = tuple(sorted(valid_mutant_ids))
    if not valid_mutants:
        raise ValueError("mutation results contain no valid mutants")
    eligible_ids = {row["extension_candidate_id"] for row in healthy if row["status"] == "PASS"}
    expected_cells = {(mutant, candidate) for mutant in valid_mutants for candidate in eligible_ids}
    if seen_cells != expected_cells:
        missing = len(expected_cells - seen_cells)
        extra = len(seen_cells - expected_cells)
        raise ValueError(
            f"mutation execution cells are incomplete/inconsistent: missing={missing}, extra={extra}"
        )
    mutation.sort(key=lambda row: (row["ordered_index"], row["mutation_id"]))
    return pool, healthy, mutation, valid_mutants


def validate_kill_matrix(
    matrix_rows: list[dict[str, str]],
    pool: list[dict[str, Any]],
    healthy: list[dict[str, Any]],
    mutation: list[dict[str, Any]],
    valid_mutants: tuple[str, ...],
) -> None:
    require_columns(matrix_rows, ("mutation_id",), "mutation_kill_matrix.csv")
    matrix_ids = tuple(row["mutation_id"].strip() for row in matrix_rows)
    if matrix_ids != valid_mutants:
        raise ValueError("kill matrix mutant rows differ from valid mutation executions")
    candidate_columns = [matlab_variable_name(row["extension_candidate_id"]) for row in pool]
    if len(set(candidate_columns)) != 100:
        raise ValueError("candidate IDs collide after MATLAB table-name conversion")
    missing_columns = set(candidate_columns) - set(matrix_rows[0])
    extra_columns = set(matrix_rows[0]) - {"mutation_id", *candidate_columns}
    if missing_columns or extra_columns:
        raise ValueError(
            "kill matrix candidate columns differ from the frozen pool: "
            f"missing={len(missing_columns)}, extra={len(extra_columns)}"
        )
    healthy_status = {row["extension_candidate_id"]: row["status"] for row in healthy}
    execution = {
        (row["mutation_id"], row["extension_candidate_id"]): row["mutant_status"]
        for row in mutation
    }
    expected_label = {
        "FAIL": "KILL",
        "PASS": "PASS",
        "INCONCLUSIVE_PRECONDITION": "INCONCLUSIVE",
        "EXECUTION_ERROR": "EXECUTION_ERROR",
    }
    matrix_cell_count = 0
    execution_backed_cells = 0
    for matrix_row in matrix_rows:
        mutant = matrix_row["mutation_id"].strip()
        for pool_row, column in zip(pool, candidate_columns):
            candidate = pool_row["extension_candidate_id"]
            observed = matrix_row[column].strip()
            matrix_cell_count += 1
            if healthy_status[candidate] == "PASS":
                key = (mutant, candidate)
                if key not in execution:
                    raise ValueError(f"kill matrix cell has no execution result: {key}")
                expected = expected_label[execution[key]]
                execution_backed_cells += 1
            else:
                expected = "NOT_EXECUTED"
            if observed != expected:
                raise ValueError(
                    f"kill matrix mismatch for {mutant}/{candidate}: {observed} != {expected}"
                )
    if matrix_cell_count != len(valid_mutants) * 100:
        raise ValueError("kill matrix cell count is inconsistent")
    if execution_backed_cells != len(mutation):
        raise ValueError("kill matrix and mutation execution cell counts differ")


def validate_runtime(
    runtime_rows: list[dict[str, str]],
    healthy: list[dict[str, Any]],
    mutation: list[dict[str, Any]],
) -> None:
    require_columns(
        runtime_rows,
        (
            "healthy_execution_count",
            "mutation_execution_count",
            "total_execution_count",
            "healthy_elapsed_time_s",
            "mutation_elapsed_time_s",
            "total_simulation_elapsed_time_s",
            "execution_error_count",
            "completion_status",
        ),
        "runtime_summary.csv",
    )
    if len(runtime_rows) != 1:
        raise ValueError("runtime_summary.csv must contain one row")
    row = runtime_rows[0]
    healthy_count = parse_int(row["healthy_execution_count"], "healthy_execution_count")
    mutation_count = parse_int(row["mutation_execution_count"], "mutation_execution_count")
    total_count = parse_int(row["total_execution_count"], "total_execution_count")
    if (healthy_count, mutation_count, total_count) != (
        len(healthy),
        len(mutation),
        len(healthy) + len(mutation),
    ):
        raise ValueError("runtime execution counts differ from result artifacts")
    observed_errors = sum(row["status"] == "EXECUTION_ERROR" for row in healthy) + sum(
        row["mutant_status"] == "EXECUTION_ERROR" for row in mutation
    )
    if parse_int(row["execution_error_count"], "execution_error_count") != observed_errors:
        raise ValueError("runtime execution_error_count differs from execution artifacts")
    healthy_phase = parse_float(row["healthy_elapsed_time_s"], "healthy phase elapsed")
    mutation_phase = parse_float(row["mutation_elapsed_time_s"], "mutation phase elapsed")
    total_phase = parse_float(row["total_simulation_elapsed_time_s"], "total phase elapsed")
    if healthy_phase + 1e-9 < sum(item["elapsed_time_s"] for item in healthy):
        raise ValueError("healthy phase runtime is shorter than summed per-test runtime")
    if mutation_phase + 1e-9 < sum(item["elapsed_time_s"] for item in mutation):
        raise ValueError("mutation phase runtime is shorter than summed per-execution runtime")
    if not math.isclose(total_phase, healthy_phase + mutation_phase, rel_tol=1e-12, abs_tol=1e-9):
        raise ValueError("total runtime differs from healthy + mutation phase runtime")
    if row["completion_status"].strip() != "COMPLETED":
        raise ValueError("runtime summary is not a completed Extension run")


def analyze_rows(
    pool: list[dict[str, Any]],
    healthy: list[dict[str, Any]],
    mutation: list[dict[str, Any]],
    valid_mutants: tuple[str, ...],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    mutation_by_index: dict[int, list[dict[str, Any]]] = {}
    for row in mutation:
        mutation_by_index.setdefault(row["ordered_index"], []).append(row)

    seen_mutants: set[str] = set()
    per_test: list[dict[str, Any]] = []
    first_kill: dict[str, tuple[int, str]] = {}
    for pool_row, healthy_row in zip(pool, healthy):
        index = pool_row["ordered_index"]
        cells = mutation_by_index.get(index, [])
        killed = {row["mutation_id"] for row in cells if row["kill"]}
        new_kills = killed - seen_mutants
        eligible = healthy_row["status"] == "PASS"
        if not eligible and cells:
            raise ValueError(f"non-eligible test has mutation cells at index {index}")
        for mutation_id in sorted(new_kills):
            first_kill[mutation_id] = (index, pool_row["extension_candidate_id"])
        seen_mutants.update(killed)
        per_test.append(
            {
                "ordered_index": index,
                "extension_candidate_id": pool_row["extension_candidate_id"],
                "requirement_id": pool_row["requirement_id"],
                "healthy_status": healthy_row["status"],
                "mutation_eligible": str(eligible).lower(),
                "killed_mutant_count": len(killed),
                "newly_killed_mutant_count": len(new_kills),
                "cumulative_unique_mutants_killed": len(seen_mutants),
                "zero_kill": str(eligible and not killed).lower(),
                "no_new_mutant": str(eligible and bool(killed) and not new_kills).lower(),
            }
        )

    killed_anywhere = sorted(first_kill)
    if killed_anywhere:
        all_first_index: int | str = max(first_kill[mutant][0] for mutant in killed_anywhere)
        all_first_budget: int | str = containing_budget(int(all_first_index))
    else:
        all_first_index = ""
        all_first_budget = ""

    budget_summary: list[dict[str, Any]] = []
    previous_kill_cells = 0
    for budget in BUDGETS:
        healthy_prefix = healthy[:budget]
        mutation_prefix = [row for row in mutation if row["ordered_index"] <= budget]
        per_test_prefix = per_test[:budget]
        healthy_pass = sum(row["status"] == "PASS" for row in healthy_prefix)
        kill_cells = sum(row["kill"] for row in mutation_prefix)
        killed_mutants = {row["mutation_id"] for row in mutation_prefix if row["kill"]}
        total_cells = healthy_pass * len(valid_mutants)
        healthy_elapsed = sum(row["elapsed_time_s"] for row in healthy_prefix)
        mutation_elapsed = sum(row["elapsed_time_s"] for row in mutation_prefix)
        completed = len(healthy_prefix) + len(mutation_prefix)
        total_elapsed = healthy_elapsed + mutation_elapsed
        budget_summary.append(
            {
                "budget": budget,
                "test_count": budget,
                "healthy_pass_count": healthy_pass,
                "healthy_pass_rate_percent": safe_percent(healthy_pass, budget),
                "healthy_fail_count": sum(row["status"] == "FAIL" for row in healthy_prefix),
                "healthy_inconclusive_precondition_count": sum(
                    row["status"] == "INCONCLUSIVE_PRECONDITION" for row in healthy_prefix
                ),
                "healthy_execution_error_count": sum(
                    row["status"] == "EXECUTION_ERROR" for row in healthy_prefix
                ),
                "mutation_eligible_test_count": healthy_pass,
                "valid_mutants": len(valid_mutants),
                "mutants_killed": len(killed_mutants),
                "mutation_score_percent": safe_percent(len(killed_mutants), len(valid_mutants)),
                "kill_cells": kill_cells,
                "cumulative_kill_cells": kill_cells,
                "marginal_kill_cell_gain": kill_cells - previous_kill_cells,
                "total_test_mutant_cells": total_cells,
                "kill_density_percent": safe_percent(kill_cells, total_cells),
                "inconclusive_mutation_cells": sum(
                    row["mutant_status"] == "INCONCLUSIVE_PRECONDITION"
                    for row in mutation_prefix
                ),
                "mutation_execution_error_cells": sum(
                    row["mutant_status"] == "EXECUTION_ERROR" for row in mutation_prefix
                ),
                "zero_kill_test_count": sum(row["zero_kill"] == "true" for row in per_test_prefix),
                "no_new_mutant_test_count": sum(
                    row["no_new_mutant"] == "true" for row in per_test_prefix
                ),
                "healthy_elapsed_time_s": healthy_elapsed,
                "mutation_elapsed_time_s": mutation_elapsed,
                "total_elapsed_time_s": total_elapsed,
                "completed_execution_count": completed,
                "average_time_per_completed_execution_s": (
                    total_elapsed / completed if completed else ""
                ),
                "all_killable_mutants_first_killed_index": all_first_index,
                "all_killable_mutants_first_killed_budget": all_first_budget,
            }
        )
        previous_kill_cells = kill_cells

    per_mutant: list[dict[str, Any]] = []
    for mutant in valid_mutants:
        first = first_kill.get(mutant)
        per_mutant.append(
            {
                "mutation_id": mutant,
                "killed_within_100": str(first is not None).lower(),
                "first_kill_test_index": first[0] if first else "",
                "first_killing_candidate": first[1] if first else "",
                "first_kill_budget": containing_budget(first[0]) if first else "",
                "total_kill_cells": sum(
                    row["mutation_id"] == mutant and row["kill"] for row in mutation
                ),
            }
        )
    return budget_summary, per_mutant, per_test


def atomic_write_csv(path: Path, fields: Iterable[str], rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
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
            writer = csv.DictWriter(handle, fieldnames=list(fields), extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
            temporary = Path(handle.name)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def parse_metadata(path: Path) -> dict[str, str]:
    metadata: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if not line.strip():
            continue
        if "=" not in line:
            raise ValueError(f"metadata line is not key=value: {line!r}")
        key, value = line.split("=", 1)
        if key in metadata:
            raise ValueError(f"duplicate metadata key: {key}")
        metadata[key.strip()] = value.strip()
    if metadata.get("completion_status") != "COMPLETED":
        raise ValueError("metadata does not describe a completed Extension run")
    return metadata


def analyze_result_directory(result_dir: Path) -> tuple[list[dict[str, Any]], ...]:
    paths = {name: result_dir / filename for name, filename in INPUT_FILES.items()}
    missing = [str(path) for path in paths.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError("Missing scalability result input(s):\n" + "\n".join(missing))
    pool_rows = read_csv(paths["pool"])
    budget_rows = read_csv(paths["budgets"])
    healthy_rows = read_csv(paths["healthy"])
    mutation_rows = read_csv(paths["mutation"])
    matrix_rows = read_csv(paths["matrix"])
    runtime_rows = read_csv(paths["runtime"])
    metadata = parse_metadata(paths["metadata"])
    pool, healthy, mutation, valid_mutants = normalize_inputs(
        pool_rows, budget_rows, healthy_rows, mutation_rows
    )
    validate_kill_matrix(matrix_rows, pool, healthy, mutation, valid_mutants)
    validate_runtime(runtime_rows, healthy, mutation)
    run_ids = {row["run_id"].strip() for row in healthy + mutation}
    if len(run_ids) != 1 or metadata.get("run_id") not in run_ids:
        raise ValueError("metadata run_id differs from execution artifacts")
    return analyze_rows(pool, healthy, mutation, valid_mutants)


def synthetic_fixture() -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    pool = [
        {
            "ordered_index": index,
            "extension_candidate_id": f"EXT-SYN-TC-{index:03d}",
            "requirement_id": "REQ-TRK-001",
        }
        for index in range(1, 101)
    ]
    healthy = [
        {
            "ordered_index": index,
            "extension_candidate_id": f"EXT-SYN-TC-{index:03d}",
            "requirement_id": "REQ-TRK-001",
            "status": "PASS",
            "elapsed_time_s": 1.0,
        }
        for index in range(1, 101)
    ]
    kills = {
        (1, "MUT-001"),
        (2, "MUT-001"),
        (12, "MUT-002"),
        (12, "MUT-003"),
        (12, "MUT-004"),
        (12, "MUT-005"),
        (12, "MUT-006"),
    }
    mutation: list[dict[str, Any]] = []
    for index in range(1, 101):
        for mutant in FROZEN_MUTANTS:
            killed = (index, mutant) in kills
            mutation.append(
                {
                    "ordered_index": index,
                    "extension_candidate_id": f"EXT-SYN-TC-{index:03d}",
                    "mutation_id": mutant,
                    "mutant_status": "FAIL" if killed else "PASS",
                    "kill": killed,
                    "elapsed_time_s": 2.0,
                }
            )
    return pool, healthy, mutation


def run_self_check() -> None:
    pool, healthy, mutation = synthetic_fixture()
    budgets, mutants, tests = analyze_rows(pool, healthy, mutation, FROZEN_MUTANTS)
    by_budget = {row["budget"]: row for row in budgets}
    assert [row["test_count"] for row in budgets] == list(BUDGETS)
    assert by_budget[10]["kill_cells"] == 2
    assert by_budget[10]["marginal_kill_cell_gain"] == 2
    assert by_budget[25]["kill_cells"] == 7
    assert by_budget[25]["marginal_kill_cell_gain"] == 5
    assert by_budget[50]["marginal_kill_cell_gain"] == 0
    assert by_budget[10]["mutants_killed"] == 1
    assert by_budget[25]["mutants_killed"] == 6
    assert by_budget[25]["mutation_score_percent"] == 100.0
    assert math.isclose(by_budget[10]["kill_density_percent"], 100 * 2 / 60)
    assert by_budget[10]["zero_kill_test_count"] == 8
    assert by_budget[10]["no_new_mutant_test_count"] == 1
    assert by_budget[25]["zero_kill_test_count"] == 22
    assert by_budget[25]["no_new_mutant_test_count"] == 1
    assert by_budget[25]["all_killable_mutants_first_killed_index"] == 12
    assert by_budget[25]["all_killable_mutants_first_killed_budget"] == 25
    first = {row["mutation_id"]: row for row in mutants}
    assert first["MUT-001"]["first_kill_test_index"] == 1
    assert first["MUT-002"]["first_kill_test_index"] == 12
    assert tests[0]["newly_killed_mutant_count"] == 1
    assert tests[1]["no_new_mutant"] == "true"
    assert tests[2]["zero_kill"] == "true"
    print("Scalability analysis synthetic self-check: PASS")
    print("budgets: 10, 25, 50, 75, 100")
    print("budget 10: kill_cells=2, unique_mutants=1, zero_kill=8, no_new=1")
    print("budget 25: kill_cells=7, unique_mutants=6, marginal_gain=5")
    print("all killable synthetic mutants first killed: index=12, budget=25")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", type=Path, default=DEFAULT_RESULT_DIR)
    parser.add_argument("--self-check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.self_check:
            run_self_check()
            return 0
        budget_rows, mutant_rows, test_rows = analyze_result_directory(args.results_dir)
        atomic_write_csv(
            args.results_dir / "budget_effectiveness_summary.csv", SUMMARY_FIELDS, budget_rows
        )
        atomic_write_csv(
            args.results_dir / "per_mutant_first_kill.csv", PER_MUTANT_FIELDS, mutant_rows
        )
        atomic_write_csv(
            args.results_dir / "per_test_detection_summary.csv", PER_TEST_FIELDS, test_rows
        )
    except (OSError, ValueError) as error:
        print(f"Scalability result analysis ERROR: {error}", file=sys.stderr)
        return 2
    print(f"Scalability result analysis: PASS ({args.results_dir})")
    for row in budget_rows:
        print(
            f"budget {row['budget']}: kill_cells={row['kill_cells']}, "
            f"mutants_killed={row['mutants_killed']}/{row['valid_mutants']}, "
            f"marginal_gain={row['marginal_kill_cell_gain']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
