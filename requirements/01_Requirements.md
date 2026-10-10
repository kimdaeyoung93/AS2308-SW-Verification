# AS2308 MIL Verification Requirements v1.1

| 항목 | 내용 |
|---|---|
| 문서 버전 | 1.1 |
| 문서 상태 | Frozen |
| 대상 | AS2308 BLDC Speed PI Controller MIL Verification |

## 1. Document Purpose

본 문서는 AS2308 BLDC Speed PI Controller의 MIL verification에 사용할 요구사항과 verification environment를 정의한다.

프로젝트의 DUT와 verification environment는 다음과 같다.

| 구분 | 정의 |
|---|---|
| DUT | Speed PI Controller |
| Verification Plant | `G(s) = 2185.96 / (s + 17.76)` |
| Reference Path | SpeedRef [rps] is applied to the Speed PI Controller after the required rps-to-rad/s unit conversion (`2*pi`), without a reference prefilter. |
| Simulation/control sample time | `0.0004 s` |

Verification Plant는 실제 AS2308 실험에서 voltage와 angular velocity 데이터를 취득하고 least-squares 방식으로 식별했던 1차 voltage-to-speed model을 재사용한 것이다.

## 2. Requirement Classification

본 문서의 requirement는 다음 두 종류로 구분한다.

| Classification | 정의 |
|---|---|
| Source-backed Requirement | 기존 AS2308 실습 코드 또는 강의자료에 직접 근거가 있는 requirement 또는 design constraint |
| Derived Functional Requirement | 원래 speed-control system의 기능 및 실험 시나리오로부터 verification을 위해 파생한 functional requirement |

Derived Functional Requirement는 원 제조사 또는 OEM의 공식 제품 requirement를 의미하지 않는다.

## 3. Source-backed Requirements

### 3.1 REQ-VOLT-001 — Controller Voltage Limitation

| 항목 | 내용 |
|---|---|
| Requirement ID | `REQ-VOLT-001` |
| Classification | Source-backed Requirement |
| Requirement | Speed controller의 output voltage command `Vcmd`는 `-12 V <= Vcmd <= +12 V` 범위를 벗어나지 않아야 한다. |
| Source | Existing AS2308 controller code의 `Vdc = 12` rated voltage 정의. Original PI controller Saturation block의 upper limit는 `Vdc`, lower limit는 `-Vdc`이다. |
| Rationale | Controller output은 기존 actuator/DC-bus 설계 한계 내로 제한되어야 한다. |
| Verification Method | Simulation 전체 구간의 `Vcmd` maximum과 minimum을 확인한다. |

### 3.2 REQ-BW-001 — Speed-loop Design Bandwidth

| 항목 | 내용 |
|---|---|
| Requirement ID | `REQ-BW-001` |
| Classification | Source-backed Requirement |
| Requirement | Project baseline의 Speed PI Controller는 `f_cs = 40 Hz` speed-loop design bandwidth를 기준으로 설계되어야 한다. |
| Source | 실제 project baseline script `AS2308_calculate_pi_control_cc.m`의 `f_cs = 40` 및 `w_cs = 2*pi*f_cs` 정의 |
| Rationale | `f_cs`는 기존 코드에서 speed loop의 bandwidth frequency design parameter로 명시되어 있다. |
| Verification Method | Controller parameter 및 PI gain 계산 관계를 확인한다. 필요한 경우 reference prefilter 없이 필수 rps-to-rad/s 단위변환 (`2*pi`)을 거치는 reference path의 controller characterization을 보조 증거로 사용할 수 있다. |

**Source Note:** 일부 강의자료 버전에는 `f_cs = 30 Hz`가 사용된 예제가 존재한다. 이번 프로젝트에서는 실제 사용한 baseline controller script의 값인 `40 Hz`를 project source of truth로 사용한다.

### 3.3 REQ-PI-001 — PI Gain Relationship

| 항목 | 내용 |
|---|---|
| Requirement ID | `REQ-PI-001` |
| Classification | Source-backed Requirement |
| Requirement | 식별 Plant `G(s) = b / (s + a)`에 대해 Speed PI Controller gain은 `Kps = w_cs / b`, `Kis = a * Kps` 관계를 따라야 한다. |
| Source | Original BLDC speed-control lecture의 pole-zero cancellation 기반 PI 설계와 existing controller script의 동일한 계산식 |
| Rationale | 식별된 first-order Plant와 기존 speed-loop design bandwidth를 이용해 원래 실습 방식과 동일한 PI controller를 구성한다. |
| Verification Method | 설정된 `Kps`, `Kis`를 식별된 `a`, `b`, `w_cs`에서 계산한 값과 비교한다. |

