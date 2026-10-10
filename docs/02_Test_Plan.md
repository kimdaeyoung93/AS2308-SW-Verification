# AS2308 AI-Assisted MIL Verification Test Plan v1.1

| 항목 | 내용 |
|---|---|
| 문서 버전 | 1.1 |
| 문서 상태 | Frozen |
| Verification Level | MIL (Model-in-the-Loop) |
| Requirements Source of Truth | `requirements/01_Requirements.md` |

## 1. Objective

본 프로젝트의 목적은 AS2308 BLDC Speed PI Controller를 대상으로 요구사항 기반 MIL verification 환경을 구축하고, Human-designed Test Case와 AI-assisted Test Case의 verification effectiveness를 동일 조건에서 비교하는 것이다.

비교의 핵심은 AI가 단순히 더 많은 Test Case를 생성하는지가 아니라 다음 항목을 정량적으로 평가하는 데 있다.

- Requirement Coverage
- Fault/Mutation Detection capability
- 생성된 AI Test Case의 유효성

AI/LLM은 최종 PASS/FAIL Oracle로 사용하지 않는다.

## 2. System Under Test and Verification Environment

본 Test Plan은 Requirements v1.1의 정의를 그대로 참조하며, 세부 근거는 `requirements/01_Requirements.md`를 source of truth로 사용한다.

| 항목 | 정의 |
|---|---|
| DUT | Speed PI Controller |
| Verification Level | MIL (Model-in-the-Loop) |
| Verification Plant | `G(s) = 2185.96 / (s + 17.76)` |
| Plant Origin | 실제 AS2308 실험에서 식별된 first-order voltage-to-speed model |
| Verification Reference Path | SpeedRef [rps] is applied to the Speed PI Controller after the required rps-to-rad/s unit conversion (`2*pi`), without a reference prefilter. |
| Sample Time | `0.0004 s` |
| Nominal Speed Reference Domain | 원칙적으로 `|SpeedRef| < 20 rps` |

Verification signal path는 다음과 같다.

```text
SpeedRef [rps]
  -> rps-to-rad/s unit conversion (2*pi)
  -> Speed PI Controller (DUT)
  -> G(s) = 2185.96 / (s + 17.76)
```

`2*pi` 블록은 rps를 rad/s로 변환하기 위해 유지되는 정상적인 필수 단위변환이며 reference prefilter가 아니다. 기존 AS2308 실습 모델의 `20 / (s + 20)` reference prefilter는 이번 MIL verification path에서 제외한다. 이는 기존 실습 모델의 타당성을 부정하는 것이 아니라 DUT인 Speed PI Controller의 tracking, transient response, actuator saturation 및 anti-windup behavior를 직접 검증하기 위한 baseline 결정이다.

### 2.1 Controller Design Constraints

- `Vdc = 12 V`
- Baseline speed-loop design bandwidth: `f_cs = 40 Hz`
- `Kps = w_cs / b`
- `Kis = a * Kps`
- `Kas = Kis / Kps`

## 3. Verification Scope

### 3.1 Included Scope

- Speed PI Controller configuration
- Constant speed tracking
- Positive/negative direction behavior
- Direction reversal
- Controller voltage limitation
- Speed-loop design parameter consistency
- Anti-windup configuration 및 saturation-related behavior
- Intentional Controller Fault/Mutation에 대한 Test Case 검출 능력

### 3.2 Excluded Scope

- Actual MCU execution timing
- Real ADC behavior
- PWM switching-level verification
- Actual encoder electrical behavior
- Current-loop verification
- Detailed BLDC electrical transient
- Thermal behavior
- HIL verification
- Physical motor validation

본 프로젝트를 HIL 또는 실제 차량 검증으로 표현하지 않는다.

## 4. Requirement Set

### 4.1 Frozen Requirements v1.1

| Requirement ID | Requirement Group |
|---|---|
| `REQ-VOLT-001` | Source-backed Requirement |
| `REQ-BW-001` | Source-backed Requirement |
| `REQ-PI-001` | Source-backed Requirement |
| `REQ-AW-001` | Source-backed Requirement |
| `REQ-TRK-001` | Derived Functional Requirement |
| `REQ-DIR-001` | Derived Functional Requirement |
| `REQ-REV-001` | Derived Functional Requirement |

### 4.2 Frozen Environment Constraints

| Environment ID |
|---|
| `ENV-SAMP-001` |
| `ENV-PLANT-001` |
| `ENV-REF-001` |
| `ENV-RANGE-001` |

Test Case 설계가 시작된 이후 Requirements v1.1은 변경하지 않는다. Requirement 변경이 불가피한 경우 기존 실험을 중단하고 새로운 document version으로 별도 관리한다.

## 5. Verification Method Classification

모든 Requirement를 동일한 방식의 dynamic Test Case로 검증하지 않는다. Requirement의 성격에 따라 Configuration/Static Verification과 Dynamic MIL Verification을 구분하여 사용한다.

