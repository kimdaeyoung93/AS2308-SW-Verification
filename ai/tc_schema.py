"""Schema for AI-assisted MIL test case candidates.

This module deliberately has no dependency on Manual Test Cases, mutation
data, or coverage results. It uses only Python's standard library.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, ClassVar


ALLOWED_REQUIREMENT_IDS = frozenset(
    {
        "REQ-VOLT-001",
        "REQ-TRK-001",
        "REQ-DIR-001",
        "REQ-REV-001",
    }
)

ALLOWED_TEST_DESIGN_TECHNIQUES = frozenset(
    {
        "Equivalence Partitioning",
        "Boundary Value Analysis",
        "State Transition",
        "Scenario-Based",
    }
)

ALLOWED_TEST_SCOPES = frozenset({"nominal", "stress"})


@dataclass(slots=True)
class TestCaseCandidate:
    """Validated shape of one AI-generated MIL test case candidate."""

    candidate_id: str
    requirement_id: str
    test_objective: str
    precondition: str
    input_type: str
    input_values: list[float]
    expected_behavior: str
    test_design_technique: str
    rationale: str
    test_scope: str = "nominal"

    REQUIRED_FIELDS: ClassVar[tuple[str, ...]] = (
        "candidate_id",
        "requirement_id",
        "test_objective",
        "precondition",
        "input_type",
        "input_values",
        "expected_behavior",
        "test_design_technique",
        "rationale",
    )

    def __post_init__(self) -> None:
        if self.requirement_id not in ALLOWED_REQUIREMENT_IDS:
            raise ValueError(
                f"Unsupported Requirement ID: {self.requirement_id}"
            )
        if self.test_design_technique not in ALLOWED_TEST_DESIGN_TECHNIQUES:
            raise ValueError(
                "Unsupported test design technique: "
                f"{self.test_design_technique}"
            )
        if self.test_scope not in ALLOWED_TEST_SCOPES:
            raise ValueError(f"Unsupported test scope: {self.test_scope}")

    @classmethod
    def from_mapping(cls, data: dict[str, Any]) -> "TestCaseCandidate":
        """Construct a candidate after the validator checks raw fields."""

        return cls(
            candidate_id=str(data["candidate_id"]).strip(),
            requirement_id=str(data["requirement_id"]).strip(),
            test_objective=str(data["test_objective"]).strip(),
            precondition=str(data["precondition"]).strip(),
            input_type=str(data["input_type"]).strip(),
            input_values=[float(value) for value in data["input_values"]],
            expected_behavior=str(data["expected_behavior"]).strip(),
            test_design_technique=str(
                data["test_design_technique"]
            ).strip(),
            rationale=str(data["rationale"]).strip(),
            test_scope=str(data.get("test_scope", "nominal")).strip().lower(),
        )

    def to_dict(self) -> dict[str, Any]:
        """Return a JSON/CSV-friendly representation."""

        return {
            "candidate_id": self.candidate_id,
            "requirement_id": self.requirement_id,
            "test_objective": self.test_objective,
            "precondition": self.precondition,
            "input_type": self.input_type,
            "input_values": self.input_values,
            "expected_behavior": self.expected_behavior,
            "test_design_technique": self.test_design_technique,
            "rationale": self.rationale,
            "test_scope": self.test_scope,
        }