### 3.4 REQ-AW-001 — Anti-windup Compensation

| 항목 | 내용 |
|---|---|
| Requirement ID | `REQ-AW-001` |
| Classification | Source-backed Requirement |
| Requirement | Speed PI Controller에는 actuator saturation에 대응하는 anti-windup compensation이 적용되어야 한다. Project baseline에서는 기존 설계의 `Kas = Kis / Kps`를 사용한다. |
| Source | Existing controller script에서 `Kas`를 anti-windup feedback gain으로 정의한다. Original PI controller lecture/model에 anti-windup feedback 구조가 존재하며, 해당 gain을 zero로 설정하면 anti-windup을 disable할 수 있다. |
| Rationale | Saturation 발생 시 integrator windup을 억제하기 위한 기존 controller 기능을 보존한다. |
| Verification Method | Controller structure와 `Kas` parameter를 확인한다. 별도 saturation stress condition에서 recovery behavior를 관찰할 수 있으나, 자료에 근거 없는 특정 recovery-time threshold는 추가하지 않는다. |

## 4. Derived Functional Requirements

### 4.1 REQ-TRK-001 — Constant Speed Tracking

| 항목 | 내용 |
|---|---|
| Requirement ID | `REQ-TRK-001` |
| Classification | Derived Functional Requirement |
| Requirement | 일정한 valid speed reference가 유지되고 지속적인 actuator saturation이 발생하지 않는 경우, closed-loop motor speed는 해당 reference로 안정적으로 수렴해야 한다. |
| Source / Derivation | System의 목적이 closed-loop speed control이며, 기존 AS2308 실습에서 speed-reference tracking response를 실제로 확인했다. |
| Rationale | Closed-loop speed-control 기능이 일정한 reference에 대해 의도한 정상상태 동작을 형성하는지 확인한다. |
| Verification Method | Reference와 steady-state motor speed의 convergence를 확인한다. 특정 `steady-state error <= 1%`와 같은 수치는 원 자료에 없으므로 추가하지 않는다. |

### 4.2 REQ-DIR-001 — Bidirectional Speed Control

| 항목 | 내용 |
|---|---|
| Requirement ID | `REQ-DIR-001` |
| Classification | Derived Functional Requirement |
| Requirement | Positive speed reference에는 positive steady-state motor speed가 형성되어야 하며, negative speed reference에는 negative steady-state motor speed가 형성되어야 한다. |
| Source / Derivation | Original speed-control system이 signed reference를 사용하고 기존 실험에서도 positive/negative speed response를 사용했다. BLDC control material에서는 voltage/current sign과 rotation/torque direction을 구분한다. |
| Rationale | Signed speed reference에 따라 의도한 회전 방향의 정상상태 응답이 형성되는지 확인한다. |
| Verification Method | Non-zero reference와 steady-state speed의 sign을 비교한다. |

### 4.3 REQ-REV-001 — Direction Reversal

| 항목 | 내용 |
|---|---|
| Requirement ID | `REQ-REV-001` |
| Classification | Derived Functional Requirement |
| Requirement | 한 방향의 정상 운전 상태에서 speed reference의 sign이 반전되면, motor speed는 기존 방향에서 새로운 reference 방향으로 전환되고 안정적으로 수렴해야 한다. |
| Source / Derivation | Original AS2308 speed-control experiment에서 approximately `+15 rps <-> -15 rps` 형태의 반복적인 direction-reversal scenario를 사용했다. |
| Rationale | Signed reference가 운전 중 반전되는 기존 실험 시나리오에서 closed-loop 방향 전환과 최종 convergence를 확인한다. |
| Verification Method | Positive-to-negative와 negative-to-positive sequence를 실행하고 최종 회전 방향과 convergence를 확인한다. 특정 reversal settling-time threshold는 원 자료에 없으므로 추가하지 않는다. |

## 5. Verification Environment Constraints

아래 항목은 product performance requirement가 아니라 MIL verification에 사용할 frozen environment configuration이다.

### 5.1 ENV-SAMP-001 — Simulation and Control Sample Time

| 항목 | 내용 |
|---|---|
| Environment ID | `ENV-SAMP-001` |
| Configuration | Simulation/control sample time은 `ts = 0.0004 s`로 설정한다. |
| Source | Existing AS2308 controller 및 motor-identification script |

### 5.2 ENV-PLANT-001 — Verification Plant

| 항목 | 내용 |
|---|---|
| Environment ID | `ENV-PLANT-001` |
| Configuration | Verification Plant는 `G(s) = 2185.96 / (s + 17.76)`을 사용한다. |
| Source | Existing AS2308 experiment에서 voltage/angular-velocity data를 사용해 identification한 first-order model |

