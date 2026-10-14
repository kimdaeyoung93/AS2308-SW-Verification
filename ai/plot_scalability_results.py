"""Create deterministic scalability-result figures from frozen CSV evidence.

This post-processing script does not call an AI API, MATLAB, Simulink, or a
mutation executor. Plot values are read from existing result CSV files.
"""

from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path
from typing import Iterable

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULT_DIR = ROOT / "results" / "scalability_extension_v1"
EXPECTED_BUDGETS = (10, 25, 50, 75, 100)
PNG_DPI = 300


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        raise FileNotFoundError(f"Required result file does not exist: {path}")
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise ValueError(f"Result file is empty: {path}")
    return rows


def require_columns(
    rows: list[dict[str, str]], required: Iterable[str], label: str
) -> None:
    missing = set(required) - set(rows[0])
    if missing:
        raise ValueError(f"{label} is missing columns: {', '.join(sorted(missing))}")


def parse_float(value: str, label: str) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{label} must be numeric: {value!r}") from error
    if not math.isfinite(parsed):
        raise ValueError(f"{label} must be finite")
    return parsed


def load_budget_results(result_dir: Path) -> list[dict[str, float]]:
    path = result_dir / "budget_effectiveness_summary.csv"
    rows = read_csv(path)
    required = (
        "budget",
        "cumulative_kill_cells",
        "kill_density_percent",
        "mutation_score_percent",
        "total_elapsed_time_s",
    )
    require_columns(rows, required, path.name)

    parsed: list[dict[str, float]] = []
    for row in rows:
        parsed.append({name: parse_float(row[name], name) for name in required})
    budgets = tuple(int(row["budget"]) for row in parsed)
    if budgets != EXPECTED_BUDGETS:
        raise ValueError(
            f"Frozen budgets must be {EXPECTED_BUDGETS}, got {budgets}"
        )
    if any(row["cumulative_kill_cells"] < 0 for row in parsed):
        raise ValueError("Cumulative kill cells cannot be negative")
    if any(not 0 <= row["kill_density_percent"] <= 100 for row in parsed):
        raise ValueError("Kill density must be between 0 and 100 percent")
    if any(not 0 <= row["mutation_score_percent"] <= 100 for row in parsed):
        raise ValueError("Mutation score must be between 0 and 100 percent")
    if any(row["total_elapsed_time_s"] < 0 for row in parsed):
        raise ValueError("Total execution time cannot be negative")
    return parsed


def configure_style() -> None:
    plt.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 10,
            "axes.titlesize": 13,
            "axes.labelsize": 11,
            "figure.figsize": (8.0, 5.0),
            "figure.dpi": 100,
            "savefig.dpi": PNG_DPI,
            "axes.spines.top": False,
            "axes.spines.right": False,
        }
    )


def save_line_plot(
    output_path: Path,
    budgets: list[int],
    values: list[float],
    *,
    title: str,
    y_label: str,
    value_format: str,
    y_limits: tuple[float, float] | None = None,
) -> None:
    figure, axis = plt.subplots()
    axis.plot(
        budgets,
        values,
        color="#1769AA",
        marker="o",
        linewidth=2.0,
        markersize=6,
    )
    axis.set_title(title)
    axis.set_xlabel("Test Budget (top-level executions)")
    axis.set_ylabel(y_label)
    axis.set_xticks(budgets)
    axis.grid(axis="y", color="#D9D9D9", linewidth=0.8)
    if y_limits is not None:
        axis.set_ylim(*y_limits)
    for x_value, y_value in zip(budgets, values):
        axis.annotate(
            value_format.format(y_value),
            (x_value, y_value),
            xytext=(0, 8),
            textcoords="offset points",
            ha="center",
            fontsize=9,
        )
    figure.tight_layout()
    figure.savefig(
        output_path,
        dpi=PNG_DPI,
        bbox_inches="tight",
        metadata={"Software": "AS2308 deterministic scalability plotting"},
    )
    plt.close(figure)


def create_figures(result_dir: Path) -> list[Path]:
    rows = load_budget_results(result_dir)
    budgets = [int(row["budget"]) for row in rows]
    figure_dir = result_dir / "figures"
    figure_dir.mkdir(parents=True, exist_ok=True)
    configure_style()

    outputs = [
        figure_dir / "figure_1_budget_vs_cumulative_kill_cells.png",
        figure_dir / "figure_2_budget_vs_kill_density.png",
        figure_dir / "figure_3_budget_vs_mutation_score.png",
        figure_dir / "figure_4_budget_vs_total_execution_time.png",
    ]
    save_line_plot(
        outputs[0],
        budgets,
        [row["cumulative_kill_cells"] for row in rows],
        title="Test Budget vs Cumulative Kill Cells",
        y_label="Cumulative Kill Cells (count)",
        value_format="{:.0f}",
    )
    save_line_plot(
        outputs[1],
        budgets,
        [row["kill_density_percent"] for row in rows],
        title="Test Budget vs Kill Density",
        y_label="Kill Density (%)",
        value_format="{:.2f}%",
        y_limits=(0, 30),
    )
    save_line_plot(
        outputs[2],
        budgets,
        [row["mutation_score_percent"] for row in rows],
        title="Mutation Score by Frozen Test Budget",
        y_label="Mutation Score (%)",
        value_format="{:.0f}%",
        y_limits=(0, 105),
    )
    save_line_plot(
        outputs[3],
        budgets,
        [row["total_elapsed_time_s"] for row in rows],
        title="Test Budget vs Total Execution Time",
        y_label="Cumulative Execution Time (s)",
        value_format="{:.2f}",
    )
    return outputs


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot frozen AS2308 scalability-extension CSV results."
    )
    parser.add_argument(
        "--result-dir",
        type=Path,
        default=DEFAULT_RESULT_DIR,
        help="Directory containing budget_effectiveness_summary.csv",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    outputs = create_figures(args.result_dir.resolve())
    print("Scalability result plotting: PASS")
    for output in outputs:
        print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
