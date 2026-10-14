# AS2308 Verification Final Technical Report

| 항목 | 내용 |
|---|---|
| 보고서 목적 | Frozen MIL, Coverage, Mutation, AI-assisted Test 및 SIL evidence의 최종 통합 |
| Requirements baseline | `requirements/01_Requirements.md` v1.1 Frozen |
| MIL baseline | `model/AS2308_MIL_Baseline_v3.slx` |
| SIL protocol | `docs/04_SIL_BackToBack_Protocol_v1.2.md` v1.2 Frozen |
| Traceability baseline | `docs/06_Requirements_Traceability_Matrix.md` |
| 작성 원칙 | Repository에 보존된 frozen protocol과 결과 artifact만 사용하며 새 실험이나 새 acceptance criterion을 도입하지 않음 |

## 1. Project Objective

이 프로젝트의 주 목적은 AS2308 BLDC Speed PI Controller에 대한 재현 가능한 소프트웨어 검증 환경을 구축하는 것이다. 실제 BLDC 실험 데이터로 식별한 reduced-order plant를 폐루프 MIL 환경에 사용하고, frozen requirement를 deterministic MATLAB Oracle로 판정하였다. Test Suite의 structural adequacy는 Model Coverage로, fault-detection effectiveness는 Mutation Testing으로 보완하였다.

Manual Test Case, Mutation 및 Coverage 결과를 제공하지 않은 상태에서 requirements/environment/I/O와 AI Test Basis를 기반으로 LLM이 Test Case 후보를 생성하도록 구성하고, schema/semantic validation과 사전 고정된 deterministic selection을 거쳐 같은 DUT, Oracle, fault set 및 9개 top-level execution budget에서 효과를 비교하였다. 마지막으로 frozen source에서 추적 가능한 verification model을 생성하고, generated-code host SIL과 Normal model의 numerical equivalence를 source-to-derived gate, Phase A characterization, tolerance freeze, independent Phase B evaluation 순으로 검증하였다.

따라서 본 프로젝트는 AI 기능 개발 자체가 아니라 requirements-based verification, test-effectiveness 평가 및 generated-code equivalence 확인을 중심으로 한다.

## 2. System Under Test and Verification Environment

MIL DUT는 `AS2308_MIL_Baseline_v3/PI Speed Controller`이며, verification reference path는 `SpeedRef [rps] -> 2*pi unit conversion -> Speed PI Controller`이다. 기존 실습 모델의 `20/(s+20)` reference prefilter는 이 verification path에 포함되지 않는다. (`requirements/01_Requirements.md`)

| 항목 | Frozen value 또는 구조 |
|---|---|
| DUT | Speed PI Controller |
| Verification plant | `G(s) = 2185.96 / (s + 17.76)` |
| Plant origin | 실제 AS2308 voltage/angular-velocity 실험 데이터로 식별한 first-order voltage-to-speed reduced-order model |
| `Kps` | `0.11497347265603371` |
| `Kis` | `2.041928874371159` |
| `Kas` | `17.760000000000002` (`Kis/Kps`) |
| `Vdc` | `12 V` |
| Solver | Fixed-step `ode4` |
| Fixed step | `ts = 0.00040000000000000002 s` |
| Numerical datatype | `double` |
| Controller state | Continuous-time Integrator |
| Plant state | Continuous transfer function |
| Verified MATLAB/Simulink environment | MATLAB R2023b / Simulink 23.2 |

Parameter relation과 anti-windup topology는 frozen source script/model을 저장하지 않고 read-only로 확인했으며, execution configuration은 gate와 SIL metadata에도 보존되어 있다. (`results/static_requirement_verification_v1/static_verification_summary.csv`, `results/static_requirement_verification_v1/metadata.txt`, `results/source_derived_equivalence_v1/metadata.txt`, `results/sil_b2b_phase_b_v1/metadata.txt`)

