"""Diagnose Gemini Interactions API JSON-schema compatibility stage by stage.

This script does not read the AI Test Basis or generation prompt, does not
generate official test cases, and does not write candidate or metadata files.
Each schema stage is sent exactly once with SDK transport retries disabled.
"""

from __future__ import annotations

import copy
import os
import sys
from typing import Any

from generate_test_cases import (
    DEFAULT_MODEL,
    THINKING_LEVEL,
    build_candidate_schema,
    build_gemini_compatible_schema,
    create_structured_interaction,
)
from tc_schema import (
    ALLOWED_REQUIREMENT_IDS,
    ALLOWED_TEST_DESIGN_TECHNIQUES,
    ALLOWED_TEST_SCOPES,
)


STRING_FIELDS = [
    "candidate_id",
    "requirement_id",
    "test_objective",
    "precondition",
    "input_type",
    "expected_behavior",
    "test_design_technique",
    "rationale",
    "test_scope",
]


def _candidate_array_schema(candidate_schema: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "candidates": {
                "type": "array",
                "items": candidate_schema,
            }
        },
        "required": ["candidates"],
        "additionalProperties": False,
    }


def build_schema_stages() -> list[tuple[str, dict[str, Any]]]:
    """Build cumulative S0-S10 schemas without changing production schema."""

    stages: list[tuple[str, dict[str, Any]]] = []

    s0 = {
        "type": "object",
        "properties": {"status": {"type": "string"}},
        "required": ["status"],
        "additionalProperties": False,
    }
    stages.append(("S0", s0))

    s1 = _candidate_array_schema(
        {
            "type": "object",
            "properties": {"candidate_id": {"type": "string"}},
        }
    )
    stages.append(("S1", s1))

    s2 = copy.deepcopy(s1)
    s2_candidates = s2["properties"]["candidates"]
    s2_candidates["minItems"] = 25
    s2_candidates["maxItems"] = 25
    stages.append(("S2", s2))

    s3 = copy.deepcopy(s2)
    s3_item = s3["properties"]["candidates"]["items"]
    s3_item["properties"] = {
        field_name: {"type": "string"} for field_name in STRING_FIELDS
    }
    stages.append(("S3", s3))

    s4 = copy.deepcopy(s3)
    s4_item = s4["properties"]["candidates"]["items"]
    s4_item["required"] = list(STRING_FIELDS)
    stages.append(("S4", s4))

    s5 = copy.deepcopy(s4)
    s5_item = s5["properties"]["candidates"]["items"]
    s5_item["additionalProperties"] = False
    stages.append(("S5", s5))

    s6 = copy.deepcopy(s5)
    s6_properties = s6["properties"]["candidates"]["items"]["properties"]
    s6_properties["requirement_id"]["enum"] = sorted(ALLOWED_REQUIREMENT_IDS)
    stages.append(("S6", s6))

    s7 = copy.deepcopy(s6)
    s7_properties = s7["properties"]["candidates"]["items"]["properties"]
    s7_properties["test_design_technique"]["enum"] = sorted(
        ALLOWED_TEST_DESIGN_TECHNIQUES
    )
    stages.append(("S7", s7))

    s8 = copy.deepcopy(s7)
    s8_properties = s8["properties"]["candidates"]["items"]["properties"]
    s8_properties["test_scope"]["enum"] = sorted(ALLOWED_TEST_SCOPES)
    stages.append(("S8", s8))

    s9 = copy.deepcopy(s8)
    s9_item = s9["properties"]["candidates"]["items"]
    input_values_schema = {
        "type": "array",
        "items": {"type": "number"},
        "minItems": 1,
    }
    ordered_properties: dict[str, Any] = {}
    for field_name, field_schema in s9_item["properties"].items():
        ordered_properties[field_name] = field_schema
        if field_name == "input_type":
            ordered_properties["input_values"] = input_values_schema
    s9_item["properties"] = ordered_properties
    input_type_index = s9_item["required"].index("input_type")
    s9_item["required"].insert(input_type_index + 1, "input_values")
    stages.append(("S9", s9))

    canonical_schema = build_candidate_schema()
    production_api_schema, _ = build_gemini_compatible_schema(canonical_schema)
    stages.append(("S10", production_api_schema))
    return stages


def _http_status_from_error(error: Exception) -> str:
    status_code = getattr(error, "status_code", None)
    if status_code is None:
        response = getattr(error, "response", None)
        status_code = getattr(response, "status_code", None)
    if status_code is None:
        status_code = getattr(error, "code", None)
    return str(status_code) if status_code is not None else "N/A"


def _safe_error_message(error: Exception, api_key: str) -> str:
    message = " ".join(str(error).splitlines())
    if api_key:
        message = message.replace(api_key, "[REDACTED]")
    return message


def main() -> int:
    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key:
        print("GEMINI_API_KEY is not set; no schema API tests were called.", file=sys.stderr)
        return 1

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        print("The google-genai Python package is not installed.", file=sys.stderr)
        return 1

    selected_model = os.environ.get("GEMINI_MODEL", "").strip() or DEFAULT_MODEL
    stages = build_schema_stages()
    prompt = (
        "Return the smallest valid JSON value matching the response schema. "
        "Use short placeholder strings and the first allowed enum value."
    )

    print(f"model={selected_model}")
    print(f"thinking_level={THINKING_LEVEL}")
    print("max_output_tokens=32")
    print("request_timeout_s=30")
    print("official_generation_performed=false")
    print("Stage\tResult\tHTTPStatus\tError")

    all_passed = True
    http_options = types.HttpOptions(
        retry_options=types.HttpRetryOptions(attempts=1)
    )
    with genai.Client(http_options=http_options) as client:
        for stage_name, schema in stages:
            try:
                interaction = create_structured_interaction(
                    client,
                    selected_model,
                    prompt,
                    schema,
                    max_output_tokens=32,
                    timeout_s=30,
                )
                status = getattr(interaction, "status", None)
                # Any HTTP 200 response proves the server accepted the schema.
                # The intentionally small output cap may produce an incomplete
                # interaction, which is acceptable for this compatibility test.
                print(
                    f"{stage_name}\tPASS\t200\t"
                    f"schema accepted; interaction_status={status}"
                )
            except Exception as error:
                all_passed = False
                http_status = _http_status_from_error(error)
                message = _safe_error_message(error, api_key)
                print(f"{stage_name}\tFAIL\t{http_status}\t{message}")

    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