### 5.1 Configuration / Static Verification

Controller parameter 또는 구조를 직접 확인하는 방식이다.

| 주요 대상 | Verification 예시 |
|---|---|
| `REQ-BW-001` | `f_cs` 설정 확인 |
| `REQ-PI-001` | PI gain 계산 관계 확인 |
| `REQ-AW-001` | `Kas` anti-windup feedback 구성 확인 |

### 5.2 Dynamic MIL Verification

실제 simulation input sequence를 실행하고 output behavior를 확인하는 방식이다.

| 주요 대상 | Verification 관점 |
|---|---|
| `REQ-VOLT-001` | Controller voltage limitation |
| `REQ-TRK-001` | Constant speed tracking behavior |
| `REQ-DIR-001` | Positive/negative direction behavior |
| `REQ-REV-001` | Direction-reversal behavior |
| 필요 시 `REQ-AW-001` | SpeedRef stimulus로 actuator saturation을 발생시키고 controller output인 `Vcmd`와 recovery behavior를 관찰한다. 특정 recovery-time threshold는 추가하지 않는다. |

### 5.3 Nominal Verification and Saturation Stress Verification

| 구분 | 적용 원칙 |
|---|---|
| Nominal verification | `ENV-RANGE-001`에 따라 원칙적으로 `|SpeedRef| < 20 rps`인 정상 검증 조건을 사용한다. |
| Saturation stress verification | Anti-windup 및 actuator saturation behavior를 관찰하기 위한 별도 stress condition으로 관리한다. 필요 시 nominal reference range 밖의 SpeedRef stimulus를 사용할 수 있다. |

`Vcmd`는 시험 입력이 아니라 Speed PI Controller의 output이다. Saturation stress verification에서는 SpeedRef 등의 stimulus로 actuator saturation을 유발하고 `Vcmd` 및 recovery behavior를 관찰한다. 근거가 없는 recovery-time acceptance threshold는 생성하지 않는다.

## 6. Manual Test Case Design Protocol

Manual Test Case는 사용자가 직접 설계한다. Manual Test Case 작성 중에는 AI가 실제 AS2308에 대한 구체적인 Test Case input 값이나 sequence를 제안하지 않는다.

### 6.1 Permitted Test Design Techniques

- Equivalence Partitioning
- Boundary Value Analysis
- State/Transition-based testing
- Sequence/Scenario testing

### 6.2 Test Budget

Executable Manual Test Case는 최대 20개로 제한한다. 단순히 20개를 채우기 위해 중복 Test Case를 추가하지 않는다.

### 6.3 Required Test Case Information

각 Manual Test Case는 최소한 다음 정보를 포함한다.

- Test Case ID
- Requirement ID
- Precondition
- Input/Steps
- Expected Result
- Test Design Technique

### 6.4 Manual Test Suite Freeze

Manual Test Case 작성 완료 후 test suite를 Freeze한다. Freeze 이후에는 AI 결과를 보고 Manual Test Case를 추가, 삭제 또는 수정하지 않는다.

## 7. AI-Assisted Test Case Design Protocol

AI는 Manual Test Case 내용을 제공받지 않는다.

### 7.1 Information Provided to AI

- 동일한 `01_Requirements.md`
- 동일한 verification environment
- 동일한 Test Case output schema
- 동일한 최대 실행 Test Budget

### 7.2 Candidate and Executable Test Budgets

| 구분 | 최대 개수 |
|---|---:|
| AI candidate Test Cases | 25 |
| 최종 executable AI Test Suite | 20 |

### 7.3 Validation and Human Review

AI candidate는 Validator와 Human Review를 통해 다음 항목을 확인한다.

- Schema valid 여부
- Requirement와 관련 있는지
- 실행 가능한 입력인지
- 명백한 duplicate인지
- Expected Result가 Requirement와 모순되지 않는지

Validator에서 탈락한 candidate를 보충하기 위해 억지로 추가 생성을 반복하지 않는다. 탈락한 Test Case와 탈락 사유도 결과에 기록한다.

## 8. Comparison Fairness Rules

Human과 AI Test Suite를 비교할 때 다음 조건을 동일하게 유지한다.

| 통제 항목 | 공통 조건 |
|---|---|
| Requirements | 동일한 Requirements v1.1 |
| DUT | 동일한 DUT |
| Plant | 동일한 Plant |
| Sample time | 동일한 sample time |
| Reference path | 동일한 prefilter-free reference path (`SpeedRef [rps] -> 2*pi unit conversion -> controller`) |
| Execution | 동일한 automated runner |
| Oracle | 동일한 PASS/FAIL Oracle |
| Faults | 동일한 Fault/Mutation Set |
| Executable Test Budget | 각 suite 최대 20개 |

AI가 Manual Test Case를 보거나 Manual Test Case가 AI 결과를 참고하지 않도록 한다. Test Case 설계 시 Fault/Mutation의 구체적인 내용은 제공하지 않으며, Fault/Mutation은 test design 단계와 독립적으로 평가한다.

