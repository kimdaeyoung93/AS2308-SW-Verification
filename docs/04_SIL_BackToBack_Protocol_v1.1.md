# AS2308 SIL Back-to-Back Verification Protocol v1.1

| 항목 | 내용 |
|---|---|
| 문서 버전 | v1.1 |
| 문서 상태 | Frozen |
| Verification Level | Host SIL Back-to-Back Characterization / Equivalence Verification |
| Source Model | `model/AS2308_MIL_Baseline_v3.slx` |
| Source Model SHA-256 | `4A7FDC070506CA641ACBD2C3EFEA2FEF71DDCC150CA3FC1F20F191B8B998ED4D` |
| Primary Architecture | Continuous closed-loop derived verification model executed as top-model SIL |
| Initial Code-Generation Target | Current GRT configuration, Windows x86-64 |

## 1. Objective

본 protocol revision은 frozen MIL source model과 Simulink Coder로 생성된 C implementation 사이의 closed-loop functional/numerical equivalence를 characterization하기 위한 실행 architecture를 보완한다.

MIL requirement verification과 SIL Back-to-Back verification은 서로 다른 verification objective를 가진다.

- MIL requirement verification은 controller와 verification environment의 동작이 Requirement 및 Oracle을 만족하는지 확인한다.
- SIL Back-to-Back verification은 Simulink model과 generated C implementation이 동일 조건에서 기능적·수치적으로 동등하게 동작하는지 확인한다.
- SIL Back-to-Back `PASS`는 generated implementation의 model equivalence를 의미하며, 그 자체를 product requirement `PASS`로 해석하지 않는다.
- 기존 MIL Requirement, Test Case, Oracle, threshold 및 corrected MIL result는 SIL equivalence를 위해 변경하거나 재해석하지 않는다.

현재 v1.1 Draft에서도 numerical tolerance는 정의하지 않는다. Healthy Model/SIL 결과를 Phase A에서 characterization한 후 별도 protocol revision에서 project-specific B2B tolerance를 freeze한다.

## 2. Why v1.1 Exists

v1.0 protocol에 따른 첫 Phase A 실행 시도에서 다음 사실이 확인되었다.

- GRT C code generation이 성공했다.
- SIL standalone executable build가 성공했다.
- SIL application이 정상적으로 시작되고 종료되었다.
- Required comparison signals인 `Vcmd`와 `MotorSpeed`는 continuous sample-time internal signals였다.
- 선택한 top-model SIL internal signal-logging interface는 해당 continuous signals를 기록하지 못했다.
- Runner가 comparison signals를 확보하지 못하여 characterization execution은 `EXECUTION_ERROR`로 종료되었다.
- Scenario마다 model 내부 Constant, Pulse Generator 및 Manual Switch 관련 parameter를 변경하여 generated-code rebuild가 반복되었다.

이 결과는 controller functional failure 또는 Model-Code numerical mismatch가 아니다. Verification observability 및 stimulus architecture가 Phase A characterization 목적에 적합하지 않았던 infrastructure failure이다.

첫 v1.0 attempt는 다음과 같이 기록한다.

> Code generation and SIL executable execution succeeded, but characterization could not be completed because required continuous internal signals were not observable through the selected SIL signal-logging interface.

이 결과를 equivalence `PASS`, equivalence `FAIL` 또는 Model-Code mismatch로 표현하지 않는다.

## 3. Baseline and Frozen Source

### 3.1 Source Baseline

SIL Back-to-Back source baseline은 다음과 같다.

- Model: `model/AS2308_MIL_Baseline_v3.slx`
- SHA-256: `4A7FDC070506CA641ACBD2C3EFEA2FEF71DDCC150CA3FC1F20F191B8B998ED4D`
- Solver type: Fixed-step
- Solver: `ode4`
- Fixed step: `ts = 0.0004 s`
- Numerical datatype: `double`
- Controller integrator: continuous-time Integrator
- MIL model and corrected MIL results: frozen

Frozen source model은 직접 수정하거나 SIL instrumentation을 저장하지 않는다.

### 3.2 R2023b SIL Architecture Constraint

R2023b SIL/PIL architecture에는 다음 제약을 적용한다.

- Top-model SIL/PIL은 component 내부의 continuous sample time을 지원한다.
- SIL/PIL component boundary의 continuous sample time은 지원하지 않는다.
- Model-block SIL/PIL은 continuous sample time을 지원하지 않는다.

