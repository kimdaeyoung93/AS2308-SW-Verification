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
import copy
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

GEMINI_RESPONSE_JSON_SCHEMA_KEYWORDS = frozenset(
    {
        "$id",
        "$defs",
        "$ref",
        "$anchor",
        "type",
        "format",
        "title",
        "description",
        "enum",
        "items",
        "prefixItems",
        "minItems",
        "maxItems",
        "minimum",
        "maximum",
        "anyOf",
        "oneOf",
        "properties",
        "additionalProperties",
        "required",
        "propertyOrdering",
    }
)

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


def collect_schema_keywords(schema: dict[str, Any]) -> set[str]:
    """Collect JSON Schema keywords without treating property names as keywords."""

    keywords: set[str] = set()

    def visit(schema_node: dict[str, Any]) -> None:
        for keyword, value in schema_node.items():
            keywords.add(keyword)
            if keyword in {"properties", "$defs"} and isinstance(value, dict):
                for child_schema in value.values():
                    if isinstance(child_schema, dict):
                        visit(child_schema)
            elif keyword in {"items", "additionalProperties"} and isinstance(
                value, dict
            ):
                visit(value)
            elif keyword in {"prefixItems", "anyOf", "oneOf"} and isinstance(
                value, list
            ):
                for child_schema in value:
                    if isinstance(child_schema, dict):
                        visit(child_schema)

    visit(schema)
    return keywords


def build_gemini_compatible_schema(
    canonical_schema: dict[str, Any],
) -> tuple[dict[str, Any], set[str]]:
    """Copy a schema while removing only Gemini-unsupported keywords."""

    removed_keywords: set[str] = set()

    def copy_schema_node(schema_node: dict[str, Any]) -> dict[str, Any]:
        compatible_node: dict[str, Any] = {}
        for keyword, value in schema_node.items():
            if keyword not in GEMINI_RESPONSE_JSON_SCHEMA_KEYWORDS:
                removed_keywords.add(keyword)
                continue

            if keyword in {"properties", "$defs"} and isinstance(value, dict):
                compatible_node[keyword] = {
                    property_name: copy_schema_node(child_schema)
                    if isinstance(child_schema, dict)
                    else copy.deepcopy(child_schema)
                    for property_name, child_schema in value.items()
                }
            elif keyword in {"items", "additionalProperties"} and isinstance(
                value, dict
            ):
                compatible_node[keyword] = copy_schema_node(value)
            elif keyword in {"prefixItems", "anyOf", "oneOf"} and isinstance(
                value, list
            ):
                compatible_node[keyword] = [
                    copy_schema_node(child_schema)
                    if isinstance(child_schema, dict)
                    else copy.deepcopy(child_schema)
                    for child_schema in value
                ]
            else:
                compatible_node[keyword] = copy.deepcopy(value)
        return compatible_node

    return copy_schema_node(canonical_schema), removed_keywords


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


