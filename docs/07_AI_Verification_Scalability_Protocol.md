# AS2308 AI-Assisted Verification Scalability Extension Protocol v1.1

| 항목 | 내용 |
|---|---|
| 문서 상태 | v1.1 Amended — One-Time B07 Capacity Extension |
| 기준 branch | `feature/scalability-extension` |
| Extension result root | `results/scalability_extension_v1/` |
| V1 authoritative baseline | 변경하지 않음 |

## 1. 목적과 V1 실험과의 분리

본 extension은 AI-assisted requirements-based MIL Test Case의 수를 늘렸을 때 candidate 처리, deterministic execution, Mutation Testing 및 결과 집계가 어느 규모까지 재현 가능하게 자동화되는지 분석한다. 또한 동일한 frozen ordered pool의 prefix를 이용해 Test Budget 증가에 따른 현재 frozen 6개 결함 기준 검출 효과와 runtime 변화를 측정한다.

이 실험은 다음 V1 controlled comparison을 대체하지 않는다.

- V1: Manual 9 executions 대 Official AI 9 executions
- V1 목적: 동일한 Test Budget에서 두 frozen Suite의 Test Design effectiveness 비교
- V1 authoritative result: 기존 corrected/frozen evidence를 그대로 유지

Scalability Extension v1은 Manual Suite와의 공정 비교 실험이 아니다. Extension 결과를 V1 결과와 합산하거나, V1 Mutation Score·kill matrix·결론을 재해석하거나 덮어쓰지 않는다.

## 2. Source of Truth와 Frozen Variables

Extension 구현과 실행은 다음 V1 semantics를 source of truth로 재사용한다.

- `requirements/01_Requirements.md`
- `docs/03_Mutation_Adjudication_Protocol.md`
- `ai/01_AI_Test_Basis.md`
- `ai/03_AI_Test_Execution_Protocol.md`
- 기존 deterministic Oracle 구현
- `mutations/01_Mutation_Set.csv`

Extension 1에서 다음 항목을 freeze한다.

| Frozen variable | Extension 1 rule |
|---|---|
| DUT | `AS2308_MIL_Baseline_v3/PI Speed Controller` |
| MIL model and plant | V1 authoritative baseline과 identified plant 유지 |
| Requirements | Requirements v1.1 유지 |
| Oracle | 기존 Voltage, Tracking, Direction 및 Direction + Tracking 조합 유지 |
| Mutation 판정 | `Healthy PASS -> Mutant FAIL = KILL` 및 Protocol v1.0 semantics 유지 |
| Mutation Set | Primary Mutation Set `MUT-001`~`MUT-006`, 6개 유지 |
| Healthy applicability | healthy baseline에서 Tracking applicability를 결정하고 mutation phase에서 재계산하지 않음 |
| Reversal semantics | pre-reversal setup과 post-reversal outcome 의미 유지 |
| Numerical environment | 현재 frozen MIL numerical environment 유지 |
| Execution adapter | segment hold `2.0 s`, terminal evaluation window `0.05 s` 유지 |

Plant는 mutate하지 않는다. Mutation Set 확대는 본 실험 결과를 본 뒤 사후 추가하지 않으며, 별도 protocol과 별도 experiment로 분리한다.

## 3. Candidate Generation Plan

### 3.1 Batch target

- 기본 Batch count: 5 (`B01`~`B05`)
- Candidates requested per batch: 25
- 기본 raw target: 125 candidates
- 사전 승인 fallback: `B06` 1회, 25 candidates
- one-time capacity extension: `B07` 1회, 25 candidates
- Maximum raw candidates: 175
- Frozen pool target: 100 schema-valid, semantic-valid, executable, unique Test Cases

현재 `ai/generate_test_cases.py`의 strict Structured Output schema는 한 API response당 정확히 25개 candidate를 요구한다. Extension은 이 V1 schema 의미를 바꾸지 않고 batch-specific output을 보존하는 별도 orchestrator를 사용한다. 각 batch에는 `batch_id`, API response provenance 및 `original_candidate_id`를 기록하고, 전역 식별자는 deterministic하게 부여한다.