따라서 continuous closed-loop dynamics를 포함한 verification model을 Model block SIL로 실행하지 않는다. v1.1의 primary architecture는 반드시 **continuous closed-loop derived verification model 전체를 top-model SIL로 실행하는 구조**를 사용한다.

## 4. Revised Primary Architecture

### 4.1 Derived Top-Model SIL Verification Model

Frozen source를 기반으로 deterministic generation script가 derived top-model SIL verification model을 생성한다. 수동 편집된 derived model을 source of truth로 사용하지 않는다.

Derived model 전체를 top-model SIL로 실행하며 Model-block SIL은 사용하지 않는다.

```text
External sampled SpeedRef input (ts)
               |
               v
       Speed PI Controller
               |
             Vcmd
               |
       Identified Plant
               |
          MotorSpeed
               +---------------- feedback

Observation-only branches:
Vcmd ------> Zero-Order Hold(SampleTime=ts) ------> sampled_Vcmd root output
MotorSpeed -> Zero-Order Hold(SampleTime=ts) -----> sampled_MotorSpeed root output
```

Closed-loop dynamics는 다음과 같이 유지한다.

- Speed PI Controller의 proportional path 유지
- Continuous Integrator 유지
- Anti-windup path 유지
- Voltage saturation 유지
- Identified continuous plant 유지
- Feedback polarity와 scaling 유지
- Fixed-step `ode4` solver 유지
- `FixedStep = ts = 0.0004 s` 유지
- `double` datatype 유지

결과는 다음과 같이 표현한다.

> Continuous closed-loop model versus generated-code top-model SIL back-to-back verification

Derived model에 verification interface가 포함되므로 결과를 standalone controller implementation verification으로 표현하지 않는다.

### 4.2 Model-Block SIL Exclusion

이전 검토에서 제안된 continuous closed-loop component의 Model-block SIL 실행 구조는 폐기한다. 이유는 Model-block SIL boundary가 continuous sample time을 지원하지 않아 현재 controller와 plant의 continuous dynamics를 그대로 보존하는 primary architecture가 될 수 없기 때문이다.

## 5. Observation Interface

### 5.1 Observation-Only Sampling

Continuous `Vcmd`와 `MotorSpeed`를 SIL boundary에 직접 연결하지 않는다. 각 신호에서 control/feedback path와 독립적인 observation-only branch를 생성한다.

```text
continuous Vcmd
       |
       +------------------------------> Plant
       |
       +--> Zero-Order Hold(SampleTime=ts)
                    |
                    +--> sampled_Vcmd root output

continuous MotorSpeed
       |
       +------------------------------> Controller feedback
       |
       +--> Zero-Order Hold(SampleTime=ts)
                    |
                    +--> sampled_MotorSpeed root output
```

Observation sampler는 Simulink Zero-Order Hold block으로 고정한다. 각 Zero-Order Hold의 `SampleTime`은 `ts = 0.0004 s`이다. `t = 0`에서 Zero-Order Hold output은 해당 시점의 input과 같아야 한다는 semantics를 사용한다.

Observation branch에는 다음 제약을 적용한다.

- Controller 또는 plant 계산으로 되돌아가는 feedback을 만들지 않는다.
- Zero-Order Hold는 observation branch에만 존재하며 controller/plant feedback path에는 삽입하지 않는다.
- 기존 signal의 source, destination, datatype 및 dynamic path를 변경하지 않는다.
- Observation state 또는 sampled output이 controller/plant state update에 영향을 주지 않는다.
- Model 및 SIL에서 동일한 observation definition을 사용한다.
- Primary comparison에는 sampled root outputs만 사용한다.

Primary signal은 `sampled_Vcmd`, secondary signal은 `sampled_MotorSpeed`이다. `raw_pi_output`은 동일한 observation-only interface로 안정적으로 노출할 수 있는 경우에만 diagnostic signal로 추가하며, primary characterization 완료 조건으로 요구하지 않는다.

### 5.2 Semantic Statement

`0.0004 s` observation sampling은 controller execution period를 의미하지 않는다. Controller는 계속 continuous Integrator와 fixed-step ODE4로 실행되며, observer는 solver major grid에서 comparison evidence를 취득하기 위한 verification instrumentation이다.

다음 표현은 사용하지 않는다.

