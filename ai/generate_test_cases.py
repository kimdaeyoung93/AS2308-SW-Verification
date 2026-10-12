"""Generate AI-assisted requirements-based MIL test case candidates.

Dry run (no API call):
    python ai/generate_test_cases.py --dry-run

Official generation:
    python ai/generate_test_cases.py

Only the AI Test Basis, generation prompt, and schema defined from
tc_schema.py are sent to the Google Gemini API. Generation does not run
the downstream candidate validator and does not use any test-result data.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from tc_schema import (
    ALLOWED_REQUIREMENT_IDS,
    ALLOWED_TEST_DESIGN_TECHNIQUES,
    ALLOWED_TEST_SCOPES,
    TestCaseCandidate,
)


DEFAULT_MODEL = "gemini-3.8-flash"
THINKING_LEVEL = "medium"
CANDIDATE_BUDGET = 25

LEAKAGE_MARKERS = (
    "MUT-",
    "manual_suite",
    "kill matrix",
    "mutation score",
    "16.75",
    "MTC-",
    "coverage 100",
)


def build_candidate_schema() -> dict[str, Any]:
    """Build the structured-output schema from the local TC schema."""

    candidate_properties: dict[str, Any] = {
        "candidate_id": {"type": "string", "minLength": 1},
        "requirement_id": {
            "type": "string",
            "enum": sorted(ALLOWED_REQUIREMENT_IDS),
        },
        "test_objective": {"type": "string", "minLength": 1},
        "precondition": {"type": "string", "minLength": 1},
        "input_type": {"type": "string", "minLength": 1},
        "input_values": {
            "type": "array",
            "items": {"type": "number"},
            "minItems": 1,
        },
        "expected_behavior": {"type": "string", "minLength": 1},
        "test_design_technique": {
            "type": "string",
            "enum": sorted(ALLOWED_TEST_DESIGN_TECHNIQUES),
        },
        "rationale": {"type": "string", "minLength": 1},
        "test_scope": {
            "type": "string",
            "enum": sorted(ALLOWED_TEST_SCOPES),
        },
    }
    required_fields = [
        *TestCaseCandidate.REQUIRED_FIELDS,
        "test_scope",
    ]
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "candidates": {
                "type": "array",
                "minItems": CANDIDATE_BUDGET,
                "maxItems": CANDIDATE_BUDGET,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": candidate_properties,
                    "required": required_fields,
                },
            }
        },
        "required": ["candidates"],
    }


def build_api_sources(
    test_basis_text: str, prompt_text: str, output_schema: dict[str, Any]
) -> dict[str, str]:
    """Return the only three information sources allowed into the request."""

    return {
        "AI Test Basis": test_basis_text,
        "TC generation instruction": prompt_text,
        "TC output schema": json.dumps(
            output_schema, ensure_ascii=False, sort_keys=True
        ),
    }


def find_leakage(source_texts: dict[str, str]) -> list[tuple[str, str]]:
    """Find specific Manual/Mutation/Coverage-result leakage markers."""

    findings: list[tuple[str, str]] = []
    for source_name, source_text in source_texts.items():
        lowered_text = source_text.casefold()
        for marker in LEAKAGE_MARKERS:
            if marker.casefold() in lowered_text:
                findings.append((source_name, marker))
    return findings


def _strict_parse_candidates(output_text: str) -> dict[str, Any]:
    """Parse and verify the complete response before any output is written."""

    try:
        payload = json.loads(output_text)
    except json.JSONDecodeError as error:
        raise ValueError(f"Response is not valid JSON: {error}") from error

    if not isinstance(payload, dict) or set(payload) != {"candidates"}:
        raise ValueError("Response must contain only the top-level candidates key")
    candidates = payload["candidates"]
    if not isinstance(candidates, list) or len(candidates) != CANDIDATE_BUDGET:
        raise ValueError(
            f"Response must contain exactly {CANDIDATE_BUDGET} candidates"
        )

    expected_fields = {
        *TestCaseCandidate.REQUIRED_FIELDS,
        "test_scope",
    }
    parsed_candidates: list[dict[str, Any]] = []
    candidate_ids: set[str] = set()
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, dict) or set(candidate) != expected_fields:
            raise ValueError(
                f"Candidate {index + 1} does not exactly match the TC schema"
            )
        for field_name in expected_fields - {"input_values"}:
            if not isinstance(candidate[field_name], str) or not candidate[
                field_name
            ].strip():
                raise ValueError(
                    f"Candidate {index + 1} field {field_name} must be nonempty text"
                )
        values = candidate["input_values"]
        if not isinstance(values, list) or not values:
            raise ValueError(
                f"Candidate {index + 1} input_values must be a nonempty list"
            )
        if any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            for value in values
        ):
            raise ValueError(
                f"Candidate {index + 1} input_values must be finite numbers"
            )

        parsed = TestCaseCandidate.from_mapping(candidate)
        if parsed.candidate_id in candidate_ids:
            raise ValueError(f"Duplicate candidate_id: {parsed.candidate_id}")
        candidate_ids.add(parsed.candidate_id)
        parsed_candidates.append(parsed.to_dict())

    return {"candidates": parsed_candidates}


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
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
        ) as file:
            json.dump(payload, file, indent=2, ensure_ascii=False, allow_nan=False)
            file.write("\n")
            temporary_path = Path(file.name)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def _dry_run_report(
    model: str,
    test_basis_path: Path,
    prompt_path: Path,
    prompt_text: str,
    test_basis_text: str,
    source_texts: dict[str, str],
) -> bool:
    # The request consists only of the prompt, Test Basis, and response schema.
    final_input_text = json.dumps(source_texts, ensure_ascii=False, sort_keys=True)
    api_key_present = bool(os.environ.get("GEMINI_API_KEY", "").strip())
    findings = find_leakage(source_texts)

    print("AI-Assisted Test Case Generator V1 - DRY RUN")
    print("provider: Google Gemini")
    print(f"selected_model: {model}")
    print(f"thinking_level: {THINKING_LEVEL}")
    print(f"candidate_budget: {CANDIDATE_BUDGET}")
    print(f"test_basis_path: {test_basis_path}")
    print(f"prompt_path: {prompt_path}")
    print(f"final_api_input_character_count: {len(final_input_text)}")
    print(f"gemini_api_key_present: {str(api_key_present).lower()}")
    print("api_source_types:")
    for source_name in source_texts:
        print(f"  - {source_name}")

    if findings:
        print("leakage_sanity_check: FAIL")
        for source_name, marker in findings:
            print(f"  - source={source_name}; marker={marker}")
        return False

    print("leakage_sanity_check: PASS")
    print("api_call_performed: false")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate AI-assisted requirements-based MIL candidates."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Inspect the request and leakage checks without calling the API.",
    )
    arguments = parser.parse_args()

    ai_directory = Path(__file__).resolve().parent
    test_basis_path = ai_directory / "01_AI_Test_Basis.md"
    prompt_path = ai_directory / "prompt" / "tc_generation_prompt.txt"
    candidates_path = ai_directory / "output" / "ai_candidates.json"
    metadata_path = ai_directory / "output" / "ai_generation_metadata.json"

    test_basis_text = test_basis_path.read_text(encoding="utf-8")
    prompt_text = prompt_path.read_text(encoding="utf-8")
    output_schema = build_candidate_schema()
    source_texts = build_api_sources(
        test_basis_text, prompt_text, output_schema
    )
    selected_model = os.environ.get("GEMINI_MODEL", "").strip() or DEFAULT_MODEL

    if arguments.dry_run:
        passed = _dry_run_report(
            selected_model,
            test_basis_path,
            prompt_path,
            prompt_text,
            test_basis_text,
            source_texts,
        )
        return 0 if passed else 1

    findings = find_leakage(source_texts)
    if findings:
        details = "; ".join(
            f"{source_name}: {marker}" for source_name, marker in findings
        )
        print(f"Generation blocked by leakage sanity check: {details}", file=sys.stderr)
        return 1

    if not os.environ.get("GEMINI_API_KEY", "").strip():
        print("GEMINI_API_KEY is not set; no API call was made.", file=sys.stderr)
        return 1

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        print(
            "The google-genai Python package is not installed; no API call was made.",
            file=sys.stderr,
        )
        return 1

    try:
        client = genai.Client()
        response = client.models.generate_content(
            model=selected_model,
            contents=test_basis_text,
            config=types.GenerateContentConfig(
                system_instruction=prompt_text,
                response_mime_type="application/json",
                response_json_schema=output_schema,
                thinking_config=types.ThinkingConfig(
                    thinking_level=THINKING_LEVEL
                ),
            ),
        )
    except Exception as error:  # SDK/network/API errors must not touch outputs.
        print(f"Gemini generate_content call failed: {error}", file=sys.stderr)
        return 1

    try:
        parsed_payload = _strict_parse_candidates(response.text)
    except (TypeError, ValueError) as error:
        print(f"Structured response validation failed: {error}", file=sys.stderr)
        return 1

    metadata = {
        "provider": "Google Gemini",
        "model": selected_model,
        "thinking_level": THINKING_LEVEL,
        "candidate_count_requested": CANDIDATE_BUDGET,
        "candidate_count_returned": len(parsed_payload["candidates"]),
        "generation_timestamp": datetime.now(timezone.utc).isoformat(),
        "test_basis_file": str(test_basis_path.relative_to(ai_directory.parent)),
        "prompt_file": str(prompt_path.relative_to(ai_directory.parent)),
        "api_type": "Gemini generate_content",
        "generation_status": "SUCCESS",
    }

    # Files are written only after the API response and strict parsing both
    # succeed. API keys and raw response objects are never persisted.
    _atomic_write_json(candidates_path, parsed_payload)
    _atomic_write_json(metadata_path, metadata)
    print(f"Generated {len(parsed_payload['candidates'])} candidates.")
    print(f"Candidates: {candidates_path}")
    print(f"Metadata: {metadata_path}")
    print("Run python ai/validate_test_cases.py to validate the candidates.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