### 3.2 125-to-100 capacity fallback 및 one-time extension rule

125 raw candidates는 validation rejection과 cross-batch duplicate를 위한 attrition allowance를 제공하지만 100 unique candidates를 보장하지 않는다. 최초 `B01`~`B05`의 validation, deduplication 및 executable resolution 결과가 100개 미만일 때만 사전에 승인된 예비 batch `B06`을 정확히 1회 추가 생성한다.

`B06` 실행 여부는 오직 eligible unique executable candidate count가 100 미만인지로 결정한다. Mutation, Coverage, SIL, Manual 결과 또는 예상 검출 효과는 이 결정에 사용하지 않는다. **B06는 사후 결과 조정이 아니라 Protocol에서 사전에 정의한 capacity fallback이다.**

실제 `B01`~`B06` 처리 결과는 raw candidates 150개, schema/semantic valid 147개, duplicates 52개, eligible unique executable candidates 95개였다. 이 결과는 Healthy MIL 및 Mutation execution을 시작하기 전에 확인되었다. Frozen target 100개를 유지하기 위한 protocol amendment로 `B07`을 one-time capacity extension 25 candidates로 정확히 1회 허용한다. 이는 Mutation, Coverage, Healthy 또는 기타 검증 결과를 개선하기 위한 regeneration이 아니다.

`B07`은 다음 조건을 모두 만족할 때만 사용할 수 있다.

1. `B01`~`B06` raw 및 metadata artifact가 모두 정상 존재한다.
2. `B01`~`B06`에 기존 validation, deduplication 및 executable resolution을 적용한 eligible unique executable candidate count가 100개 미만이다.
3. Healthy MIL 및 Mutation execution이 아직 시작되지 않았다.

`B07` 처리 후에도 eligible candidate가 100개 미만이면 `POOL_TARGET_NOT_MET`으로 최종 종료하고 Healthy/Mutation execution을 시작하지 않는다. `B08` 이상 generation은 금지한다. Schema validation, semantic validation, duplicate key, executable resolution 및 deterministic ordering rule은 v1.0에서 변경하지 않는다.

100개를 초과하면 Section 7의 frozen ordering을 전체 eligible pool에 적용하고 처음 100개만 frozen pool로 채택한다. 나머지는 `VALID_UNSELECTED_CAPACITY`로 보존하며 삭제하지 않는다.

## 4. Leakage Prevention

Candidate generation request에는 다음 세 입력만 사용한다.

1. `ai/01_AI_Test_Basis.md`
2. frozen generation prompt
3. canonical output schema

Generation, validation, normalization, deduplication 및 ordering에서 다음 정보를 읽거나 score에 사용하지 않는다.

- Mutation execution results 또는 kill matrix
- 기존 Manual/AI kill 결과 및 mutation effectiveness
- Manual Test Cases와 Manual input values
- Coverage result 또는 coverage-based candidate ranking
- SIL Phase A/Phase B result
- candidate별 예상 kill 가능성

Batch metadata에는 실제 사용한 input file hash를 기록한다. Leakage sanity check가 실패하면 해당 batch는 API 호출 전에 중단한다.

## 5. Validation and Pool Construction Pipeline

```text
Raw LLM candidates
  -> strict schema validation
  -> existing semantic validation
  -> 형식 통일 (canonical normalization)
  -> deterministic cross-batch duplicate detection
  -> executable resolution
  -> deterministic ordering
  -> frozen 100-candidate pool
```

### 5.1 Schema and semantic validation

- 현재 `tc_schema.py`의 field, enum 및 allowed Requirement ID를 유지한다.
- `validate_test_cases.py`의 numeric, nominal-range, unsupported-threshold 및 duplicate rules를 유지한다.
- NaN/Inf, missing fields, unsupported Requirement ID 및 semantic rejection은 reason과 함께 보존한다.
- Candidate rejection은 generation infrastructure failure와 구분한다.