- `400 us discrete controller SIL`
- `400 us controller execution SIL`

허용하는 표현은 다음과 같다.

- `Major-grid observation based Model-Code SIL equivalence`
- `Continuous closed-loop model versus generated-code top-model SIL back-to-back verification`

## 6. Externalized Test Stimulus

### 6.1 Purpose

Frozen source model 내부의 Constant, Pulse Generator 및 Manual Switch 기반 stimulus는 scenario에 따라 generated-code parameter 또는 source가 달라져 rebuild를 유발할 수 있다. Derived verification model에서는 test stimulus를 generated closed-loop algorithm과 분리한다.

Generated closed-loop dynamics와 observation interface는 scenario 사이에서 동일하게 유지하고, SpeedRef waveform만 외부 input data로 변경한다.

Top-model SIL boundary의 continuous sample time은 사용하지 않는다. SpeedRef root input은 명시적인 supported discrete sample time `ts = 0.0004 s`로 구성한다.

이 input interface는 test stimulus 전달을 위한 verification interface이며 controller를 discrete controller로 재정의하지 않는다. 기존 source model의 정상적인 `rps-to-rad/s` unit conversion과 이후 continuous closed-loop dynamics는 그대로 유지한다.

### 6.2 Frozen Characterization Set

| ID | Frozen Source Scenario | Externalized Waveform | Duration |
|---|---|---|---:|
| `SIL-CHAR-001` | Manual MTC-002 / IT-001 | `+2 rps` | `0–1 s` |
| `SIL-CHAR-002` | Manual MTC-001 / IT-001 | `+16.75 rps` | `0–1 s` |
| `SIL-CHAR-003` | Manual MTC-004 / IT-001 | `+15 rps` for `0–2 s`, then `-15 rps` for `2–4 s` | `0–4 s` |

Input magnitude, transition time, segment order, duration 및 initial reference semantics를 변경하지 않는다. Implementation 단계에서 externalized input vector가 기존 Manual runner의 frozen waveform definition과 동일한지 assertion으로 확인한다.

## 7. Source-to-Derived Equivalence Gate

SIL comparison 전에 다음의 명시적인 2-stage equivalence gate를 순서대로 수행한다. 두 stage 모두 SIL B2B numerical tolerance를 사용하지 않으며 interpolation, resampling 및 tolerance 적용을 금지한다.

### 7.1 Stage A — Dynamic Preservation

Frozen Source Normal의 internal continuous signals와 Derived Verification Model Normal의 internal continuous signals를 동일 fixed-step major-time grid에서 비교한다.

```text
Frozen Source Normal internal continuous Vcmd
              versus
Derived Normal internal continuous Vcmd

Frozen Source Normal internal continuous MotorSpeed
              versus
Derived Normal internal continuous MotorSpeed
```

양쪽에 동일한 characterization waveform과 동일한 parameter, initial state, solver, fixed step 및 stop time을 적용한다. 각 signal에 대해 다음 조건을 모두 만족해야 한다.

- Sample count exact match
- Time vector exact match
- 동일 sample index의 numeric value exact match

Stage A는 internal stimulus의 external input interface 전환과 derived model 생성이 original continuous closed-loop dynamics를 변경하지 않았음을 확인한다.

### 7.2 Stage B — Observation Fidelity

Derived Normal의 internal continuous signal major-grid values와 동일 execution의 sampled root output을 비교한다.

```text
Derived Normal internal continuous Vcmd major-grid values
              versus
Derived Normal sampled_Vcmd root output

Derived Normal internal continuous MotorSpeed major-grid values
              versus
Derived Normal sampled_MotorSpeed root output
```

각 signal pair에 대해 다음 조건을 모두 만족해야 한다.

- Sample count exact match
- Time vector exact match
- 동일 sample index의 numeric value exact match

Stage B는 observation-only Zero-Order Hold와 sampled root output interface가 major-grid values를 정확하게 보존함을 확인한다. `t = 0` sample도 exact comparison에 포함한다.

### 7.3 Gate Outcome

Stage A와 Stage B가 모두 exact equivalence를 만족한 경우에만 Source-to-Derived Equivalence Gate를 통과한다.

이 gate의 목적은 다음 derived transformation이 original closed-loop behavior를 변경하지 않았음을 확인하는 것이다.

- Internal stimulus의 external input interface 전환
- Observation-only Zero-Order Hold branch 추가
- Sampled root output interface 추가