## 9. PASS / FAIL Oracle

최종 PASS/FAIL 판정은 deterministic MATLAB logic으로 수행한다. LLM이 simulation 결과를 보고 PASS/FAIL을 판단하지 않는다.

Oracle은 frozen Requirement와 명시된 expected behavior만 사용하며, 근거가 없는 performance threshold를 새로 추가하지 않는다. 기존 characterization 결과는 Golden Baseline 또는 regression reference로 사용할 수 있으나 이를 OEM 또는 제품 specification으로 표현하지 않는다.

## 10. Fault / Mutation Evaluation Strategy

Test Suite 작성이 끝난 후 Controller에 intentional fault/mutation을 적용하여 각 suite의 fault detection capability를 평가한다. Mutation은 실제 software/control design mistake를 단순화한 형태로 구성한다.

### 10.1 Candidate Mutation Categories

- PI gain-related mutation
- Integral action-related mutation
- Anti-windup-related mutation
- Feedback magnitude-related mutation
- Feedback direction/sign-related mutation
- Actuator limitation-related mutation

현재 Test Plan에서는 정확한 mutation value를 확정하거나 Test Case별로 어떤 fault를 검출해야 하는지 작성하지 않는다. 정확한 Mutation Set은 Human/AI Test Suite가 Freeze된 뒤 별도 문서 또는 설정 파일로 관리한다.

Mutation 개수 목표는 약 6~8개다. 정상 baseline은 mutation이 아닌 control condition으로 별도 실행한다.

Plant parameter variation 또는 sensor noise와 같은 environment variation을 사용하는 경우 Controller software mutation과 구분하여 **Robustness Variation**으로 분류한다.

## 11. Evaluation Metrics

### 11.1 Requirement Coverage

전체 Requirement 중 하나 이상의 유효 Test Case 또는 verification activity와 연결된 Requirement 비율이다.

```text
Requirement Coverage = Covered Requirements / Applicable Requirements
```

Configuration/static verification과 dynamic Test Case coverage를 구분해서 표시할 수 있다.

### 11.2 Fault Detection Rate

Test Suite가 하나 이상의 Test Case를 통해 검출한 intentional mutation의 비율이며, 이번 프로젝트의 주요 비교 metric으로 사용한다.

```text
Fault Detection Rate = Detected Mutations / Total Mutations
```

### 11.3 AI Schema Valid Rate

```text
Schema Valid Rate = Schema-valid AI Candidates / Total AI Candidates
```

### 11.4 AI Human Acceptance Rate

```text
Human Acceptance Rate = Accepted AI TCs / Reviewed AI Candidates
```

### 11.5 AI Duplicate Rate

동일한 Requirement, 사실상 동일한 input condition 및 동일한 expected behavior를 반복하는 candidate를 duplicate로 분류한다.

```text
Duplicate Rate = Duplicate Candidates / Total AI Candidates
```

Duplicate 판정 기준은 결과 보고서에 기록한다.

### 11.6 Test Design Time

Human Test Case 설계 시간과 AI generation 및 validation/review 시간을 기록할 수 있다. 이 metric은 특정 수행자와 환경에 종속되는 secondary case-study metric으로만 사용하며, 일반적인 생산성 향상률 또는 산업 전체에 적용 가능한 결과로 일반화하지 않는다.

## 12. Traceability

최종적으로 다음 traceability chain을 구성한다.

```text
Requirement
  -> Test Case
  -> Execution
  -> PASS/FAIL
  -> Fault/Mutation Detection
```

Manual과 AI Test Case는 별도 ID namespace를 사용한다.

| Test Suite | ID Namespace |
|---|---|
| Manual | `MTC-XXX` |
| AI-assisted | `ATC-XXX` |

Requirement ID는 `requirements/01_Requirements.md`의 값을 그대로 사용한다.

## 13. Experiment Order

실험은 다음 순서로 수행한다.

1. Requirements v1.1 Freeze
2. Test Plan v1.1 Freeze
3. Manual Test Case 작성
4. Manual Test Suite Freeze
5. AI Candidate Test Case 생성
6. AI Validator/Human Review
7. AI Test Suite Freeze
8. Fault/Mutation Set 확정
9. Automated MIL execution
10. Manual vs AI quantitative comparison
11. Verification Report 작성

한쪽 Test Suite에 유리하도록 실험 순서를 임의로 변경하지 않는다.

## 14. Deliverables

최종 프로젝트 산출물은 다음과 같다.

- `requirements/01_Requirements.md`
- `docs/02_Test_Plan.md`
- `tests/03_Manual_Test_Cases.csv`
- `tests/04_AI_Test_Cases.csv`
- Automated MIL runner
- Validator
- Mutation/Fault configuration
- Simulation results
- `docs/05_Verification_Report.md`
- Project `README.md`