### 5.2 형식 통일 (Canonical normalization)

Normalization은 original candidate를 수정하지 않고 별도 canonical representation을 생성한다.

- `requirement_id`, `test_scope`, `test_design_technique`: validated enum value 사용
- SpeedRef values: JSON number를 finite decimal representation으로 변환하고 trailing zero를 제거하며 `-0`은 `0`으로 통일
- Ordered SpeedRef sequence: 순서, 부호, magnitude 및 반복을 보존
- `segment_count`: SpeedRef value count
- `waveform_type`:
  - one value: `CONSTANT`
  - two or more values with at least one non-zero sign change: `REVERSAL_SEQUENCE`
  - 그 외 two or more values: `MULTI_SEGMENT_CONSTANT_SEQUENCE`
- `polarity_signature`: ordered sign sequence `NEGATIVE`, `ZERO`, `POSITIVE`

원문 `input_values`, objective, rationale 및 text fields는 provenance를 위해 함께 보존한다.

### 5.3 Deterministic duplicate detection

LLM 또는 embedding 기반 의미 판단은 duplicate judge로 사용하지 않는다. Cross-batch duplicate key는 다음 exact tuple이다.

```text
(
  requirement_id,
  waveform_type,
  normalized ordered SpeedRef sequence,
  segment_count
)
```

동일 key가 여러 번 나타나면 `(batch_id, original_candidate_id)` lexicographic order의 첫 candidate를 representative로 유지한다. 나머지는 `DUPLICATE`로 기록하고 representative ID를 연결한다. Objective 문구가 다르더라도 동일 Requirement와 동일 실행 waveform이면 이 extension의 execution-budget 관점에서는 duplicate로 취급한다.

### 5.4 Executable resolution

기존 Execution Adapter semantics를 재사용한다.

- 각 SpeedRef segment: `2.0 s`
- Total duration: `segment_count * 2.0 s`
- Existing Requirement-to-Oracle mapping 유지
- REQ-TRK applicability gate와 REQ-REV setup/outcome semantics 유지

Resolution이 불가능한 candidate는 `EXECUTABLE_RESOLUTION_REJECTED`로 기록하며 대체 candidate를 사후 생성하지 않는다. Eligible pool에 이미 100개 이상 있으면 frozen ordering의 다음 candidate가 자연스럽게 100-candidate cutoff 안으로 들어온다.

## 6. Frozen Candidate Identity

각 raw candidate에는 다음 identity를 기록한다.

- `batch_id`: 기본 `B01`~`B05`, fallback 사용 시 `B06`, v1.1 one-time capacity extension 사용 시 `B07`
- `original_candidate_id`: LLM response의 ID
- `extension_candidate_id`: `EXT-Bxx-<original_candidate_id>`를 filename-safe하게 정규화한 값
- `canonical_duplicate_key_sha256`: Section 5.3 tuple의 UTF-8 canonical JSON SHA-256

Candidate ID collision은 content duplicate와 구분한다. 동일 original ID가 다른 batch에서 재사용되어도 global ID는 충돌하지 않는다.

## 7. Deterministic Ordering and Nested Budgets

Ordering은 generation 및 validation이 끝난 뒤, Healthy/Mutation 결과를 보기 전에 freeze한다. 다음 candidate-content-only rule을 적용한다.

1. Requirement bucket을 고정 순서 `REQ-VOLT-001`, `REQ-TRK-001`, `REQ-DIR-001`, `REQ-REV-001`로 둔다.
2. 각 candidate에 대해 아래 validated/canonical 정보만 포함한 canonical UTF-8 JSON을 생성한다.
   - `requirement_id`
   - `test_scope`
   - `test_design_technique`
   - `waveform_type`
   - normalized ordered SpeedRef sequence
   - `segment_count`
   - `extension_candidate_id`