Stage A 또는 Stage B가 정상 실행되었으나 required exact equivalence를 만족하지 못하면 `DERIVATION_MISMATCH`로 기록하고 SIL Phase A를 시작하지 않는다.

Source integrity/hash 문제, model generation failure, simulation failure, signal collection failure 또는 time-grid construction/alignment failure로 data comparison 자체를 정상 수행할 수 없으면 `EXECUTION_ERROR`로 기록하고 SIL Phase A를 시작하지 않는다.

이 gate에는 SIL B2B numerical tolerance 또는 product performance threshold를 사용하지 않는다.

## 8. SIL Phase A Characterization

Source-to-derived equivalence gate 통과 후 다음 execution을 비교한다.

```text
Derived Verification Model — Normal
              versus
Derived Verification Model — Top-Model SIL
```

Phase A에서는 numerical equivalence `PASS` 또는 `FAIL`을 판정하지 않는다. Numerical tolerance는 아직 정의하지 않는다.

각 characterization scenario와 comparison signal에 대해 최소 다음 metric을 수집한다.

- Time-grid equality
- Sample count
- Maximum absolute difference
- RMS difference
- First differing sample index and time
- Time of maximum difference
- `sampled_Vcmd` difference
- `sampled_MotorSpeed` difference
- 해당되는 saturation interval difference
- 해당되는 reversal/sign-change interval difference

### 8.1 Time-Grid and Sample Alignment

Model과 SIL은 동일한 fixed-step major-time grid를 생성해야 한다. Numerical output comparison 전에 다음 조건을 확인한다.

- Sample count 동일
- Start time 동일
- Stop time 동일
- 각 logged sample time이 동일하거나 machine representation 수준에서 동일

Interpolation, resampling 및 extrapolation으로 time grid를 맞추는 행위는 금지한다. Time-grid mismatch로 동일 sample index comparison이 불가능하면 output difference를 계산하기 전에 configuration mismatch를 조사하고 execution을 `EXECUTION_ERROR`로 기록한다.

Time-grid alignment가 확인된 뒤 다음과 같이 비교한다.

```text
difference(k) = model_signal(k) - sil_signal(k)
```

### 8.2 Saturation and Reversal Analysis

Saturation stress scenario에서는 Model과 SIL의 saturation 진입·종료 구간과 해당 구간의 sample-wise difference를 기록한다. 이를 위해 새로운 product saturation threshold를 만들지 않는다.

Reversal scenario에서는 reference transition 주변의 `Vcmd`와 `MotorSpeed` difference, sign-change sample 및 difference의 증가·감소 양상을 기록한다. 새로운 settling-time 또는 overshoot requirement를 추가하지 않는다.

## 9. Characterization and Evaluation Separation

v1.0에서 freeze된 separation을 유지한다.

- Phase A Characterization Set은 Section 6.2의 3개 frozen Manual scenario이다.
- 이 3개 scenario에서 healthy Model/SIL numerical difference를 측정한다.
- 결과 검토 후 별도 protocol revision에서 project-specific B2B tolerance를 freeze한다.
- 이후 나머지 frozen Manual/AI scenario를 independent Evaluation Set으로 실행한다.
- Characterization scenario는 최종 표에 참고용으로 포함할 수 있지만 tolerance의 독립 검증 근거로 표현하지 않는다.
- Evaluation result를 사용하여 이미 freeze된 tolerance를 다시 조정하지 않는다.

이 구조는 Manual Suite와 AI Suite의 effectiveness를 비교하기 위한 것이 아니므로 suite 간 동일 scenario 개수나 total duration을 요구하지 않는다.

## 10. Build Reuse Objective

Characterization 3개 scenario에 대한 목표는 generated closed-loop algorithm full build 1회이다.

초기 build 이후에는 다음 항목을 변경하지 않는다.

- Controller 및 plant blocks
- Controller/plant parameters
- Solver configuration
- Fixed step
- Observation interface
- Root input/output interface
- Code-generation configuration

Scenario 사이에서는 external SpeedRef input data와 top-level execution duration만 변경한다. Implementation 전에 R2023b top-model SIL의 build reuse, incremental build 및 runtime input 적용 방식을 실제 configuration에서 확인한다.