`0.0004 s`는 이 모델의 fixed-step numerical integration 간격이다. 현재 controller와 plant는 continuous dynamics를 유지하므로 이를 standalone discrete controller execution period 또는 검증된 400 us real-time deadline으로 해석하지 않는다. Plant 또한 speed-domain 검증을 위한 저차 모델이며 실제 BLDC의 current, PWM, encoder 및 detailed electrical transient 전체를 1차로 모델링했다고 주장하지 않는다.

## 3. Verification Strategy

검증 흐름은 다음과 같이 구성되었다.

```text
Actual BLDC experiment
  -> voltage-to-speed plant identification
  -> frozen MIL baseline
  -> frozen requirements and environment
  -> read-only static/configuration verification
  -> Manual requirements-based Test Suite
  -> deterministic MATLAB Oracles
  -> Model Coverage measurement
  -> frozen Mutation Set evaluation
  -> independent AI-assisted candidate generation and validation
  -> deterministic 9-test AI Suite selection/execution
  -> Manual/AI Mutation effectiveness comparison
  -> deterministic derived SIL verification model
  -> Source-to-Derived exact-equivalence gate
  -> SIL Phase A numerical characterization
  -> numerical criterion freeze
  -> independent SIL Phase B evaluation
```

MIL requirement compliance와 SIL equivalence는 서로 다른 목적이다. MIL은 requirement와 Oracle의 관계를 확인하고, SIL은 동일 numerical environment에서 Normal model과 generated-code execution의 동등성을 확인한다. SIL `PASS`를 product requirement `PASS`로 대체하지 않는다.

## 4. Requirements-Based MIL Verification

Frozen Requirements v1.1은 source-backed requirement와 derived functional requirement를 구분한다. (`requirements/01_Requirements.md`)

| Requirement | Verification method | Final result | Primary evidence |
|---|---|---|---|
| `REQ-VOLT-001` | 전체 simulation의 deterministic Voltage Oracle | Manual 2/2 `PASS`; AI 2/2 `PASS` | Corrected healthy baseline CSVs |
| `REQ-BW-001` | Frozen source script의 `f_cs` read-only static/configuration check | Static `PASS`: observed `f_cs = 40 Hz` | `results/static_requirement_verification_v1/static_verification_summary.csv` |
| `REQ-PI-001` | `Kps = w_cs/b`, `Kis = a*Kps` relation과 model gain expression 비교 | Static `PASS`: Kps/Kis expected-observed difference 각각 0 | `results/static_requirement_verification_v1/static_verification_summary.csv` |
| `REQ-AW-001` | Anti-windup feedback topology와 `Kas = Kis/Kps` relation의 read-only inspection | Static `PASS`: topology 존재, Kas expected-observed difference 0 | `results/static_requirement_verification_v1/static_verification_summary.csv` |
| `REQ-TRK-001` | Healthy-baseline applicability gate 후 deterministic Tracking Oracle | Manual 2/2 `PASS`·`APPLICABLE`; AI 3/3 `PASS`·`APPLICABLE` | Corrected healthy baseline CSVs |
| `REQ-DIR-001` | Deterministic Direction Oracle | Manual 2/2 `PASS`; AI 2/2 `PASS` | Corrected healthy baseline CSVs |
| `REQ-REV-001` | Pre-reversal setup과 post-reversal outcome에 Direction + Tracking Oracle 적용 | Manual 3/3 `PASS`; AI 2/2 `PASS`; setup `ESTABLISHED` | Corrected healthy baseline CSVs |

표의 corrected healthy baseline evidence는 `results/manual_mutation_corrected_v1/Manual_Corrected_Healthy_Baseline.csv`와 `results/ai_mutation_corrected_v1/AI_Corrected_Healthy_Baseline.csv`를 의미한다. Requirement별 Test Case, Oracle, mutation 및 SIL 연결은 `docs/06_Requirements_Traceability_Matrix.md`를 따른다.

Static Verification은 Polyspace-style code static analysis가 아니다. `model/AS2308_calculate_pi_control_cc.m`과 frozen Simulink configuration/topology를 read-only로 확인한 결과이며, model hash는 검사 전후 authoritative value를 유지하고 model은 저장되지 않았다. (`results/static_requirement_verification_v1/metadata.txt`)