3. 위 JSON의 SHA-256을 `ordering_hash`로 계산하고 각 Requirement bucket 내부를 hash ascending order로 정렬한다. Hash가 같으면 `extension_candidate_id` lexicographic order로 결정한다.
4. Global pool은 네 Requirement bucket에서 한 개씩 round-robin으로 취한다. 소진된 bucket은 건너뛴다.
5. 100개를 채운 시점에서 ordering, candidate별 ordering hash와 pool hash를 freeze한다.

Hash input에는 Mutation, Coverage, SIL, Manual result를 포함하지 않는다. 이 ordering은 결과를 보지 않고 재현 가능한 순서를 만들며, nominal/stress 또는 특정 waveform이 단순 lexicographic ordering 때문에 작은 budget 앞쪽에 구조적으로 몰리는 현상을 줄인다. Requirement exposure는 round-robin으로 prefix 전반에 분산한다. Scope 또는 technique에 별도 target quota를 두거나 각 budget을 따로 최적화하지 않는다.

같은 테스트 목록에서 개수만 늘리는 nested Test Budget은 동일 ordered pool의 prefix로 정의한다.

| Budget | Included ordered indices |
|---:|---|
| 10 | 1~10 |
| 25 | 1~25 |
| 50 | 1~50 |
| 75 | 1~75 |
| 100 | 1~100 |

Budget별로 candidate를 다시 선택하거나 Mutation 결과를 보고 ordering을 변경하지 않는다.

## 8. Healthy MIL Execution Gate

100-candidate maximum pool을 Healthy MIL에서 ordered index 순으로 한 번 실행한다. Nested budget 결과는 동일 실행 결과의 prefix view로 산출하며 동일 candidate를 budget마다 재실행하지 않는다.

Candidate별로 다음을 기록한다.

- `PASS`
- `FAIL`
- `INCONCLUSIVE_PRECONDITION`
- `EXECUTION_ERROR`
- elapsed runtime
- Requirement ID
- test scope
- waveform type
- applicability 및 reversal setup 상태

Mutation phase 전 Healthy 상태를 다음과 같이 처리한다.

- Healthy `FAIL`: DUT Requirement failure 가능성이 있으므로 `HEALTHY_BASELINE_GATE_FAILED`로 기록하고 전체 Mutation phase를 시작하지 않는다.
- Healthy `EXECUTION_ERROR`: test infrastructure, data 또는 Oracle failure 가능성이 있으므로 `HEALTHY_BASELINE_GATE_FAILED`로 기록하고 전체 Mutation phase를 시작하지 않는다.
- Healthy `INCONCLUSIVE_PRECONDITION`: 결과와 원인을 보존하되 전체 Mutation phase를 막지 않는다. 해당 Test Case는 Mutation execution과 kill 판정 대상에서 제외한다.
- Healthy `PASS`: 해당 Test Case만 Mutation execution 및 판정 대상이 된다.

REQ-TRK applicability와 REQ-REV setup 의미는 기존 V1 semantics를 유지한다. Healthy `INCONCLUSIVE_PRECONDITION`은 해당 조건에서 Requirement 판정을 내릴 수 없다는 뜻이며 FAIL로 바꾸지 않는다. **Healthy PASS가 아닌 Test Case를 제거하거나 교체하여 pool을 다시 구성하지 않는다.** Frozen pool과 ordered index는 그대로 유지한다.

Healthy 결과, applicability, reversal setup, failure reason과 elapsed runtime은 상태와 관계없이 모두 저장한다.

## 9. Mutation Execution and 판정

Healthy gate가 통과한 경우 frozen Primary Mutation Set 6개를 동일 ordered pool의 Healthy `PASS` Test Case에 적용한다.

- Healthy executions: 100
- Mutation executions: 최대 `100 * 6 = 600`
- Maximum simulation executions: 700
- Actual mutation executions: `Healthy PASS Test Count * Valid Mutant Count`

