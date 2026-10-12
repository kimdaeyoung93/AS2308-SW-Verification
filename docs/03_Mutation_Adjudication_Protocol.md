# AS2308 Mutation Adjudication Protocol v1.0

| 항목 | 내용 |
|---|---|
| 문서 버전 | 1.0 |
| 문서 상태 | Frozen |
| 적용 대상 | Manual Dynamic MIL Suite v1.0 및 Official AI MIL Suite v1의 Mutation Testing |
| Mutation Set | `mutations/01_Mutation_Set.csv`에 정의된 frozen Primary Mutation Set 6개 |

## 1. 목적

이 문서는 Manual Suite와 AI Suite의 Mutation Testing에 동일한 adjudication semantics를 적용하기 위한 공통 판정 규칙을 정의한다.

이 protocol은 기존 결과를 어느 한쪽에 유리하게 만들기 위한 변경이 아니다. 서로 다른 runner에 존재하던 Tracking applicability, reversal precondition 및 execution error 처리의 불일치를 바로잡고, 동일한 의미의 상태와 mutation kill 규칙을 적용하기 위한 것이다.

기존 commit과 이전 결과는 삭제하지 않는다.

## 2. 공통 Mutation Kill Rule

Mutation kill은 healthy baseline에서 `PASS`한 동일한 frozen execution이 동일 input과 동일 Oracle 조건에서 mutant 적용 후 requirement evaluation `FAIL`이 된 경우에만 성립한다.

```text
Healthy PASS -> Mutant FAIL = KILL
```

다음 상태는 KILL로 계산하지 않는다.

- `INCONCLUSIVE_PRECONDITION`
- `EXECUTION_ERROR`
- `INVALID_MUTANT`

`EXECUTION_ERROR`는 mutant kill이 아니다. Verification harness 또는 simulation execution 문제로 별도 기록한다.

### 2.1 Healthy Baseline Acceptance Rule

Mutation execution을 시작하기 전에 동일한 adjudication protocol을 healthy baseline에 먼저 적용한다. Healthy baseline은 다음 조건을 모두 충족해야 한다.

- Frozen Suite의 9개 top-level execution이 모두 `PASS`여야 한다 (`9/9 PASS`).
- REQ-TRK-001 대상 Test Case와 plateau의 applicability가 확정되어야 한다.
- REQ-REV-001 대상 Test Case에서 요구되는 pre-reversal setup이 established되어야 한다.
- `EXECUTION_ERROR`가 0건이어야 한다.

위 조건 중 하나라도 충족하지 않으면 mutation execution을 시작하지 않는다. 이 acceptance rule은 mutant 결과를 해석하기 전에 healthy execution path와 precondition 상태가 정상적으로 성립했음을 확인하기 위한 consistency gate이다.

## 3. REQ-TRK-001 Applicability Rule

REQ-TRK-001은 일정한 valid reference가 유지되고 지속적인 actuator saturation이 발생하지 않는 경우 speed가 reference로 안정적으로 수렴할 것을 요구한다.

Tracking applicability는 mutant 실행마다 다시 판정하지 않고 healthy baseline에서 고정한다.

1. Healthy baseline에서 frozen Test Case의 각 평가 plateau에 대한 applicability를 판정한다.
2. Healthy baseline에서 `APPLICABLE`이며 Tracking Oracle이 `PASS`한 Test Case 또는 plateau는 mutation phase에서도 계속 `APPLICABLE`로 유지한다.
3. Mutant fault effect로 persistent actuator saturation이 발생하더라도 해당 Test Case 또는 plateau를 `INCONCLUSIVE_PRECONDITION`으로 변경하지 않는다.
4. 동일한 Tracking Oracle을 적용한다. 그 결과가 `FAIL`이면 mutant fault effect로 판정하며, 공통 kill rule에 따라 KILL로 기록한다.

이 규칙은 mutant가 자신의 fault effect로 verification applicability를 회피하는 것을 방지한다. Official AI Suite v1의 input magnitude와 input order는 변경하지 않는다.

Healthy-baseline-fixed applicability는 REQ-TRK-001의 원문을 변경하거나 새로운 제품 요구사항을 추가하는 규칙이 아니다. 이는 동일 frozen execution의 healthy/mutant 결과를 비교하기 위해 이 프로젝트의 Mutation Testing에서 사용하는 **project-specific adjudication convention**이다. 이 convention이 일반적인 모든 verification 또는 다른 프로젝트에도 동일하게 적용되는 보편 규칙이라고 주장하지 않는다.