`REQ-AW-001`의 static `PASS`는 anti-windup feedback 구조와 `Kas = Kis/Kps` relation에만 적용된다. Dynamic anti-windup recovery effectiveness에는 공식 compliance Oracle이나 threshold를 정의하지 않았으며 dynamic `PASS`로 판정하지 않았다.

환경 제약은 `ts = 0.0004 s`, identified plant, filter-free reference path와 필수 `2*pi` unit conversion, nominal `|SpeedRef| < 20 rps` 원칙을 고정한다. Saturation stress는 nominal verification과 구분한다. `steady-state error <= 1%`, `overshoot <= 5%`, `settling time <= 0.25 s`, `reversal settling time <= 0.30 s` 같은 source에 없는 수치는 acceptance criterion으로 사용하지 않았다.

Manual Dynamic Compliance Suite v1.0의 authoritative count는 5 logical Test Cases와 9 top-level executions이다. Corrected healthy baseline은 9/9 `PASS`, tracking 대상은 `APPLICABLE`, reversal setup은 `ESTABLISHED`, execution error는 0이었다. Repeated reversal인 MTC-005는 첫 plateau를 setup으로 취급하고 이후 required transition 5/5를 통과하였다. Official AI Suite도 corrected semantics에서 9/9 `PASS`, inconclusive 0, execution error 0이었다. (`results/manual_mutation_corrected_v1/Manual_Corrected_Healthy_Baseline.csv`, `results/ai_mutation_corrected_v1/AI_Corrected_Healthy_Baseline.csv`)

## 5. Deterministic Oracle

PASS/FAIL은 LLM이 아니라 다음 MATLAB Oracle과 frozen adjudication rule로 계산하였다.

- Voltage Oracle: simulation 전체 구간의 `max(Vcmd) <= +12` 및 `min(Vcmd) >= -12`를 모두 요구한다. 임의 tolerance를 추가하지 않는다. (`runner/oracles/evaluate_voltage_limit.m`)
- Tracking Oracle: 마지막 `0.05 s`에서 `max(abs(reference - motorspeed)) <= 1e-9 rps`를 요구한다. `1e-9 rps`는 healthy MIL numerical zero를 자동 판정하기 위한 project-specific numerical tolerance이며 제품 성능 요구사항이 아니다. (`runner/oracles/evaluate_tracking.m`)
- Direction Oracle: 마지막 `0.05 s`의 모든 sample에서 `reference * motorspeed > 0`이어야 한다. Tracking accuracy는 이 Oracle에 포함하지 않는다. (`runner/oracles/evaluate_direction.m`)
- Reversal evaluation: 별도 threshold를 만들지 않고 Direction과 Tracking Oracle을 조합한다.

Mutation Testing에는 Adjudication Protocol v1.0의 corrected semantics를 적용하였다. (`docs/03_Mutation_Adjudication_Protocol.md`)

- Healthy baseline에서 REQ-TRK applicability를 먼저 판정하고 mutant 실행 중에는 이를 변경하지 않는다.
- REQ-REV는 pre-reversal setup과 post-reversal outcome을 분리한다. Setup가 established되지 않으면 `INCONCLUSIVE_PRECONDITION`이며 reversal failure가 아니다.
- Healthy `PASS`가 동일 mutant execution에서 `FAIL`이 된 경우에만 `KILL`이다.
- `INCONCLUSIVE_PRECONDITION`, `EXECUTION_ERROR`, `INVALID_MUTANT`은 kill이 아니다.

## 6. Model Coverage

Manual Suite v1.0의 DUT structural coverage 결과는 다음과 같다. (`results/manual_suite_v1_coverage_summary.csv`)

| Metric | Covered | Total | Result |
|---|---:|---:|---:|
| Execution | 10 | 10 | 100% |
| Decision | 4 | 4 | 100% |
| Condition | 0 | 0 | N/A |
| MC/DC | 0 | 0 | N/A |

Condition과 MC/DC는 uncovered 0%가 아니라 해당 DUT 구조에 objective가 없어 `N/A`이다. Uncovered-objective CSV에도 행이 없다. (`results/manual_suite_v1_uncovered_objectives.csv`)