Full build 1회가 해당 top-model SIL architecture에서 기술적으로 불가능하면 검증되지 않은 우회 방법을 적용하지 않는다. 대신 다음 evidence를 implementation note에 기록한다.

- 실제 rebuild trigger
- Scenario별 generated source 또는 parameter checksum 변화
- 가능한 최소 full-build/relink 횟수
- Build artifact 재사용이 불가능한 기술적 이유

Build 횟수는 product requirement가 아니라 verification infrastructure objective이다.

## 11. Integrity and Traceability

### 11.1 Deterministic Derivation

Derived verification model은 deterministic generation script로 생성한다. 예정된 generator는 다음과 같다.

`runner/build_sil_b2b_verification_model.m`

Generator는 frozen source model을 입력으로 사용하고 source model을 저장하거나 덮어쓰지 않는다.

### 11.2 Derivation Manifest

Derivation manifest에는 최소 다음을 기록한다.

- Source path
- Source SHA-256
- Derived path
- Protocol version
- Allowed transformations
- Controller parameters: `Kps`, `Kis`, `Kas`, `Vdc`, `ts`
- Plant parameters
- Solver and FixedStep
- Observation sample time
- Input/output interface definition
- MATLAB/Simulink release
- Generation timestamp

Allowed transformations는 다음으로 제한한다.

- Internal scenario source를 supported discrete root input interface로 대체
- `Vcmd` 및 `MotorSpeed`의 observation-only branch에 `SampleTime = ts`인 Zero-Order Hold 추가
- Sampled observation root outputs 추가
- Verification-only naming 및 logging configuration 추가

Controller dynamics, plant dynamics 또는 solver semantics를 변경하는 transformation은 허용하지 않는다.

### 11.3 Reproducibility Metadata

각 characterization result에는 최소 다음 metadata를 기록한다.

- MATLAB / Simulink release
- `SystemTargetFile`
- Solver
- Fixed step
- Datatype
- Host platform
- Compiler/toolchain
- Source model SHA-256
- Derived model identity/hash
- Generated-code checksum 또는 artifact identity
- `Kps`, `Kis`, `Kas`, `Vdc`, `ts`
- Observation sample time
- Scenario identifier

이 metadata는 product requirement나 acceptance criterion이 아니라 B2B 재현성 및 traceability 정보이다.

### 11.4 Source Integrity

실행 전후 frozen source model SHA-256을 확인한다. Hash mismatch가 발생하면 generation 또는 execution을 시작하지 않고 `EXECUTION_ERROR`로 기록한다. Generated artifacts, derived model, reports 및 results는 source model과 기존 MIL evidence를 덮어쓰지 않는 별도 directory에 저장한다.

## 12. Frozen Items

다음 항목은 변경하지 않는다.

- `model/AS2308_MIL_Baseline_v3.slx`
- Source SHA-256
- Controller structure and dynamics
- Plant structure and dynamics
- Continuous Integrator
- Fixed-step ODE4 semantics
- `Kps`, `Kis`, `Kas`, `Vdc`, `ts`
- Requirements
- Manual Test Cases
- Official AI Test Cases
- Existing Oracles and thresholds
- Primary Mutation Set and mutation results
- Corrected MIL results
- Frozen waveform magnitude, transition and duration semantics
- v1.0 Frozen protocol document

## 13. Execution and Evaluation Status

### 13.1 Characterization Phase

Tolerance freeze 전에는 다음 상태만 사용한다.

| Status | Definition |
|---|---|
| `EXECUTION_OK` | Source-to-derived gate와 required Model/SIL execution 및 difference measurement가 정상 완료됨. Numerical PASS/FAIL은 아직 판정하지 않음. |
| `DERIVATION_MISMATCH` | Source-to-Derived Stage A 또는 Stage B가 정상 실행되었으나 required exact equivalence를 만족하지 못함. SIL Phase A를 시작하지 않음. |
| `EXECUTION_ERROR` | Source integrity/hash 문제, model generation/build failure, simulation failure, signal collection failure 또는 time-grid construction/alignment failure로 required data comparison을 정상 수행할 수 없음. |
| `NOT_EVALUATED` | Optional diagnostic signal 또는 해당 분석이 수행되지 않았음. |

`EXECUTION_OK`를 equivalence `PASS`로 표현하지 않는다.

`DERIVATION_MISMATCH`는 실제 data comparison mismatch이며 infrastructure error가 아니다. `EXECUTION_ERROR`는 정상적인 data comparison 자체를 수행할 수 없는 infrastructure 또는 execution failure에만 사용한다.