일부 Healthy candidate가 `INCONCLUSIVE_PRECONDITION`이면 실제 Mutation execution 수는 600보다 작을 수 있다. 각 execution은 한 번만 수행하고 budget별 result는 ordered prefix로 집계한다. 각 budget의 Mutation 대상 Test Case 수와 Test-Mutant denominator는 해당 prefix 안의 실제 Healthy `PASS` count와 valid mutant count를 사용한다.

Kill criterion:

```text
Healthy PASS -> Mutant FAIL = KILL
```

다음은 KILL이 아니다.

- `INCONCLUSIVE_PRECONDITION`
- `EXECUTION_ERROR`
- `INVALID_MUTANT`

Healthy-baseline-fixed Tracking applicability를 mutant run에서 재계산하지 않는다. Reversal setup이 mutant 영향으로 성립하지 않으면 기존 protocol대로 `INCONCLUSIVE_PRECONDITION`이며 kill이 아니다. `INVALID_MUTANT`는 Mutation Score denominator에서 제외하고 별도 기록한다. Mutant execution 도중 model parameter가 baseline으로 복구되지 않거나 on-disk model integrity가 달라지면 이후 execution을 중단한다.

## 10. Metrics

각 budget `10`, `25`, `50`, `75`, `100`에 대해 다음을 산출한다.

### 10.1 Core metrics

- Test Count
- Healthy PASS count and rate
- Healthy FAIL count
- Healthy INCONCLUSIVE count
- Healthy EXECUTION_ERROR count
- Valid Mutants
- Mutants Killed
- Mutation Score = `Killed valid mutants / Total valid mutants`
- Kill Cells
- Mutation-Eligible Test Count = 해당 budget prefix의 Healthy `PASS` Test Case 수
- Total Test-Mutant Cells = `Mutation-Eligible Test Count * Valid Mutants`
- Kill Density = `Kill Cells / Total Test-Mutant Cells`
- Inconclusive Mutation Cells
- Mutation Execution Error Cells
- Elapsed Runtime

### 10.2 Budget-effectiveness metrics

- `cumulative_kill_cells(b)`: ordered index `1..b`의 kill-cell 합
- `marginal_kill_cell_gain(b_i)`: 현재 budget cumulative kill cells에서 이전 budget cumulative kill cells를 뺀 값
- `first_kill_test_index` per mutant: 해당 mutant의 첫 KILL ordered index
- `all_killable_mutants_first_killed_budget`: 현재 100-test experiment에서 한 번 이상 kill된 모든 valid mutant가 처음 모두 kill된 최소 frozen budget. Frozen budget 사이에서 발생한 정확한 test index도 별도 기록
- `zero_kill_test_count(b)`: 해당 budget prefix에서 어떤 valid mutant도 KILL하지 못한 Healthy `PASS` Test Case 수
- `no_new_mutant_test_count(b)`: 해당 Test Case가 이전 ordered prefix에서 이미 한 번 이상 검출된 mutant만 다시 KILL하고 새로운 mutant를 추가로 검출하지 못한 Healthy `PASS` Test Case 수

두 metric은 frozen six-mutant set과 이전 ordered prefix에 대해서만 정의한다. `zero_kill` 또는 `no_new_mutant` Test Case가 다른 fault, Requirement, coverage objective 또는 실제 결함에 일반적으로 불필요하다는 의미가 아니다. `no_new_mutant_test_count`는 kill-cell 재검출을 무시하지 않으며 `cumulative_kill_cells`와 함께 해석한다.

V1에서 이미 6/6 mutants가 killed였으므로 Extension의 주요 관찰값은 Mutation Score뿐 아니라 kill-cell growth, marginal gain, first-kill position, saturation behavior 및 runtime이다.

## 11. Runtime and Automation Evidence

Wall-clock monotonic timer를 사용해 최소 다음을 기록한다.

- generation 및 pool-construction elapsed time
- total simulation elapsed time
- healthy execution elapsed time
- mutation execution elapsed time
- per-execution elapsed time
- average time per completed execution
- failed execution count
- retry count