Execution/Decision 100%는 관찰된 structural objectives가 실행되었다는 의미이지 결함 부재나 requirement 충족의 충분조건이 아니다. 실제 fault를 Test Suite가 판별할 수 있는지는 Coverage만으로 알 수 없으므로 별도의 frozen Mutation Set으로 검출 효과를 평가하였다.

## 7. Mutation Verification

Primary Mutation Set은 controller parameter, feedback logic, saturation boundary에 대한 6개 fault로 고정되었다. Plant는 mutate하지 않았고 runtime override만 사용하였다. (`mutations/01_Mutation_Set.csv`)

| Mutant | Fault | Manual kills | AI kills | Corrected status |
|---|---|---:|---:|---|
| `MUT-001` | `Kis = 0` | 2 | 3 | Both KILLED |
| `MUT-002` | `Kis = -abs(Kis)` | 4 | 5 | Both KILLED |
| `MUT-003` | Error Sum `+-` -> `++` | 2 | 3 | Both KILLED |
| `MUT-004` | Upper limit `+12 -> +13 V` | 1 | 1 | Both KILLED |
| `MUT-005` | Lower limit `-12 -> -13 V` | 1 | 2 | Both KILLED |
| `MUT-006` | Upper limit `+12 -> 0 V` | 4 | 4 | Both KILLED |

Final 수치는 initial/superseded result가 아니라 Adjudication Protocol v1.0을 적용한 versioned corrected result이다.

| Metric | Manual Suite | Official AI Suite |
|---|---:|---:|
| Top-level executions per mutant | 9 | 9 |
| Valid mutants | 6 | 6 |
| Killed mutants | 6/6 | 6/6 |
| Mutation score | 100% | 100% |
| Kill cells | 14/54 | 18/54 |
| Kill density | 25.9259259259259% | 33.3333333333333% |
| Inconclusive execution cells | 10 | 8 |
| Execution errors | 0 | 0 |

근거는 `results/manual_mutation_corrected_v1/manual_mutation_summary.csv`, `results/manual_mutation_corrected_v1/manual_mutation_per_mutant.csv`, `results/ai_mutation_corrected_v1/AI_Mutation_Summary.csv`이다.

동일 DUT, Oracle, mutation set과 9-execution budget에서 두 Suite 모두 6개 mutant를 모두 검출했고, AI Suite가 이 frozen experiment에서 4개 더 많은 kill cell을 만들었다. 이는 해당 Suite와 fault set에 한정된 관찰이며 AI가 일반적으로 Manual 설계보다 우수하거나 더 정확하다는 결론은 아니다.

## 8. AI-Assisted Test Generation

AI-assisted 경로는 다음 책임 분리를 사용하였다.

```text
Requirements + AI Test Basis + generation prompt
  -> OpenAI Responses API strict structured output
  -> canonical schema validation
  -> semantic validation
  -> 25-candidate VALID pool
  -> frozen deterministic selector
  -> 9-candidate Official AI Suite
  -> deterministic MATLAB waveform adapter and runner
  -> deterministic MATLAB Oracles
```

Generation metadata는 provider `OpenAI`, model `gpt-5.6-luna`, reasoning effort `medium`, Responses API, requested/returned candidates `25/25`, semantic valid/rejected `25/0`, status `SUCCESS`를 기록한다. (`ai/output/ai_generation_metadata.json`)

선택 전 protocol은 mutation, Manual Test Case 및 Coverage 결과 사용을 금지하였다. Requirement quota `VOLT 2 / TRK 3 / DIR 2 / REV 2`를 hard constraint로 적용하고, scope `nominal 5 / stress 4`, technique `BVA 4 / EP 2 / State Transition 1 / Scenario-Based 2`를 정확히 만족하는 조합을 118,125개 중 deterministic lexicographic rule로 선택하였다. (`ai/02_AI_Suite_Selection_Protocol.md`, `ai/output/ai_suite_v1_selection_summary.csv`)