### 13.2 Tolerance Freeze 이후

Numerical tolerance가 별도 revision에서 freeze된 이후에만 `PASS`, `FAIL`, `EXECUTION_ERROR` 상태를 사용한다.

## 14. Limitations

이 protocol의 SIL은 Windows x86-64 host에서 실행하는 generated-code equivalence verification이다. 다음 항목은 검증하지 않는다.

- Arduino Due execution
- WCET 또는 `400 us` real-time deadline
- MCU interrupt scheduling and latency
- ADC
- PWM
- Encoder acquisition, quantization and hardware timing
- CAN
- 실제 MCU architecture 및 target compiler equivalence
- Target hardware I/O 및 peripheral integration
- HIL

Observation sampling period가 `0.0004 s`라는 사실을 real-time deadline 검증으로 해석하지 않는다.

## 15. Design Decisions

1. Continuous closed-loop derived verification model 전체를 top-model SIL로 실행한다.
2. Continuous sample-time을 지원하지 않는 Model-block SIL architecture는 사용하지 않는다.
3. Frozen source model은 수정하지 않고 deterministic generator로 derived model을 생성한다.
4. Controller와 plant의 continuous dynamics 및 ODE4 semantics를 유지한다.
5. Continuous comparison signals는 control path와 독립적인 Zero-Order Hold observation branch에서 `SampleTime = ts`로 sampling하여 supported discrete root outputs로 노출한다.
6. Internal stimulus blocks를 external discrete root input으로 대체하여 scenario data와 generated algorithm을 분리한다.
7. Source-to-derived Normal equivalence gate를 Stage A Dynamic Preservation과 Stage B Observation Fidelity로 나누어 SIL Phase A보다 먼저 수행한다.
8. Phase A에서는 numerical difference만 characterization하고 tolerance를 정의하지 않는다.
9. Interpolation 없이 동일 time grid와 sample index로 비교한다.
10. 3개 characterization scenario에 대해 full algorithm build 1회를 목표로 하되 R2023b에서 확인되지 않은 우회는 사용하지 않는다.

## 16. Open Technical Risks

Implementation 전에 다음 사항을 확인해야 한다.

1. Zero-Order Hold observation output이 `t = 0`을 포함한 모든 major-grid sample에서 internal continuous signal과 exact alignment를 유지하는가?
2. Derived root input의 discrete timing과 source Constant/Pulse/Manual Switch waveform이 transition sample을 포함해 동일한가?
3. Top-model SIL root output이 `sampled_Vcmd` 및 `sampled_MotorSpeed`를 안정적으로 반환하는가?
4. External input data 또는 stop time 변경이 R2023b top-model SIL에서 full regeneration을 유발하는가?
5. Full build 1회 후 동일 executable 또는 generated code를 3개 scenario에 재사용할 수 있는가?
6. Source-to-derived 2-stage exact comparison evidence를 어떤 형식으로 저장할 것인가?
7. Observer 및 interface 추가가 generated-code optimization과 logging configuration에서 제거되지 않도록 어떤 설정이 필요한가?
8. Generated artifacts와 derived model의 immutable identity를 어떤 checksum schema로 기록할 것인가?
9. Optional `raw_pi_output` diagnostic output을 primary interface나 control behavior 변경 없이 안정적으로 보존할 수 있는가?

본 문서는 **v1.1 Frozen**이다. Phase A characterization 완료 전까지 architecture, equivalence gate, characterization set 및 execution semantics를 변경하지 않는다.

## Revision Note

### v1.1 Frozen

- v1.0 첫 Phase A attempt의 observability 및 repeated-build limitation을 기록했다.
- Continuous closed-loop derived verification model을 top-model SIL로 실행하는 architecture로 개정했다.
- Model-block SIL architecture를 폐기했다.
- Observation-only major-grid sampling과 supported discrete root output interface를 정의했다.
- Frozen test stimulus를 external discrete root input으로 분리했다.
- Source-to-derived Normal equivalence gate를 SIL Phase A의 선행 조건으로 추가했다.
- Three-scenario full algorithm build 1회를 build reuse objective로 정의하고, 실제 R2023b 제약을 evidence로 확인하도록 했다.
- Numerical tolerance는 추가하지 않았다.