Extension v1은 별도의 automatic timeout 기능을 구현하지 않는다. 실제 elapsed time은 기록하며 MATLAB/Simulink 자체 실행 오류는 `EXECUTION_ERROR`로 처리한다. 사용자가 외부에서 실행을 강제 종료하면 해당 run을 incomplete로 기록한다. Automatic retry count는 0이다. Timeout 기능은 Future Improvement로 남긴다.

Execution interruption 이후 completed execution artifact는 row 단위로 즉시 보존한다. Resume은 다음 값이 모두 동일할 때만 허용한다.

- Git commit
- Protocol version
- frozen pool hash
- Mutation Set hash
- model hash
- execution adapter parameters

하나라도 다르면 resume하지 않고 새 `run_id`로 전체 affected phase를 다시 시작한다. 기존 incomplete artifact는 삭제하거나 덮어쓰지 않는다. Resume 구현 방식은 Implementation 단계에서 설계하지만 이 compatibility semantics는 본 Protocol에서 freeze한다.

Runtime은 현재 host에서 automation scalability를 설명하는 값이다. Controller real-time execution time, WCET, `400 us` deadline, target MCU 성능 또는 HIL timing으로 해석하지 않는다.

## 12. Output Artifacts and Provenance

Extension artifact는 기존 V1 result와 분리하여 `results/scalability_extension_v1/` 아래에 저장한다.

권장 파일:

- `candidate_batches/batch_01_raw.json` ~ `batch_05_raw.json`, fallback 사용 시 `batch_06_raw.json`, v1.1 amendment 사용 시 `batch_07_raw.json`
- `candidate_pool_raw.json`
- `candidate_pool_raw.csv`
- `candidate_validation_results.csv`
- `candidate_validation_summary.csv`
- `duplicate_report.csv`
- `executable_resolution_results.csv`
- `candidate_pool_frozen.csv`
- `budget_definition.csv`
- `healthy_execution_results.csv`
- `mutation_execution_results.csv`
- `mutation_kill_matrix.csv`
- `budget_effectiveness_summary.csv`
- `per_mutant_first_kill.csv`
- `runtime_summary.csv`
- `metadata.txt`

`metadata.txt`에는 최소 다음을 기록한다.

- protocol version/status 및 Git commit/branch
- model path/hash
- Requirements/Test Basis/prompt/schema hashes
- Mutation Set hash와 six-mutant identity
- generator model/provider metadata와 batch response IDs (API key 제외)
- MATLAB/Simulink release 및 host environment
- `ts`, solver, execution adapter parameters
- frozen pool row count/hash와 ordering rule version
- run ID, start/end timestamp 및 completion status

Candidate raw content와 허용된 generation metadata는 보존한다. API key와 전체 raw API response envelope은 저장하지 않는다. 기존 V1 output/result는 overwrite하지 않는다.

Git에 commit하는 Extension artifact는 다음으로 freeze한다.

- Protocol과 source code
- frozen candidate pool과 budget definition
- candidate validation/duplicate summary
- summary CSV와 kill matrix
- runtime summary와 metadata

다음은 기본적으로 Git에서 제외한다.

- 대용량 per-sample simulation time-series
- temporary build/cache
- API key
- 전체 raw API response envelope

## 13. Stop and Failure Conditions