선택된 9개는 `TC-DIR-001`, `TC-DIR-002`, `TC-REV-001`, `TC-REV-003`, `TC-TRK-003`, `TC-TRK-005`, `TC-TRK-007`, `TC-VOLT-004`, `TC-VOLT-006`이다. 추상 candidate는 plateau당 `2.0 s`의 test execution parameter로 deterministic waveform에 매핑되었고 원본 magnitude와 order는 유지되었다. Healthy AI MIL 결과는 corrected adjudication 기준으로 9/9 `PASS`, inconclusive 0, execution error 0이었다. (`ai/output/ai_suite_v1_resolved_execution_spec.csv`, `results/ai_mutation_corrected_v1/AI_Corrected_Healthy_Baseline.csv`)

LLM의 역할은 constrained candidate generation까지이며, Test Suite selection, waveform resolution, execution 및 PASS/FAIL 판정은 deterministic code가 담당한다. RAG, vector database, fine-tuning 또는 agent-based judging을 사용했다는 근거는 없다.

## 9. SIL Architecture and Initial Failure

SIL 목적은 closed-loop MIL model과 generated-code host SIL의 functional/numerical equivalence 확인이다. Source 전체 top model을 GRT 대상으로 삼았으며 standalone controller implementation verification으로 표현하지 않는다. (`docs/04_SIL_BackToBack_Protocol.md`)

첫 Phase A attempt에서는 top-model GRT code generation, standalone SIL executable build 및 SIL execution 자체는 성공했지만, required internal `Vcmd`와 `MotorSpeed`가 continuous sample-time signals라 선택한 SIL internal signal-logging interface에서 수집되지 않았다. Required comparison data를 확보할 수 없어 상태는 `EXECUTION_ERROR`였다. 이는 controller functional failure나 Model-Code mismatch가 아니라 observability infrastructure failure로 판정되었다. (`docs/04_SIL_BackToBack_Protocol_v1.1.md`)

Frozen source를 수정하지 않고 deterministic derived model `model/verification/AS2308_SIL_B2B_Verification_v1.slx`를 생성하여 다음 transformation만 허용하였다.

- Internal Constant/Pulse/Manual Switch stimulus를 discrete root input `SpeedRef_rps`로 externalize
- 기존 `2*pi` unit conversion과 이후 closed-loop dynamics 유지
- Continuous `Vcmd`와 `MotorSpeed`에 non-feedback, observation-only Zero-Order Hold branch 추가
- `SampleTime = ts`의 `sampled_Vcmd`, `sampled_MotorSpeed` root output 추가

ZOH는 evidence collection용이며 controller/plant feedback path에 삽입되지 않는다. Continuous PI Integrator, continuous plant, fixed-step `ode4`, parameter 및 feedback semantics는 유지되었다. (`model/verification/AS2308_SIL_B2B_Verification_v1_manifest.txt`)

## 10. Source-to-Derived Equivalence Gate

SIL Phase A 전에 Protocol v1.1의 2-stage exact gate를 실행하였다.

- Stage A — Dynamic preservation: frozen source Normal의 internal continuous `Vcmd`/`MotorSpeed`와 derived Normal의 같은 internal signal을 동일 major-time grid에서 비교
- Stage B — Observation fidelity: derived Normal internal major-grid values와 `sampled_Vcmd`/`sampled_MotorSpeed` root outputs를 같은 sample index에서 비교

Nominal `+2 rps`, saturation stress `+16.75 rps`, reversal `+15 -> -15 rps`의 3개 frozen scenario에서 Stage A와 Stage B가 모두 3/3 `PASS`였다. 모든 signal comparison에서 sample count와 time vector가 exact match했고 max absolute difference, RMS difference 및 differing sample count는 각각 `0`, `0`, `0`이었다. Interpolation, resampling 또는 SIL tolerance는 gate에 사용하지 않았다. (`results/source_derived_equivalence_v1/gate_summary.csv`, `stage_a_metrics.csv`, `stage_b_metrics.csv`)