### Tracking Applicability Detection

Healthy baseline의 각 REQ-TRK-001 evaluation plateau에 대해 terminal evaluation window `0.05 s`를 사용한다.

해당 window의 각 sample에서 다음 중 하나가 성립하면 그 sample을 clamp 상태로 판정한다.

Positive clamp:

- `raw_pi_output > +Vdc`
- `Vcmd`가 `+Vdc`에 clamp되어 있음

Negative clamp:

- `raw_pi_output < -Vdc`
- `Vcmd`가 `-Vdc`에 clamp되어 있음

`Vcmd`의 clamp 여부를 비교할 때는 기존 AI MIL runner와 동일한 machine-scale numerical tolerance를 사용한다.

```matlab
64 * eps(max([1; abs(Vcmd); Vdc]))
```

Terminal `0.05 s` window의 모든 sample이 positive clamp 또는 negative clamp 상태인 경우에만 `persistentClamp = true`로 판정한다. 하나 이상의 sample이 두 clamp 상태에 모두 해당하지 않으면 persistent terminal clamp가 아니며 해당 plateau는 `APPLICABLE`이다.

이 applicability detection은 healthy baseline에서만 수행하여 freeze한다. Mutation phase에서는 `persistentClamp`를 다시 계산하여 applicability를 변경하지 않는다.

Manual Suite와 AI Suite는 모두 이와 동일한 applicability detection semantics를 사용해야 한다. 별도의 saturation duration threshold를 추가하지 않으며 기존 Oracle threshold도 변경하지 않는다.

## 4. REQ-REV-001 Precondition Rule

REQ-REV-001은 한 방향의 정상 운전 상태에서 reference sign이 반전되면 motor speed가 새로운 방향으로 전환되고 안정적으로 수렴할 것을 요구한다. 따라서 reversal evaluation은 setup과 outcome의 두 단계로 구분한다.

### 4.1 Pre-reversal setup plateau

Pre-reversal plateau에 다음 기존 Oracle을 적용한다.

- Direction Oracle
- Tracking Oracle

두 Oracle이 모두 `PASS`해야 "한 방향의 정상 운전 상태"가 established된 것으로 판정한다.

Setup가 실패하면 해당 reversal transition은 `INCONCLUSIVE_PRECONDITION`이다. 이 경우 reversal requirement `FAIL`로 계산하지 않고, mutation KILL로도 계산하지 않는다.

Pre-reversal setup 판정은 기존 reversal simulation 안에 이미 존재하는 pre-reversal plateau에 Direction Oracle과 Tracking Oracle을 추가 적용하는 것이다. 별도의 simulation이나 새로운 top-level execution을 추가하지 않으므로 frozen 9 top-level execution budget은 유지된다.

### 4.2 Post-reversal plateau

Pre-reversal setup가 정상적으로 established된 경우에만 post-reversal plateau에 다음 기존 Oracle을 적용한다.

- Direction Oracle
- Tracking Oracle

두 Oracle 중 하나라도 `FAIL`이면 reversal outcome은 `FAIL`이다. 두 Oracle이 모두 `PASS`이면 reversal outcome은 `PASS`이다.

## 5. Repeated Reversal Rule

Repeated reversal scenario에서 segment 1은 초기 normal-operation setup plateau이다.

### 5.1 Segment 1

- Direction Oracle과 Tracking Oracle로 정상 운전 setup을 확인한다.
- Segment 1 자체는 reversal outcome으로 계산하지 않는다.

### 5.2 Segment 2 이후

각 transition에 대해 previous plateau가 Direction Oracle과 Tracking Oracle을 모두 통과하여 정상 운전 상태를 형성했는지 확인한다.

- Previous plateau가 정상 운전 상태를 형성한 경우: current plateau를 reversal outcome으로 평가한다.
- Previous plateau가 정상 운전 상태를 형성하지 못한 경우: 해당 transition은 `INCONCLUSIVE_PRECONDITION`이다.

각 valid reversal outcome은 post-reversal plateau의 Direction Oracle과 Tracking Oracle 결과로 판정한다.

Top-level aggregation은 다음 순서를 적용한다.

1. 하나 이상의 valid reversal outcome이 `FAIL`이면 top-level 결과는 `FAIL`이다.
2. `FAIL`은 없지만 하나 이상의 reversal transition이 precondition 미충족이면 top-level 결과는 `INCONCLUSIVE_PRECONDITION`이다.
3. 모든 required reversal transition이 `PASS`이면 top-level 결과는 `PASS`이다.