Plant는 speed-domain verification을 위한 reduced-order model이며 다음 항목은 검증 대상이 아니다.

- Current dynamics
- PWM switching
- Encoder dynamics
- Detailed electrical transient

### 5.3 ENV-REF-001 — Verification Reference Path

| 항목 | 내용 |
|---|---|
| Environment ID | `ENV-REF-001` |
| Configuration | MIL verification baseline에서는 SpeedRef [rps]에 정상적으로 필요한 rps-to-rad/s 단위변환 (`2*pi`)을 적용한 뒤 Speed PI Controller에 입력한다. reference prefilter는 verification path에 존재하지 않는다. |
| Source | Original AS2308 speed-control Simulink block diagram에는 `20 / (s + 20)` reference prefilter가 존재한다. 본 프로젝트에서는 SpeedRef가 필수 rps-to-rad/s 단위변환 (`2*pi`)만 거쳐 DUT인 Speed PI Controller에 입력되는 verification baseline을 사용한다. |
| Rationale | Speed PI Controller 자체의 tracking, transient response, actuator saturation 및 anti-windup behavior를 직접 검증하기 위함이다. |

기존 reference prefilter가 포함된 AS2308 실습 모델 자체를 잘못된 모델로 해석하지 않는다. 강의자료에서 해당 filter를 선택한 정확한 설계 목적이 명시적으로 확인되지 않았으므로 이를 추측하지 않으며, motor protection을 위해 사용됐다는 내용을 source-backed fact로 표현하지 않는다.

### 5.4 ENV-RANGE-001 — Nominal Verification Reference Range

| 항목 | 내용 |
|---|---|
| Environment ID | `ENV-RANGE-001` |
| Configuration | Nominal verification Test Case의 speed reference는 원칙적으로 `|SpeedRef| < 20 rps` 범위에서 구성한다. |
| Source | AS2308 open-loop experiment material에서 sampling condition을 고려하여 speed reference를 `20 rps` 미만으로 유지하도록 명시했다. |

**Notes:**

- `2.5 kHz` sampling에서 최소 12 samples/electrical revolution 기준 theoretical value는 약 `29.76 rps`이다.
- 24 samples/electrical revolution 권장 기준은 약 `14.88 rps`이다.
- 따라서 `+/-15 rps`는 기존 실습과 가까운 nominal verification point로 활용할 수 있다.
- `+/-15 rps`를 motor의 공식 rated speed 또는 제품 operating limit이라고 표현하지 않는다.
- 별도의 saturation stress verification에서는 anti-windup 및 actuator saturation behavior를 관찰하기 위해 nominal range와 구분된 stress condition을 사용할 수 있다.

## 6. Unsupported / Excluded Acceptance Criteria

다음 값들은 기존 강의자료 또는 코드에서 공식 requirement로 확인되지 않았으므로 Requirements v1.1에 포함하지 않는다.

| 제외 항목 | 처리 원칙 |
|---|---|
| Steady-state error `<= 1%` | Requirement 또는 acceptance criterion으로 사용하지 않는다. |
| Overshoot `<= 5%` | Requirement 또는 acceptance criterion으로 사용하지 않는다. |
| Settling time `<= 0.25 s` | Requirement 또는 acceptance criterion으로 사용하지 않는다. |
| Reversal settling time `<= 0.30 s` | Requirement 또는 acceptance criterion으로 사용하지 않는다. |

기존 characterization에서 측정한 settling time, overshoot 및 saturation threshold 등의 수치는 product requirement가 아니라 **Golden Baseline / Regression data**로만 취급한다.

## 7. Requirement Traceability Preparation

Manual Test Case와 AI-assisted Test Case를 추후 작성할 수 있도록 본 문서의 Requirement ID를 변경하지 않고 유지한다.

향후 traceability 구조는 다음과 같다.

```text
Requirement ID -> Test Case ID -> Execution Result -> Fault/Mutation Detection
```

Requirements v1.1은 AS2308 MIL verification의 requirement 및 environment baseline을 freeze하기 위한 문서다. Characterization 결과를 제품 사양으로 변환하지 않으며, 본 문서의 Derived Functional Requirement를 현대차, OEM 또는 ISO 26262의 공식 제품 requirement로 표현하지 않는다.

## 8. Revision Note

### v1.1

Reference prefilter를 verification path에서 제외하고 SpeedRef [rps]를 필수 rps-to-rad/s 단위변환 (`2*pi`) 후 Speed PI Controller에 입력하는 MIL baseline으로 변경했다. 기존 Requirement ID와 핵심 기능 요구사항은 유지한다.