| Artifact | Frozen SHA-256 before/after |
|---|---|
| Source `AS2308_MIL_Baseline_v3.slx` | `4A7FDC070506CA641ACBD2C3EFEA2FEF71DDCC150CA3FC1F20F191B8B998ED4D` |
| Derived `AS2308_SIL_B2B_Verification_v1.slx` | `0223B483023B87DE70FA440558AF651DF4B21DCD9B8C7095772A6CDFAB18D565` |

이 gate는 tested 3개 scenario와 비교 신호에 대해 source dynamics 및 observation interface의 exact preservation을 보인 것이다. 가능한 모든 state/input에 대한 보편적 equivalence 증명으로 확대 해석하지 않는다.

## 11. SIL Phase A Characterization

Phase A는 tolerance를 적용한 equivalence PASS/FAIL 단계가 아니라 numerical behavior characterization 단계였다. 세 scenario 모두 `EXECUTION_OK`, Normal/SIL execution success, exact time-grid equality를 기록하였다. (`results/sil_b2b_characterization_v1_1/characterization_summary.csv`)

| Scenario | Samples | Time grid | `Vcmd` max/RMS diff | `MotorSpeed` max/RMS diff | 관찰 |
|---|---:|---|---|---|---|
| `SIL-CHAR-001`, `+2 rps`, 1 s | 2,501 | Exact | `0 / 0 V` | `0 / 0 rps` | Nominal tracking |
| `SIL-CHAR-002`, `+16.75 rps`, 1 s | 2,501 | Exact | `0 / 0 V` | `0 / 0 rps` | Saturation sample 1개, `t=0`, saturation-region max diff 0 |
| `SIL-CHAR-003`, `+15 -> -15 rps`, 4 s | 10,001 | Exact | `0 / 0 V` | `0 / 0 rps` | First negative `Vcmd`: 2 s, MotorSpeed: 2.0036 s; transition-window max diff 0 |

Build evidence는 첫 1 s scenario에서 code generation/compile/relink, 두 번째 1 s scenario에서 unchanged executable reuse, 4 s reversal scenario에서 rebuild와 새 executable을 기록했다. 이는 numerical acceptance criterion이 아니라 build/reuse 재현성 evidence이다. (`results/sil_b2b_characterization_v1_1/build_reuse_evidence.txt`)

## 12. Numerical Tolerance Freeze

Phase A 이후, Phase B 실행 전에 Protocol v1.2에서 다음 criterion을 freeze하였다. (`docs/04_SIL_BackToBack_Protocol_v1.2.md`)

```text
scale(k) = max(1, abs(Model(k)), abs(SIL(k)))
tolerance(k) = 64 * eps(scale(k))
```

동일 sample index에서 `abs(Model(k)-SIL(k)) <= tolerance(k)`를 요구한다. Time-grid/sample-count mismatch는 output difference를 보간해 판정하지 않고 `EXECUTION_ERROR`로 처리한다.

Multiplier `64`는 이 프로젝트의 current frozen numerical environment에 사전 정의한 conservative machine-precision-scale margin이다. ISO 26262, A-SPICE, MathWorks 또는 다른 외부 표준이 요구한 값이 아니며, Phase A에서 observed difference가 0이라는 결과에 fitting해 도출한 값도 아니다. Exact equality를 future execution의 acceptance criterion으로 강제하지 않기 위해 정의한 margin이고, 제품 성능 tolerance가 아니다. Phase B 결과를 보고 이를 재조정하지 않았다.

## 13. Independent Phase B SIL Evaluation

Phase B input pool은 Manual 9개와 Official AI 9개, 총 18개 candidate였다. Phase A에서 사용한 Manual execution 3개는 ID와 scenario identity 기준으로 `SUPPLEMENTAL / NON-INDEPENDENT` 처리하였다. ID가 다른 추가 identity-only exclusion과 remaining duplicate는 없었고, independent set은 Manual 6개와 AI 9개, 총 15개로 확정되었다. (`results/sil_b2b_phase_b_v1/scenario_audit.csv`)