| Condition | Required handling |
|---|---|
| Leakage sanity check failure | API 호출 전 중단, `LEAKAGE_CHECK_FAILED` |
| Batch API/schema infrastructure failure | 해당 batch 실패 기록, 자동 retry 없이 generation phase 중단 |
| Individual semantic rejection | candidate rejection reason 기록; eligible count 계산 계속 |
| `B01`~`B05` 후 eligible unique candidate 100개 미만 | 사전 승인 `B06` 1회 생성 |
| `B01`~`B06` 후 eligible unique candidate 100개 미만이며 Healthy/Mutation 미실행 | v1.1 one-time capacity extension `B07` 1회 생성 |
| `B07` 후에도 100개 미만 | `POOL_TARGET_NOT_MET`; Healthy/Mutation 실행 금지 |
| `B08` 이상 generation 요청 | 금지; generation 시작 전 중단 |
| 형식 통일/deduplication non-determinism | `POOL_BUILD_ERROR`; artifact와 hash 보존 후 중단 |
| Executable resolution failure | candidate별 rejection 기록; 최종 eligible count가 100 미만이면 중단 |
| Healthy baseline gate failure | `HEALTHY_BASELINE_GATE_FAILED`; Mutation 실행 금지 |
| MATLAB simulation/data/Oracle failure | `EXECUTION_ERROR`; 해당 phase 중단 여부와 completed prefix를 기록 |
| 사용자의 외부 강제 종료 | incomplete run으로 기록; completed rows와 기존 artifact 보존 |
| Invalid or unapplied mutation | `INVALID_MUTANT`; kill 아님, denominator에서 제외 |
| Model state/hash restoration failure | 즉시 전체 mutation phase 중단 |
| Incomplete artifact write or row-count/hash mismatch | `INCOMPLETE_RESULT_ARTIFACT`; 완료 결과로 해석 금지 |

결과를 맞추기 위해 generation prompt, validation, deduplication, ordering, Oracle, Mutation Set 또는 candidate input을 사후 변경하지 않는다. 변경이 필요하면 기존 run을 보존하고 새로운 protocol revision/experiment ID를 사용한다.

## 14. Interpretation Rules

- Test 수 증가가 Mutation Score 증가를 반드시 의미하지 않는다.
- Mutation Score가 작은 budget에서 100%가 되어도 실험 실패가 아니다.
- Mutation Score가 포화된 뒤에도 kill-cell distribution, marginal gain 및 runtime은 scalability evidence가 될 수 있다.
- `6/6 killed`는 frozen Primary Mutation Set에 한정되며 “모든 결함을 찾았다”는 의미가 아니다.
- Kill density가 높거나 낮다는 사실만으로 requirement coverage 또는 실제 defect detection capability 전체를 대표하지 않는다.
- Extension은 Manual-vs-AI controlled comparison이 아니며 AI의 일반적 우수성을 주장하지 않는다.
- Healthy MIL PASS와 mutation kill은 Host SIL, HIL, target MCU, WCET 또는 physical motor 검증을 의미하지 않는다.
- Extension result는 DUT, Requirements, Oracles, six-mutant fault set, candidate-generation basis 및 current numerical/host environment 범위에 한정된다.

## 15. Implementation Plan

V1 artifact를 보존하기 위해 기존 scripts를 직접 확장하기보다 다음 별도 scripts를 추가하는 것을 기본 방침으로 한다.

| Planned script | Purpose |
|---|---|
| `ai/generate_scalability_candidate_batches.py` | 기본 5개 batch, 조건부 `B06`, v1.1 조건부 one-time `B07` 생성 및 batch별 raw/provenance 저장 |
| `ai/build_scalability_candidate_pool.py` | validation 결과 병합, 형식 통일, deduplication, ordering, 100-candidate freeze |
| `ai/build_scalability_execution_spec.py` | frozen pool을 기존 2.0 s adapter semantics로 resolved spec 변환 |
| `runner/run_ai_scalability_suite.m` | arbitrary ordered pool의 Healthy MIL 실행 및 runtime/status 수집 |
| `runner/run_ai_scalability_mutation_analysis.m` | frozen six-mutant execution과 corrected Mutation 판정 적용 |
| `runner/run_scalability_extension.m` | preflight부터 Healthy gate, Healthy PASS 대상 Mutation 실행, aggregation, runtime summary 및 completion status까지 한 명령으로 조정 |
| `ai/analyze_scalability_results.py` | nested budget effectiveness, first kill 및 runtime summary 생성 |

Frozen candidate pool이 준비된 뒤 사용자는 MATLAB에서 다음과 같이 master runner를 실행할 수 있어야 한다.

