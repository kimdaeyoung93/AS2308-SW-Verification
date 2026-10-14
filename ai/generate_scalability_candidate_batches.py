"""Generate frozen-protocol scalability candidate batches.

This script never reads Manual, Mutation-result, Coverage, or SIL-result data.
Use --dry-run to validate the request inputs without calling the API.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from generate_test_cases import (
    CANDIDATE_BUDGET,
    DEFAULT_MODEL,
    OUTPUT_SCHEMA_NAME,
    REASONING_EFFORT,
    _create_response,
    _response_usage,
    _strict_parse_candidates,
    build_api_sources,
    build_candidate_schema,
    find_leakage,
    validate_openai_strict_schema,
)


ROOT = Path(__file__).resolve().parents[1]
AI_DIR = ROOT / "ai"
RESULT_ROOT = ROOT / "results" / "scalability_extension_v1"
BATCH_DIR = RESULT_ROOT / "candidate_batches"
TEST_BASIS_PATH = AI_DIR / "01_AI_Test_Basis.md"
PROMPT_PATH = AI_DIR / "prompt" / "tc_generation_prompt.txt"
V1_METADATA_PATH = AI_DIR / "output" / "ai_generation_metadata.json"
PROTOCOL_PATH = ROOT / "docs" / "07_AI_Verification_Scalability_Protocol.md"
SCHEMA_PATH = AI_DIR / "tc_schema.py"
V1_GENERATOR_PATH = AI_DIR / "generate_test_cases.py"
POOL_SUMMARY_PATH = RESULT_ROOT / "candidate_validation_summary.csv"

BASE_BATCH_IDS = tuple(f"B{index:02d}" for index in range(1, 6))
FALLBACK_BATCH_ID = "B06"
CAPACITY_BATCH_ID = "B07"
ALLOWED_BATCH_IDS = (*BASE_BATCH_IDS, FALLBACK_BATCH_ID, CAPACITY_BATCH_ID)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def git_identity() -> tuple[str, str]:
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return commit, branch


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
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
        ) as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False, allow_nan=False)
            handle.write("\n")
            temporary_path = Path(handle.name)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def batch_paths(batch_id: str) -> tuple[Path, Path]:
    if batch_id not in ALLOWED_BATCH_IDS:
        raise ValueError(f"Unsupported batch ID: {batch_id}")
    number = int(batch_id[1:])
    return (
        BATCH_DIR / f"batch_{number:02d}_raw.json",
        BATCH_DIR / f"batch_{number:02d}_metadata.json",
    )


def load_v1_configuration() -> dict[str, Any]:
    metadata = json.loads(V1_METADATA_PATH.read_text(encoding="utf-8"))
    required = {
        "provider": "OpenAI",
        "api_type": "Responses API",
        "reasoning_effort": REASONING_EFFORT,
        "candidate_count_requested": CANDIDATE_BUDGET,
    }
    for key, expected in required.items():
        if metadata.get(key) != expected:
            raise ValueError(
                f"V1 generation metadata mismatch for {key}: "
                f"expected {expected!r}, found {metadata.get(key)!r}"
            )
    model = str(metadata.get("model", "")).strip()
    if not model or model != DEFAULT_MODEL:
        raise ValueError(
            "V1 model metadata does not match generate_test_cases.py default model"
        )
    environment_model = os.environ.get("OPENAI_MODEL", "").strip()
    if environment_model and environment_model != model:
        raise ValueError(
            "OPENAI_MODEL must match the frozen V1 generation model "
            f"({model}) for this extension"
        )
    return metadata


def prepare_request() -> dict[str, Any]:
    required_paths = (
        TEST_BASIS_PATH,
        PROMPT_PATH,
        V1_METADATA_PATH,
        PROTOCOL_PATH,
        SCHEMA_PATH,
        V1_GENERATOR_PATH,
    )
    for path in required_paths:
        if not path.is_file():
            raise FileNotFoundError(f"Required generation input not found: {path}")

    v1_metadata = load_v1_configuration()
    test_basis = TEST_BASIS_PATH.read_text(encoding="utf-8")
    prompt = PROMPT_PATH.read_text(encoding="utf-8")
    schema = build_candidate_schema()
    validate_openai_strict_schema(schema)
    sources = build_api_sources(test_basis, prompt, schema)
    leakage = find_leakage(sources)
    if leakage:
        detail = "; ".join(f"{source}: {marker}" for source, marker in leakage)
        raise ValueError(f"Leakage sanity check failed: {detail}")

    return {
        "model": v1_metadata["model"],
        "provider": v1_metadata["provider"],
        "api_type": v1_metadata["api_type"],
        "reasoning_effort": v1_metadata["reasoning_effort"],
        "test_basis": test_basis,
        "prompt": prompt,
        "schema": schema,
        "source_hashes": {
            str(path.relative_to(ROOT)): sha256_file(path) for path in required_paths
        },
    }


def read_pool_summary() -> dict[str, str]:
    if not POOL_SUMMARY_PATH.is_file():
        raise FileNotFoundError(
            "Capacity generation requires candidate_validation_summary.csv"
        )
    import csv

    with POOL_SUMMARY_PATH.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 1:
        raise ValueError("candidate_validation_summary.csv must contain one row")
    return rows[0]


def read_fallback_eligibility() -> tuple[int, bool]:
    row = read_pool_summary()
    try:
        count = int(row["eligible_unique_executable_count"])
    except (KeyError, ValueError) as error:
        raise ValueError("Pool summary has no valid eligible count") from error
    allowed = row.get("fallback_b06_allowed", "").strip().lower() == "true"
    return count, allowed


def assert_base_batches_complete() -> None:
    missing = [
        batch_id
        for batch_id in BASE_BATCH_IDS
        if not all(path.is_file() for path in batch_paths(batch_id))
    ]
    if missing:
        raise ValueError("B06 is blocked; missing completed base batches: " + ", ".join(missing))


def assert_batches_complete(batch_ids: tuple[str, ...], action: str) -> None:
    missing = [
        batch_id
        for batch_id in batch_ids
        if not all(path.is_file() for path in batch_paths(batch_id))
    ]
    if missing:
        raise ValueError(f"{action} is blocked; missing raw/metadata: " + ", ".join(missing))


def assert_verification_not_started() -> None:
    fixed = (
        "healthy_execution_results.csv",
        "healthy_segment_results.csv",
        "mutation_execution_results.csv",
        "mutation_kill_matrix.csv",
        "runtime_summary.csv",
        "metadata.txt",
    )
    evidence = [RESULT_ROOT / name for name in fixed if (RESULT_ROOT / name).exists()]
    evidence.extend(RESULT_ROOT.glob("healthy_*_incomplete_*.csv"))
    evidence.extend(RESULT_ROOT.glob("mutation_*_incomplete_*.csv"))
    if evidence:
        names = ", ".join(sorted(path.name for path in evidence))
        raise ValueError(
            "B07 is blocked because Healthy/Mutation execution evidence exists: " + names
        )


def assert_b07_eligibility() -> int:
    assert_batches_complete((*BASE_BATCH_IDS, FALLBACK_BATCH_ID), "B07")
    raw_path, metadata_path = batch_paths(CAPACITY_BATCH_ID)
    if raw_path.exists() or metadata_path.exists():
        raise FileExistsError("Refusing to overwrite existing batch artifacts for B07")
    row = read_pool_summary()
    expected_ids = ",".join((*BASE_BATCH_IDS, FALLBACK_BATCH_ID))
    if row.get("batch_ids", "").replace(" ", "") != expected_ids:
        raise ValueError("B07 requires a pool summary built from exactly B01-B06")
    if row.get("batch_count", "").strip() != "6":
        raise ValueError("B07 requires batch_count=6 in candidate_validation_summary.csv")
    try:
        eligible_count = int(row["eligible_unique_executable_count"])
    except (KeyError, ValueError) as error:
        raise ValueError("Pool summary has no valid eligible count") from error
    if eligible_count >= 100:
        raise ValueError("B07 is blocked because B01-B06 already meet the 100-case target")
    if row.get("status", "").strip() not in {"POOL_TARGET_NOT_MET", "B07_REQUIRED"}:
        raise ValueError("B07 requires the B01-B06 pool to be in a capacity-shortfall state")
    assert_verification_not_started()
    return eligible_count


def generate_batch(batch_id: str, request: dict[str, Any]) -> None:
    raw_path, metadata_path = batch_paths(batch_id)
    if raw_path.exists() or metadata_path.exists():
        raise FileExistsError(
            f"Refusing to overwrite existing batch artifacts for {batch_id}"
        )
    if not os.environ.get("OPENAI_API_KEY", "").strip():
        raise RuntimeError("OPENAI_API_KEY is not set; no API call was made")

    try:
        from openai import OpenAI
    except ImportError as error:
        raise RuntimeError("The openai Python package is not installed") from error

    with OpenAI(max_retries=0) as client:
        response = _create_response(
            client,
            request["model"],
            request["prompt"],
            request["test_basis"],
            request["schema"],
            f"{OUTPUT_SCHEMA_NAME}_{batch_id.lower()}",
        )

    if getattr(response, "status", None) != "completed":
        raise RuntimeError(
            f"{batch_id} response did not complete: {getattr(response, 'status', None)}"
        )
    output_text = getattr(response, "output_text", None)
    if not isinstance(output_text, str) or not output_text.strip():
        raise RuntimeError(f"{batch_id} response returned no output_text")
    parsed = _strict_parse_candidates(output_text)
    usage = _response_usage(response)
    generated_at = datetime.now(timezone.utc).isoformat()
    git_commit, git_branch = git_identity()

    raw_payload = {
        "batch_id": batch_id,
        "candidate_count": len(parsed["candidates"]),
        "candidates": [
            {"original_candidate_id": row["candidate_id"], **row}
            for row in parsed["candidates"]
        ],
    }
    metadata_payload = {
        "batch_id": batch_id,
        "provider": request["provider"],
        "model": request["model"],
        "reasoning_effort": request["reasoning_effort"],
        "api_type": request["api_type"],
        "candidate_count_requested": CANDIDATE_BUDGET,
        "candidate_count_returned": len(parsed["candidates"]),
        "response_id": getattr(response, "id", None),
        "usage_input_tokens": usage["input_tokens"],
        "usage_output_tokens": usage["output_tokens"],
        "usage_reasoning_tokens": usage["reasoning_tokens"],
        "generation_timestamp": generated_at,
        "git_commit": git_commit,
        "git_branch": git_branch,
        "source_hashes": request["source_hashes"],
        "generation_status": "SUCCESS",
    }
    atomic_write_json(raw_path, raw_payload)
    atomic_write_json(metadata_path, metadata_payload)
    print(f"{batch_id}: generated {len(parsed['candidates'])} candidates")
    print(f"  raw: {raw_path}")
    print(f"  metadata: {metadata_path}")


def dry_run(request: dict[str, Any]) -> None:
    print("Scalability candidate batch generator - DRY RUN")
    print(f"provider/model: {request['provider']} / {request['model']}")
    print(f"reasoning effort: {request['reasoning_effort']}")
    print(f"candidates per batch: {CANDIDATE_BUDGET}")
    print(f"base batches: {', '.join(BASE_BATCH_IDS)}")
    print("fallback: B06 only when eligible unique executable count < 100")
    print("one-time capacity extension: B07 after B01-B06 remain below 100")
    print("B08 or later: prohibited")
    print(f"test basis: {TEST_BASIS_PATH}")
    print(f"prompt: {PROMPT_PATH}")
    print(f"output directory: {BATCH_DIR}")
    print("strict schema validation: PASS")
    print("leakage sanity check: PASS")
    print("API call performed: false")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--dry-run", action="store_true")
    actions.add_argument("--generate-base", action="store_true")
    actions.add_argument("--generate-fallback-b06", action="store_true")
    actions.add_argument("--generate-capacity-b07", action="store_true")
    args = parser.parse_args()

    try:
        request = prepare_request()
        if args.dry_run:
            dry_run(request)
            return 0
        if args.generate_base:
            for batch_id in BASE_BATCH_IDS:
                generate_batch(batch_id, request)
            return 0

        if args.generate_fallback_b06:
            assert_base_batches_complete()
            eligible_count, fallback_allowed = read_fallback_eligibility()
            if eligible_count >= 100 or not fallback_allowed:
                raise ValueError(
                    "B06 is allowed only after B01-B05 when eligible count is below 100"
                )
            generate_batch(FALLBACK_BATCH_ID, request)
            return 0

        eligible_count = assert_b07_eligibility()
        print(f"B07 capacity gate: B01-B06 eligible count={eligible_count} < 100")
        generate_batch(CAPACITY_BATCH_ID, request)
        return 0
    except Exception as error:
        print(f"ERROR: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