| Metric | Final result |
|---|---:|
| Candidate / Phase A exclusions / independent | 18 / 3 / 15 |
| Independent Manual / AI | 6 / 9 |
| PASS / FAIL / EXECUTION_ERROR | 15 / 0 / 0 |
| Worst `sampled_Vcmd` max absolute difference | `0 V` |
| Worst `sampled_MotorSpeed` max absolute difference | `0 rps` |
| Worst normalized numerical error | `0` |
| Tolerance-exceeding samples | `0` |
| Exact-equality executions | 15/15 |

모든 execution에서 Normal/SIL sample count, start/stop time과 time grid가 exact match했다. (`results/sil_b2b_phase_b_v1/evaluation_summary.csv`, `signal_metrics.csv`)

Build evidence에는 duration group `1, 2, 4, 8, 12 s`별 첫 execution에서 총 5회의 build activity가 기록되고, 같은 duration group의 이후 10개 execution에서는 executable이 재사용되었다. Numerical result와 build reuse는 별개의 evidence이다. (`results/sil_b2b_phase_b_v1/build_reuse_evidence.csv`)

검증 범위는 MATLAB R2023b / Simulink 23.2, Windows x86-64, Microsoft Visual C++ 2022, GRT (`grt.tlc`), `double`, fixed-step `ode4`, frozen source/derived model을 사용한 host SIL이다. Source와 derived hash는 execution 전후 모두 frozen value와 exact match했다. 이 `PASS`는 해당 host configuration과 15개 independent scenario에서의 Model-Code numerical equivalence를 의미한다.

## 14. Key Issues and Corrective Actions

1. **Tracking applicability 불일치** — Healthy/mutant 실행에서 applicability를 다시 계산하면 fault가 verification applicability를 회피할 수 있었다. Adjudication Protocol v1.0에서 healthy-baseline applicability를 freeze하고 corrected mutation results를 별도 versioned directory에 재생성하였다.
2. **Reversal 의미 불명확** — 초기 plateau와 reversal outcome이 같은 방식으로 집계되었다. Pre-reversal setup과 post-reversal outcome을 분리하고 repeated reversal에서 segment 1은 setup, 이후 5개 transition만 outcome으로 집계하였다.
3. **Mutation error 처리 차이** — Simulation/processing error를 kill로 볼 수 있던 초기 semantics를 폐기하고, healthy `PASS ->` mutant `FAIL`만 kill로 인정하였다. Inconclusive와 execution error는 kill에서 제외하였다.
4. **첫 SIL observability failure** — Code generation과 executable 실행은 성공했지만 continuous internal signal logging으로 `Vcmd`/`MotorSpeed`를 얻지 못했다. 이를 functional mismatch로 오판하지 않고 infrastructure `EXECUTION_ERROR`로 기록하였다.
5. **Derived verification architecture 도입** — Frozen source를 수정하는 대신 external root input과 non-feedback ZOH observation outputs만 가진 deterministic derived model을 만들었다.
6. **Derived-model 신뢰성 확보** — SIL 실행 전에 Stage A dynamic preservation과 Stage B observation fidelity exact gate를 추가하여 3개 characterization scenario에서 검증하였다.
7. **Tolerance circularity 방지** — 대표 3개 scenario를 Phase A로 사전 분리하고, criterion을 Phase B 전에 freeze한 뒤 remaining scenario identity로 independent evaluation을 수행하였다.

이 과정은 문제를 결과에서 숨기지 않고 원인, protocol correction, versioned result 및 재검증 evidence로 추적하도록 구성되었다.

## 15. Final Verification Summary