```matlab
addpath('runner');
run_scalability_extension();
```

AI API generation은 Python generation phase이므로 MATLAB master runner에 포함하지 않는다.

기존 `generate_test_cases.py`, `validate_test_cases.py`, `build_ai_execution_spec.py`, `run_ai_mil_suite.m`, `run_ai_mutation_analysis.m`의 V1 behavior와 V1 result files는 변경하지 않는다. 필요한 공통 로직 추출은 구현 전에 별도 review 대상으로 하며 V1 regression evidence 없이 수행하지 않는다.

## 16. Frozen Implementation Decisions

Implementation은 다음 결정에서 벗어나지 않는다.

1. Provider/model/configuration은 V1 candidate generation과 동일한 설정을 사용한다. Exact identity와 usage/cost는 run metadata에 기록하며 API 비용 자체는 Protocol blocking condition이 아니다.
2. 기본 generation은 `B01`~`B05`, 각 25 candidates이다. Eligible pool이 100개 미만일 때 `B06` 1회를 사용한다. `B01`~`B06` 결과가 95개였고 Healthy/Mutation execution이 시작되지 않았으므로 v1.1 amendment에서 `B07` 1회를 허용하며 최대 raw count는 175이다. `B08` 이상은 생성하지 않는다.
3. Candidate raw content, batch ID, original/global candidate ID, validation/deduplication 결과와 허용된 provider/model/response metadata를 보존한다. API key와 전체 raw API response envelope은 보존하지 않는다.
4. Ordering은 Requirement round-robin과 candidate-content SHA-256 ordering으로 고정한다. Mutation/Coverage/SIL/Manual result는 ordering에 사용하지 않는다.
5. Automatic timeout을 구현하지 않는다. Elapsed time과 MATLAB/Simulink 오류를 기록하고 automatic retry는 0으로 한다.
6. Resume은 동일 Git commit, Protocol version, frozen pool hash, Mutation Set hash, model hash와 execution adapter parameters에서만 허용한다. 그 외에는 새 run ID로 affected phase 전체를 다시 시작한다.
7. Section 12의 Git/artifact policy를 적용한다. 기존 incomplete/raw evidence를 사후 삭제하거나 V1 result를 overwrite하지 않는다.
8. MATLAB master runner는 frozen pool 이후의 preflight, Healthy MIL, gate, Healthy PASS 대상 Mutation, 집계 및 완료 상태를 조정한다. AI API generation은 포함하지 않는다.

본 v1.1 Amended Protocol은 기존 implementation semantics를 유지하면서 위 one-time `B07` capacity extension만 승인한다. Healthy/Mutation execution은 frozen 100-candidate pool이 준비된 뒤 별도 사용자 명령으로 시작한다.

## 17. Revision Note

### v1.1 Amended — One-Time B07 Capacity Extension

`B01`~`B06`의 candidate-only 처리 결과 eligible unique executable candidates가 95개임을 Healthy MIL 및 Mutation execution 전에 확인하였다. Frozen 100-case target을 유지하기 위해 동일한 provider/model/prompt/schema와 기존 validation, deduplication, executable resolution 및 ordering rule을 사용하는 `B07` 25 candidates를 one-time capacity extension으로 승인한다. Maximum raw candidates는 175이며 `B08` 이상은 금지한다. `B07` 이후에도 100개 미만이면 `POOL_TARGET_NOT_MET`으로 최종 종료한다.

### v1.0 Frozen — Approved for Implementation

V1 Manual 9 vs AI 9 controlled comparison을 보존하면서, 기본 5 x 25 generation과 사전 승인 `B06` capacity fallback으로 100 unique executable candidates를 구성한다. Requirement round-robin과 content-hash ordering으로 같은 테스트 목록에서 개수만 늘리는 budgets `10/25/50/75/100`을 고정하고, Healthy PASS Test Cases에 대해 frozen six-mutant 기준 검출 효과와 automation runtime을 분석하는 독립 extension protocol을 승인하였다.
