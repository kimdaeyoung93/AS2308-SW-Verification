"""Generate AI-assisted requirements-based MIL test case candidates.

Dry run (no API call):
    python ai/generate_test_cases.py --dry-run

Structured-output smoke test:
    python ai/generate_test_cases.py --smoke-test

Official generation:
    python ai/generate_test_cases.py

Only the AI Test Basis, generation prompt, and schema defined from
tc_schema.py are sent to the OpenAI Responses API. Generation does not use
Manual Test Cases, mutation data, coverage data, or test-result data.
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
from validate_test_cases import validate_candidates


DEFAULT_MODEL = "gpt-5.6-luna"
REASONING_EFFORT = "medium"
CANDIDATE_BUDGET = 25
OUTPUT_SCHEMA_NAME = "as2308_mil_test_candidates"

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
    """Build the canonical strict JSON Schema from the local TC schema."""

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
    required_fields = [*TestCaseCandidate.REQUIRED_FIELDS, "test_scope"]
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


def validate_openai_strict_schema(schema: dict[str, Any]) -> None:
    """Check object requirements needed by OpenAI strict Structured Outputs."""

    if schema.get("type") != "object":
        raise ValueError("Structured Output root schema must have type=object")

    def visit(node: dict[str, Any], location: str) -> None:
        if node.get("type") == "object":
            properties = node.get("properties")
            if not isinstance(properties, dict):
                raise ValueError(f"{location} object must define properties")
            if node.get("additionalProperties") is not False:
                raise ValueError(
                    f"{location} object must set additionalProperties=false"
                )
            required = node.get("required")
            if not isinstance(required, list) or set(required) != set(properties):
                raise ValueError(
                    f"{location} must require every property for strict output"
                )
            for property_name, child in properties.items():
                if isinstance(child, dict):
                    visit(child, f"{location}.properties.{property_name}")

        items = node.get("items")
        if isinstance(items, dict):
            visit(items, f"{location}.items")
        for union_keyword in ("anyOf", "oneOf"):
            alternatives = node.get(union_keyword)
            if isinstance(alternatives, list):
                for index, child in enumerate(alternatives):
                    if isinstance(child, dict):
                        visit(child, f"{location}.{union_keyword}[{index}]")

    visit(schema, "root")
    candidates = schema.get("properties", {}).get("candidates")
    if isinstance(candidates, dict):
        if candidates.get("minItems") != CANDIDATE_BUDGET:
            raise ValueError("candidates minItems must equal the candidate budget")
        if candidates.get("maxItems") != CANDIDATE_BUDGET:
            raise ValueError("candidates maxItems must equal the candidate budget")


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

    expected_fields = {*TestCaseCandidate.REQUIRED_FIELDS, "test_scope"}
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


def _response_usage(response: Any) -> dict[str, int | None]:
    usage = getattr(response, "usage", None)
    output_details = getattr(usage, "output_tokens_details", None)
    return {
        "input_tokens": getattr(usage, "input_tokens", None),
        "output_tokens": getattr(usage, "output_tokens", None),
        "reasoning_tokens": getattr(output_details, "reasoning_tokens", None),
    }


def _create_response(
    client: Any,
    model: str,
    instructions: str,
    input_text: str,
    output_schema: dict[str, Any],
    schema_name: str,
) -> Any:
    return client.responses.create(
        model=model,
        reasoning={"effort": REASONING_EFFORT},
        instructions=instructions,
        input=input_text,
        text={
            "format": {
                "type": "json_schema",
                "name": schema_name,
                "strict": True,
                "schema": output_schema,
            }
        },
        store=False,
    )


def _dry_run_report(
    model: str,
    test_basis_path: Path,
    prompt_path: Path,
    source_texts: dict[str, str],
) -> bool:
    final_input_text = json.dumps(source_texts, ensure_ascii=False, sort_keys=True)
    api_key_present = bool(os.environ.get("OPENAI_API_KEY", "").strip())
    findings = find_leakage(source_texts)

    print("AI-Assisted Test Case Generator V1 - DRY RUN")
    print("provider: OpenAI")
    print("api_type: Responses API")
    print(f"selected_model: {model}")
    print(f"reasoning_effort: {REASONING_EFFORT}")
    print(f"candidate_budget: {CANDIDATE_BUDGET}")
    print(f"test_basis_path: {test_basis_path}")
    print(f"prompt_path: {prompt_path}")
    print(f"final_api_input_character_count: {len(final_input_text)}")
    print(f"openai_api_key_present: {str(api_key_present).lower()}")
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
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--dry-run",
        action="store_true",
        help="Inspect request sources and leakage checks without calling the API.",
    )
    mode_group.add_argument(
        "--smoke-test",
        action="store_true",
        help="Call the API with a minimal strict schema; no files are written.",
    )
    mode_group.add_argument(
        "--dump-api-schema",
        action="store_true",
        help="Print only the strict JSON Schema sent to the API.",
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
    validate_openai_strict_schema(output_schema)
    source_texts = build_api_sources(test_basis_text, prompt_text, output_schema)
    selected_model = os.environ.get("OPENAI_MODEL", "").strip() or DEFAULT_MODEL

    if arguments.dump_api_schema:
        print(json.dumps(output_schema, indent=2, ensure_ascii=False))
        return 0

    if arguments.dry_run:
        passed = _dry_run_report(
            selected_model,
            test_basis_path,
            prompt_path,
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

    if not os.environ.get("OPENAI_API_KEY", "").strip():
        print("OPENAI_API_KEY is not set; no API call was made.", file=sys.stderr)
        return 1

    try:
        from openai import OpenAI
    except ImportError:
        print(
            "The openai Python package is not installed; no API call was made.",
            file=sys.stderr,
        )
        return 1

    if arguments.smoke_test:
        smoke_schema = {
            "type": "object",
            "properties": {"status": {"type": "string", "enum": ["API_OK"]}},
            "required": ["status"],
            "additionalProperties": False,
        }
        validate_openai_strict_schema(smoke_schema)
        try:
            with OpenAI(max_retries=0) as client:
                response = _create_response(
                    client,
                    selected_model,
                    "Return the requested API connectivity status as JSON.",
                    "Return status as API_OK.",
                    smoke_schema,
                    "as2308_api_smoke_test",
                )
        except Exception as error:
            print(f"Responses API smoke test failed: {error}", file=sys.stderr)
            return 1

        if getattr(response, "status", None) != "completed":
            print(
                "Responses API smoke test did not complete successfully: "
                f"{getattr(response, 'status', None)}",
                file=sys.stderr,
            )
            return 1
        output_text = getattr(response, "output_text", None)
        if not isinstance(output_text, str) or not output_text.strip():
            print("Responses API smoke test returned no output_text.", file=sys.stderr)
            return 1
        try:
            smoke_payload = json.loads(output_text)
        except json.JSONDecodeError as error:
            print(f"Smoke test output is not valid JSON: {error}", file=sys.stderr)
            return 1
        if smoke_payload != {"status": "API_OK"}:
            print(f"Unexpected smoke test output: {smoke_payload}", file=sys.stderr)
            return 1

        print("OpenAI Responses API Structured Output smoke test: PASS")
        print(f"model: {selected_model}")
        print(f"reasoning_effort: {REASONING_EFFORT}")
        print(f"output_text: {output_text}")
        print("official_generation_performed: false")
        return 0

    try:
        with OpenAI(max_retries=0) as client:
            response = _create_response(
                client,
                selected_model,
                prompt_text,
                test_basis_text,
                output_schema,
                OUTPUT_SCHEMA_NAME,
            )
    except Exception as error:  # API/network errors must not touch output files.
        print(f"OpenAI Responses API call failed: {error}", file=sys.stderr)
        return 1

    if getattr(response, "status", None) != "completed":
        print(
            "Response did not complete successfully: "
            f"{getattr(response, 'status', None)}",
            file=sys.stderr,
        )
        return 1
    output_text = getattr(response, "output_text", None)
    if not isinstance(output_text, str) or not output_text.strip():
        print("Response returned no output_text.", file=sys.stderr)
        return 1

    try:
        parsed_payload = _strict_parse_candidates(output_text)
    except (KeyError, TypeError, ValueError) as error:
        print(f"Structured response validation failed: {error}", file=sys.stderr)
        return 1

    validation_records = validate_candidates(parsed_payload["candidates"])
    semantic_valid_count = sum(
        record.status == "VALID" for record in validation_records
    )
    semantic_rejected_count = len(validation_records) - semantic_valid_count
    usage = _response_usage(response)
    metadata = {
        "provider": "OpenAI",
        "model": selected_model,
        "reasoning_effort": REASONING_EFFORT,
        "api_type": "Responses API",
        "candidate_count_requested": CANDIDATE_BUDGET,
        "candidate_count_returned": len(parsed_payload["candidates"]),
        "semantic_valid_count": semantic_valid_count,
        "semantic_rejected_count": semantic_rejected_count,
        "response_id": getattr(response, "id", None),
        "usage_input_tokens": usage["input_tokens"],
        "usage_output_tokens": usage["output_tokens"],
        "usage_reasoning_tokens": usage["reasoning_tokens"],
        "generation_timestamp": datetime.now(timezone.utc).isoformat(),
        "test_basis_file": str(test_basis_path.relative_to(ai_directory.parent)),
        "prompt_file": str(prompt_path.relative_to(ai_directory.parent)),
        "generation_status": "SUCCESS",
    }

    # Files are written only after one API response completes and passes all
    # structural checks. Semantic rejections are recorded without regeneration.
    _atomic_write_json(candidates_path, parsed_payload)
    _atomic_write_json(metadata_path, metadata)
    print(f"Generated {len(parsed_payload['candidates'])} candidates.")
    print(
        "Semantic validation: "
        f"{semantic_valid_count} VALID, {semantic_rejected_count} REJECTED"
    )
    print(f"Candidates: {candidates_path}")
    print(f"Metadata: {metadata_path}")
    print("Run python ai/validate_test_cases.py to write validation CSV files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