| Verification item | Final result | Primary evidence | Interpretation |
|---|---|---|---|
| Static Requirements | `REQ-BW-001`, `REQ-PI-001`, `REQ-AW-001` static PASS | `results/static_requirement_verification_v1/static_verification_summary.csv` | Frozen script/configuration/topology relation 확인; AW dynamic recovery PASS를 의미하지 않음 |
| MIL Healthy — Manual | 9/9 PASS | `results/manual_mutation_corrected_v1/Manual_Corrected_Healthy_Baseline.csv` | Frozen Manual dynamic executions가 corrected semantics에서 정상 동작 |
| MIL Healthy — AI | 9/9 PASS, inconclusive 0, error 0 | `results/ai_mutation_corrected_v1/AI_Corrected_Healthy_Baseline.csv` | Frozen Official AI executions가 동일 adjudication semantics에서 정상 동작 |
| Model Coverage | Execution 10/10, Decision 4/4; Condition/MC/DC N/A | `results/manual_suite_v1_coverage_summary.csv` | Applicable structural objectives fully exercised; defect absence 의미는 아님 |
| Mutation — Manual | 6/6 killed, 14/54 kill cells | `results/manual_mutation_corrected_v1/manual_mutation_summary.csv` | Frozen Manual Suite의 tested fault-detection evidence |
| Mutation — AI | 6/6 killed, 18/54 kill cells | `results/ai_mutation_corrected_v1/AI_Mutation_Summary.csv` | 같은 budget/fault set에서 4개 더 많은 kill cells; 일반화하지 않음 |
| Source-to-Derived Gate | Stage A 3/3 PASS, Stage B 3/3 PASS; all diffs 0 | `results/source_derived_equivalence_v1/` | Tested scenarios에서 dynamics와 observation interface exact preservation |
| SIL Phase A | 3/3 EXECUTION_OK; all max/RMS diffs 0 | `results/sil_b2b_characterization_v1_1/` | Characterization evidence; 당시 equivalence PASS/FAIL은 정의하지 않음 |
| SIL Phase B | 15/15 PASS, 0 FAIL, 0 error; exact equality 15/15 | `results/sil_b2b_phase_b_v1/` | Frozen host SIL environment와 independent scenarios에서 numerical equivalence 확인 |

주요 provenance commit은 unified mutation correction `5367241`, source-to-derived gate `26ed2db`, SIL observation validation `a51e339`, Phase A characterization `9205c76`, numerical criterion freeze `789cb7d`, independent Phase B verification `2a3ccf1`, final report baseline `1356440`, RTM/static evidence `90cd316`이다. (`git log --oneline`)

## 16. Limitations and Conclusion

본 evidence가 확인한 범위는 frozen controller configuration relation과 anti-windup topology, identified reduced-order plant를 사용한 requirements-based MIL behavior, DUT structural coverage, frozen controller mutations에 대한 detection, 두 9-execution Suite의 제한된 비교, 그리고 current host SIL configuration에서 generated-code numerical equivalence이다. Anti-windup dynamic recovery effectiveness는 공식 compliance PASS/FAIL 범위에 포함되지 않는다.

다음은 검증하지 않았다.

- 실제 Arduino Due 또는 production MCU execution
- Target compiler/MCU와 host generated code의 equivalence
- HIL 및 physical motor validation
- WCET 또는 400 us real-time deadline
- Interrupt scheduling
- ADC, PWM, encoder, CAN 및 실제 hardware I/O
- Current-loop, detailed electrical transient, thermal behavior
- 모든 possible input/state에 대한 수학적 equivalence
- 다른 model, requirement set 또는 mutation set으로의 Manual/AI 결과 일반화

결론적으로 이 repository는 frozen requirement와 environment에서 read-only static/configuration verification, 자동 반복 가능한 MIL verification, deterministic Oracle 판정, Coverage 및 Mutation 기반 Test Suite effectiveness 평가, 독립된 AI-assisted candidate generation/selection, 그리고 source traceability를 유지한 generated-code host SIL Back-to-Back verification을 하나의 재현 가능한 흐름으로 구축하였다. Manual과 AI Suite 모두 frozen six-mutant set을 100% 검출했다. AI Suite는 이 frozen experiment에서 18/54 kill cells를 기록해 Manual Suite의 14/54보다 4개 더 많은 kill cell을 만들었으며, 이는 해당 Suite, 해당 fault set 및 동일 9 top-level execution budget에 한정된 결과다. Source-to-derived gate, Phase A 및 independent Phase B에서는 required signals의 numerical difference가 모두 0이었으며 Phase B 15/15가 frozen criterion을 통과했다. 이 결론은 위에 명시한 model, scenarios, tools 및 host configuration 범위에 한정되며 AI의 일반적 우수성이나 모든 input/state에 대한 mathematical equivalence를 주장하지 않는다.