## 6. Execution Error Rule

Manual Suite와 AI Suite에 동일한 execution error 규칙을 적용한다.

다음과 같이 verification execution 자체가 정상적으로 완료되지 않은 경우 `EXECUTION_ERROR`로 기록한다.

- Simulation failure
- Required logged signal 누락
- Non-finite signal (`NaN` 또는 `Inf`)
- Oracle execution exception
- 기타 정상적인 requirement evaluation을 완료할 수 없는 harness 또는 execution 오류

`EXECUTION_ERROR`를 자동 KILL로 계산하지 않는다. 기존 Manual mutation runner의 "simulation error 또는 non-finite output을 KILL로 계산"하는 규칙은 이 protocol에 맞게 수정해야 하는 adjudication logic이다.

## 7. Oracle Rule

기존 Oracle 구현과 threshold는 변경하지 않는다.

| Oracle | 유지할 판정 정의 |
|---|---|
| `evaluate_tracking` | Evaluation window `0.05 s`, numerical-zero tolerance `1e-9 rps` |
| `evaluate_direction` | 기존 direction rule 유지 |
| `evaluate_voltage_limit` | `-12 V <= Vcmd <= +12 V` 기존 rule 유지 |

Mutation 결과에 맞추기 위해 Oracle threshold를 조정하지 않는다.

## 8. Test Budget 및 Fairness

| Suite | Frozen top-level execution budget |
|---|---:|
| Manual Dynamic MIL Suite v1.0 | 9 |
| Official AI MIL Suite v1 | 9 |

Manual/AI 비교에서는 **same 9 top-level execution budget**이라고 표현한다.

두 Suite의 waveform과 scenario 구성이 다를 수 있으므로 다음이 동일하다고 표현하지 않는다.

- Simulation time
- Segment count
- Computational effort

## 9. Frozen Items

다음 항목은 이 protocol 적용 과정에서 변경하지 않는다.

- Requirements v1.1
- Manual Test Cases
- Official AI Suite v1
- AI input values
- Frozen Mutation Set 6개
- Oracle thresholds
- AI Suite Selection Protocol
- 9 top-level execution budget

다음 항목만 이 protocol과 일치하도록 수정할 수 있다.

- Runner의 adjudication logic
- Result status handling
- Result reporting
- Oracle self-check test coverage

## 10. Result Status 및 Mutation Matrix Mapping

공통 status vocabulary는 다음과 같다.

- `PASS`
- `FAIL`
- `INCONCLUSIVE_PRECONDITION`
- `EXECUTION_ERROR`
- `INVALID_MUTANT`

Mutation matrix에는 다음 mapping을 적용한다.

| Mutant execution status | Mutation matrix value | Kill 여부 |
|---|---|---:|
| `PASS` | `PASS` | No |
| `FAIL` | `KILL` — healthy baseline이 `PASS`였던 경우 | Yes |
| `INCONCLUSIVE_PRECONDITION` | `INCONCLUSIVE` | No |
| `EXECUTION_ERROR` | `ERROR` | No |
| `INVALID_MUTANT` | `INVALID` | No; mutation score의 valid-mutant 분모에서 제외 |

## 11. Versioning 및 Result Authority

이 protocol 적용 전에 생성된 Mutation result는 삭제하지 않고 **superseded initial result**로 취급한다.

이 protocol의 모든 adjudication rule을 적용하여 다시 생성한 결과만 **Official Corrected Mutation Result**로 사용한다. Corrected result에는 적용한 protocol version을 식별할 수 있어야 하며, 이전 결과를 덮어써서 provenance를 제거하지 않는다.

Corrected mutation result는 기존 결과 디렉터리나 파일을 덮어쓰지 않고 별도의 versioned directory에 저장한다. v1 corrected result의 기본 저장 위치는 다음과 같다.

```text
results/manual_mutation_corrected_v1/
results/ai_mutation_corrected_v1/
```

후속 protocol version이 필요한 경우에도 동일한 방식으로 새로운 versioned directory를 사용하여 이전 결과와 corrected result의 provenance를 보존한다.

---

### Revision Note

v1.0: Manual/AI Mutation Testing에 공통 kill semantics, healthy-baseline-fixed Tracking applicability, REQ-REV setup precondition, repeated reversal aggregation, execution error 처리 및 result versioning 규칙을 최초 freeze함.