def create_structured_interaction(
    client: Any,
    model: str,
    input_text: str,
    response_schema: dict[str, Any],
    system_instruction: str | None = None,
    max_output_tokens: int | None = None,
    timeout_s: float | None = None,
) -> Any:
    """Create one non-streaming Interactions API request with JSON output."""

    generation_config: dict[str, Any] = {"thinking_level": THINKING_LEVEL}
    if max_output_tokens is not None:
        generation_config["max_output_tokens"] = max_output_tokens

    request: dict[str, Any] = {
        "model": model,
        "input": input_text,
        "generation_config": generation_config,
        "response_format": {
            "type": "text",
            "mime_type": "application/json",
            "schema": response_schema,
        },
        "response_mime_type": "application/json",
        "store": False,
    }
    if system_instruction is not None:
        request["system_instruction"] = system_instruction
    if timeout_s is not None:
        request["timeout"] = timeout_s
    return client.interactions.create(**request)


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
    canonical_schema_keywords: set[str],
    removed_schema_keywords: set[str],
    api_schema_keywords: set[str],
) -> bool:
    # The request consists only of the prompt, Test Basis, and response schema.
    final_input_text = json.dumps(source_texts, ensure_ascii=False, sort_keys=True)
    api_key_present = bool(os.environ.get("GEMINI_API_KEY", "").strip())
    findings = find_leakage(source_texts)

    print("AI-Assisted Test Case Generator V1 - DRY RUN")
    print("provider: Google Gemini")
    print("api_type: Gemini Interactions API")
    print(f"selected_model: {model}")
    print(f"thinking_level: {THINKING_LEVEL}")
    print(f"candidate_budget: {CANDIDATE_BUDGET}")
    print(f"test_basis_path: {test_basis_path}")
    print(f"prompt_path: {prompt_path}")
    print(f"final_api_input_character_count: {len(final_input_text)}")
    print(f"gemini_api_key_present: {str(api_key_present).lower()}")
    print(
        "canonical_schema_keywords: "
        + ", ".join(sorted(canonical_schema_keywords))
    )
    print(
        "removed_unsupported_schema_keywords: "
        + (", ".join(sorted(removed_schema_keywords)) or "(none)")
    )
    print("api_schema_keywords: " + ", ".join(sorted(api_schema_keywords)))
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
        help="Inspect the request and leakage checks without calling the API.",
    )
    mode_group.add_argument(
        "--smoke-test",
        action="store_true",
        help="Call the API with a minimal schema; no candidate files are written.",
    )
    mode_group.add_argument(
        "--dump-api-schema",
        action="store_true",
        help="Print only the Gemini-compatible schema sent to the API.",
    )
    arguments = parser.parse_args()

    ai_directory = Path(__file__).resolve().parent
    test_basis_path = ai_directory / "01_AI_Test_Basis.md"
    prompt_path = ai_directory / "prompt" / "tc_generation_prompt.txt"
    candidates_path = ai_directory / "output" / "ai_candidates.json"
    metadata_path = ai_directory / "output" / "ai_generation_metadata.json"

    test_basis_text = test_basis_path.read_text(encoding="utf-8")
    prompt_text = prompt_path.read_text(encoding="utf-8")
    canonical_output_schema = build_candidate_schema()
    output_schema, removed_schema_keywords = build_gemini_compatible_schema(
        canonical_output_schema
    )
    canonical_schema_keywords = collect_schema_keywords(canonical_output_schema)
    api_schema_keywords = collect_schema_keywords(output_schema)
    source_texts = build_api_sources(
        test_basis_text, prompt_text, output_schema
    )
    selected_model = os.environ.get("GEMINI_MODEL", "").strip() or DEFAULT_MODEL

    if arguments.dump_api_schema:
        print(json.dumps(output_schema, indent=2, ensure_ascii=False))
        return 0

    if arguments.dry_run:
        passed = _dry_run_report(
            selected_model,
            test_basis_path,
            prompt_path,
            prompt_text,
            test_basis_text,
            source_texts,
            canonical_schema_keywords,
            removed_schema_keywords,
            api_schema_keywords,
        )
        return 0 if passed else 1

    if arguments.smoke_test:
        if not os.environ.get("GEMINI_API_KEY", "").strip():
            print(
                "GEMINI_API_KEY is not set; the smoke test was not called.",
                file=sys.stderr,
            )
            return 1

        try:
            from google import genai
        except ImportError:
            print(
                "The google-genai Python package is not installed; "
                "the smoke test was not called.",
                file=sys.stderr,
            )
            return 1

        smoke_schema = {
            "type": "object",
            "properties": {"status": {"type": "string"}},
            "required": ["status"],
            "additionalProperties": False,
        }
        try:
            with genai.Client() as client:
                interaction = create_structured_interaction(
                    client,
                    selected_model,
                    "Return status as API_OK",
                    smoke_schema,
                )
        except Exception as error:
            print(f"Interactions API smoke test failed: {error}", file=sys.stderr)
            return 1

        if getattr(interaction, "status", None) != "completed":
            print(
                "Interactions API smoke test did not complete successfully: "
                f"{getattr(interaction, 'status', None)}",
                file=sys.stderr,
            )
            return 1
        output_text = getattr(interaction, "output_text", None)
        if not isinstance(output_text, str) or not output_text.strip():
            print(
                "Interactions API smoke test returned no output_text.",
                file=sys.stderr,
            )
            return 1
        try:
            smoke_payload = json.loads(output_text)
        except json.JSONDecodeError as error:
            print(f"Smoke test output is not valid JSON: {error}", file=sys.stderr)
            return 1
        if smoke_payload != {"status": "API_OK"}:
            print(
                f"Unexpected smoke test output: {smoke_payload}",
                file=sys.stderr,
            )
            return 1

        print("Interactions API Structured Output smoke test: PASS")
        print(f"model: {selected_model}")
        print(f"thinking_level: {THINKING_LEVEL}")
        print(f"output_text: {output_text}")
        print("official_generation_performed: false")
        return 0

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
    except ImportError:
        print(
            "The google-genai Python package is not installed; no API call was made.",
            file=sys.stderr,
        )
        return 1

    try:
        with genai.Client() as client:
            interaction = create_structured_interaction(
                client,
                selected_model,
                test_basis_text,
                output_schema,
                system_instruction=prompt_text,
            )
    except Exception as error:  # SDK/network/API errors must not touch outputs.
        print(f"Gemini Interactions API call failed: {error}", file=sys.stderr)
        return 1

    if getattr(interaction, "status", None) != "completed":
        print(
            "Interaction did not complete successfully: "
            f"{getattr(interaction, 'status', None)}",
            file=sys.stderr,
        )
        return 1
    output_text = getattr(interaction, "output_text", None)
    if not isinstance(output_text, str) or not output_text.strip():
        print("Interaction returned no output_text.", file=sys.stderr)
        return 1

    try:
        parsed_payload = _strict_parse_candidates(output_text)
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
        "api_type": "Gemini Interactions API",
        "interaction_id": getattr(interaction, "id", None),
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
