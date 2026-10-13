# AS2308 SIL Back-to-Back Verification Protocol v1.0 Frozen

| 항목 | 내용 |
|---|---|
| 문서 버전 | v1.0 |
| 문서 상태 | Frozen |
| Verification Level | Host SIL Back-to-Back Characterization / Equivalence Verification |
| Source Model | `model/AS2308_MIL_Baseline_v3.slx` |
| Source Model SHA-256 | `4A7FDC070506CA641ACBD2C3EFEA2FEF71DDCC150CA3FC1F20F191B8B998ED4D` |
| Initial Code-Generation Target | Current GRT configuration, Windows x86-64 |

## 1. Objective

본 protocol은 frozen MIL source model과 Simulink Coder로 생성된 C implementation 사이의 closed-loop functional/numerical equivalence를 characterization하고, 이후 Back-to-Back 판정 기준을 수립하기 위한 절차를 정의한다.

MIL requirement verification과 SIL Back-to-Back verification은 서로 다른 verification objective를 가진다.

- MIL requirement verification은 controller 및 verification environment의 동작이 해당 Requirement와 Oracle을 만족하는지 확인한다.
- SIL Back-to-Back verification은 Simulink model과 generated C implementation이 동일 조건에서 기능적·수치적으로 동등하게 동작하는지 확인한다.
- SIL Back-to-Back `PASS`는 generated implementation의 model equivalence를 의미하며, 그 자체를 product requirement `PASS`로 해석하지 않는다.
- 기존 MIL Oracle, threshold 및 corrected MIL result는 SIL equivalence 판정을 위해 변경하거나 재해석하지 않는다.

현재 v1.0에서는 numerical tolerance를 정의하지 않는다. 먼저 healthy Model/SIL 결과의 차이를 characterization한 후 별도 revision에서 project-specific B2B tolerance를 freeze한다.

## 2. Baseline and Scope

### 2.1 Source Baseline

SIL Back-to-Back source baseline은 다음과 같다.

- Model: `model/AS2308_MIL_Baseline_v3.slx`
- SHA-256: `4A7FDC070506CA641ACBD2C3EFEA2FEF71DDCC150CA3FC1F20F191B8B998ED4D`
- Solver type: Fixed-step
- Solver: `ode4`
- Fixed step: `ts = 0.0004 s`
- Numerical datatype: `double`
- Controller integrator: continuous-time Integrator
- Code-generation availability: Simulink Coder and Embedded Coder available
- MIL model and corrected MIL results: frozen

### 2.2 Code-Generation Scope

초기 SIL characterization의 code-generation scope는 `AS2308_MIL_Baseline_v3` top model 전체이다. 이 scope에는 다음이 포함된다.

- Speed PI Controller
- Identified reduced-order verification plant
- Closed-loop reference and feedback path
- Top-model execution semantics에 필요한 blocks and states

따라서 이 단계의 결과는 다음과 같이 표현한다.

> Closed-loop MIL model versus generated-code SIL equivalence

다음 표현은 사용하지 않는다.

> Standalone controller implementation verification

Top-model 전체가 code-generation scope이므로 결과는 controller-only production implementation의 독립적인 equivalence를 입증하지 않는다.

## 3. Primary Back-to-Back Architecture

Primary architecture는 closed-loop top-model Model versus generated-code SIL Back-to-Back 방식이다.

```text
Frozen SpeedRef scenario
        |
        +--> Normal/Model execution -------------------+
        |                                              |
        |                                    Model Vcmd, MotorSpeed
        |                                              |
        +--> Generated-code SIL closed-loop execution -+
                                                       |
                                             SIL Vcmd, MotorSpeed
                                                       |
                                            Numerical comparison
```

두 execution에는 다음 조건을 동일하게 적용한다.

- 동일한 frozen SpeedRef waveform
- 동일한 workspace parameter 값
- 동일한 initial state
- 동일한 Fixed-step / `ode4` solver semantics
- 동일한 `ts = 0.0004 s`
- 동일한 `double` datatype
- 동일한 stop time과 waveform transition time

현재 controller는 continuous-time Integrator와 fixed-step ODE4를 사용한다. 따라서 sampled controller input을 독립 component에 replay하는 standalone controller component SIL 방식은 primary 방법으로 사용하지 않는다. Controller-only sampled replay에서는 RK4 minor-step에서의 state update와 feedback semantics가 원래 closed-loop top-model execution과 달라질 수 있기 때문이다.

향후 standalone controller B2B를 수행하려면 controller timing semantics와 solver ownership을 별도로 정의하고, 해당 변경이 기존 MIL baseline과 어떤 관계를 갖는지 먼저 합의해야 한다.

## 4. Comparison Signals

### 4.1 Primary Comparison Signal

Primary comparison signal은 `Vcmd [V]`이다.

- Speed PI Controller의 saturation 이후 output이다.
- Generated controller output과 plant input 사이의 직접적인 closed-loop interface이다.
- Model과 SIL의 controller output behavior 및 voltage saturation behavior를 비교하는 기준 신호로 사용한다.

### 4.2 Secondary Comparison Signal

Secondary comparison signal은 `MotorSpeed`이다.

- 동일 generated closed-loop execution에서 verification plant의 output을 비교한다.
- `Vcmd`의 작은 차이가 closed-loop state propagation에 미치는 영향을 확인한다.
- `MotorSpeed` equivalence는 product tracking requirement 판정과 구분하여 B2B numerical comparison으로만 해석한다.

### 4.3 Diagnostic Signal

Diagnostic comparison 후보는 `raw_pi_output`이다.

- Saturation 직전 PI output이므로 `Vcmd` 차이가 PI 계산에서 발생했는지 saturation 처리에서 발생했는지 분석하는 데 사용한다.
- SIL execution에서도 안정적으로 observable하고 Model/SIL 양쪽에서 동일 의미로 수집 가능한 경우에만 사용한다.
- Diagnostic observability 확보를 위해 원본 DUT interface를 변경하지 않는다.
- Code optimization으로 신호가 제거되거나 의미가 달라지는 경우 diagnostic comparison은 `NOT_EVALUATED`로 남기며, 이를 primary comparison failure로 간주하지 않는다.

## 5. Frozen Scenario Reuse

다음 frozen MIL scenario를 B2B regression input으로 재사용할 수 있다.

- Manual Dynamic MIL Suite v1.0: 9 top-level executions
- Official AI MIL Suite v1: 9 top-level executions
- 최대 합계: 18 top-level frozen scenarios

Scenario reuse에는 다음 원칙을 적용한다.

- Test input magnitude를 변경하지 않는다.
- Waveform shape, segment order, transition time 및 duration을 변경하지 않는다.
- Existing Manual/AI Test Case를 교체하거나 보정하지 않는다.
- Model execution과 SIL execution에 동일한 scenario definition을 적용한다.
- 이 단계에서는 Manual Suite와 AI Suite의 성능 또는 effectiveness를 비교하지 않는다.

MIL에서 사용된 scenario를 재사용하더라도 SIL B2B 결과의 목적은 requirement compliance 재판정이 아니라 generated-code equivalence 확인이다.

### 5.1 Characterization Set and Evaluation Set Separation

B2B numerical tolerance를 전체 regression 결과를 확인한 뒤 결정하는 순환 구조를 방지하기 위해 frozen scenario를 Characterization Set과 Evaluation Set으로 사전에 분리한다.

Characterization Set은 기존 frozen Manual Test Case 중 동작 특성이 서로 다른 다음 3개 scenario로 고정한다.

| Characteristic | Frozen Scenario | Input |
|---|---|---|
| Nominal tracking | Manual MTC-002 / IT-001 | `+2 rps` |
| Saturation stress | Manual MTC-001 / IT-001 | `+16.75 rps` |
| Reversal | Manual MTC-004 / IT-001 | `+15 -> -15 rps` |

세 scenario는 기존 frozen Test Case이며 input, waveform, duration, transition time 및 sequence를 변경하지 않는다.

#### Phase A — Numerical Characterization

Phase A에서는 위 3개 Characterization Set scenario에서 Model과 SIL의 numerical difference만 측정한다. 각 scenario에서 최소 다음을 기록한다.

- Maximum absolute difference
- RMS difference
- First differing sample and corresponding time
- Time of maximum difference
- `Vcmd` difference
- `MotorSpeed` difference
- 해당되는 saturation interval 특성
- 해당되는 reversal/sign-change interval 특성

Phase A에서는 numerical equivalence `PASS` 또는 `FAIL`을 판정하지 않는다. 결과를 검토한 뒤 B2B numerical tolerance policy를 별도 protocol revision에서 정의하고 freeze한다.

#### Phase B — Independent Evaluation

Tolerance policy가 freeze된 이후 나머지 frozen scenario를 independent Evaluation Set으로 실행하고 `PASS` 또는 `FAIL`을 판정한다. Evaluation Set 결과를 사용하여 이미 freeze된 tolerance를 다시 조정하지 않는다.

Characterization에 사용한 3개 scenario는 최종 regression 결과 표에 참고용으로 포함할 수 있다. 그러나 tolerance 설정에 사용된 데이터이므로 tolerance의 독립적인 검증 근거로 표현하거나 Evaluation Set의 독립 결과에 포함하여 집계하지 않는다.

이 separation은 Manual Suite와 AI Suite의 성능을 비교하기 위한 것이 아니다. 따라서 두 suite 사이에 동일한 scenario 개수나 동일한 total duration을 요구하지 않는다.

## 6. Numerical Difference Characterization

v1.0에서는 Back-to-Back PASS/FAIL numerical tolerance를 정의하지 않는다. Healthy Model/SIL execution을 통해 각 comparison signal과 scenario에 대해 다음 값을 먼저 측정한다.

- Maximum absolute difference
- RMS difference
- First differing sample index and time
- Time of maximum difference
- Saturation interval difference
- Reversal or sign-change interval difference

### 6.1 Time-Grid and Sample Alignment Rule

Primary B2B comparison은 Model과 SIL이 동일한 fixed-step major-time grid를 생성하는 것을 전제로 한다. Numerical output을 비교하기 전에 반드시 다음 조건을 확인한다.

- Sample count가 동일함
- Start time이 동일함
- Stop time이 동일함
- 각 logged sample time이 동일하거나 machine representation 수준에서 동일함

정상적인 primary comparison에서는 Model 또는 SIL output을 interpolation, resampling 또는 extrapolation하여 상대방의 time grid에 맞추지 않는다.

Time vector가 예상과 다르면 output difference를 계산하기 전에 solver, fixed-step, stop time, logging 및 execution configuration mismatch를 먼저 조사한다. Time-grid mismatch 때문에 정상적인 sample-wise comparison을 수행할 수 없으면 해당 execution을 `EXECUTION_ERROR`로 기록한다.

Time-grid alignment가 확인된 뒤 동일 sample index에서 다음과 같이 비교한다.

```text
difference(k) = model_signal(k) - sil_signal(k)
```

### 6.2 Saturation Interval Analysis

`Vcmd`가 positive 또는 negative saturation boundary에 도달하는 구간을 식별하고 다음을 확인한다.

- Model과 SIL의 saturation entry time
- Saturation exit time
- Saturation 구간의 sample-wise difference
- Saturation boundary에서의 sign 및 clamping behavior

이 분석을 위해 새로운 product saturation threshold를 만들지 않는다. 기존 model parameter와 관찰된 boundary behavior를 사용한다.

### 6.3 Reversal and Sign-Change Analysis

Reference reversal 또는 output sign change가 포함된 scenario에서는 다음을 확인한다.

- 최초 `Vcmd` sign-change sample
- 최초 `MotorSpeed` sign-change sample
- Sign-change 주변의 maximum absolute difference
- State propagation에 따른 차이의 증가 또는 감소 여부

### 6.4 Future Tolerance Freeze

Characterization 결과를 검토한 뒤 별도 protocol revision에서 project-specific B2B tolerance를 정의하고 freeze한다. Tolerance 근거에는 최소 다음이 포함되어야 한다.

- Target and compiler configuration
- Datatype
- Solver and fixed-step configuration
- 사전에 지정된 3개 Characterization Set scenario에서 관찰된 numerical difference
- Reproducibility 확인 결과
- 선택한 tolerance와 관찰값 사이의 관계

근거 없이 `1%`, `0.1%` 또는 이와 유사한 임의 threshold를 사용하지 않는다. B2B numerical tolerance는 product performance requirement와 분리하여 관리한다.

## 7. Initial Host SIL Configuration

초기 characterization configuration은 다음과 같다.

| Configuration Item | Initial Setting |
|---|---|
| Execution mode | Host SIL |
| Solver type | Fixed-step |
| Solver | `ode4` |
| Fixed step | `ts = 0.0004 s` |
| Datatype | `double` |
| Host platform | Windows x86-64 |
| System target | Current GRT configuration first |
| Source scope | `AS2308_MIL_Baseline_v3` top model |

ERT target 전환, production code interface 정의, fixed-point 적용 또는 MCU-specific build는 본 revision의 범위가 아니다. ERT 기반 equivalence는 초기 GRT host SIL characterization 이후 별도 확장 단계로 관리한다.

## 8. Baseline Integrity and Artifact Control

다음 integrity control을 적용한다.

1. Source model을 직접 수정하지 않는다.
2. 실행 전 source model SHA-256을 protocol에 기록된 hash와 비교한다.
3. 실행 후 source model SHA-256을 다시 계산하여 실행 전 값과 동일한지 확인한다.
4. 실행 전후 controller 및 plant parameter 값을 기록하고 동일성을 확인한다.
5. Generated source, binaries, build cache, reports 및 comparison result는 source model과 분리된 전용 artifact directory에 저장한다.
6. Existing MIL result와 corrected MIL result를 overwrite하거나 재생성하지 않는다.
7. Model execution과 SIL execution에 사용한 configuration, scenario identifier 및 generated artifact identity를 traceable하게 기록한다.
8. Source hash, parameter 또는 required configuration이 일치하지 않으면 execution을 시작하지 않고 `EXECUTION_ERROR`로 기록한다.

Generated artifacts의 구체적인 directory naming과 retention policy는 implementation 단계에서 확정한다.

### 8.1 Reproducibility Metadata

각 SIL characterization 결과에는 실행과 build의 재현성을 위해 최소 다음 metadata를 기록한다.

- MATLAB / Simulink release
- `SystemTargetFile`
- Solver
- Fixed step
- Datatype
- Host platform
- Compiler and toolchain
- Source model SHA-256
- `Kps`, `Kis`, `Kas`, `Vdc`, `ts` 값

이 metadata는 product requirement 또는 acceptance criterion이 아니다. 동일 source, configuration 및 parameter로 B2B 결과를 재현하고 서로 다른 build 결과를 구분하기 위한 traceability 정보이다.

## 9. Limitations

Windows x86-64 host SIL은 generated C의 host execution을 통한 model equivalence를 확인하지만 다음 항목은 검증하지 않는다.

- Arduino Due target의 worst-case execution time (WCET)
- `400 us` real-time deadline 만족 여부
- Interrupt scheduling and latency
- ADC behavior
- PWM generation and timing
- Encoder acquisition, quantization and hardware timing
- CAN communication
- 실제 MCU architecture 차이
- 실제 target compiler의 optimization effect
- Target hardware I/O 및 peripheral integration

따라서 host SIL 결과를 real-time performance, target integration 또는 hardware verification 결과로 확대 해석하지 않는다.

## 10. Execution and Evaluation Status

### 10.1 Characterization Phase

Tolerance가 freeze되기 전에는 다음 상태만 사용한다.

| Status | Definition |
|---|---|
| `EXECUTION_OK` | Model과 SIL execution 및 required difference measurement가 정상 완료됨. Numerical PASS/FAIL은 아직 판정하지 않음. |
| `EXECUTION_ERROR` | Model 또는 SIL 실행, artifact integrity, signal collection, configuration consistency에 오류가 발생함. |
| `NOT_EVALUATED` | Required signal이 observable하지 않거나 해당 분석이 수행되지 않음. |

Characterization 단계의 `EXECUTION_OK`를 equivalence `PASS`로 표현하지 않는다.

### 10.2 Tolerance Freeze 이후

Numerical tolerance가 별도 revision에서 승인되고 freeze된 이후에는 다음 상태를 사용한다.

| Status | Definition |
|---|---|
| `PASS` | Required Model/SIL difference metric이 frozen B2B tolerance를 모두 만족함. |
| `FAIL` | 하나 이상의 required difference metric이 frozen B2B tolerance를 만족하지 못함. |
| `EXECUTION_ERROR` | 정상적인 equivalence 판정을 수행할 수 없는 실행 또는 infrastructure 오류가 발생함. |

## 11. Design Decisions

1. **Closed-loop top-model B2B를 primary architecture로 사용한다.** 현재 continuous-time Integrator와 ODE4 minor-step semantics를 보존하기 위해 controller-only sampled replay를 primary 방법에서 제외한다.
2. **초기 code-generation scope는 top model 전체이다.** 결과는 closed-loop MIL model versus generated-code SIL equivalence로 한정한다.
3. **`Vcmd`를 primary signal, `MotorSpeed`를 secondary signal로 사용한다.** `raw_pi_output`은 안정적으로 observable한 경우에만 diagnostic signal로 사용한다.
4. **Frozen Manual 9개와 Official AI 9개 scenario를 변경 없이 재사용한다.** 최대 18개 scenario의 B2B regression을 구성하되 Manual/AI effectiveness 비교는 수행하지 않는다.
5. **Characterization Set과 Evaluation Set을 사전에 분리한다.** 지정된 Manual scenario 3개에서 tolerance 근거를 characterization하고, 나머지 frozen scenario는 tolerance freeze 이후 독립 평가에 사용한다.
6. **Numerical tolerance를 characterization 전에 정의하지 않는다.** Characterization Set의 healthy Model/SIL difference를 먼저 측정하고 근거 기반의 별도 revision에서 freeze한다.
7. **Primary comparison은 동일한 major-time grid에서 index-by-index로 수행한다.** Interpolation이나 resampling은 사용하지 않으며 비교 불가능한 time-grid mismatch는 `EXECUTION_ERROR`이다.
8. **초기 host SIL은 현재 GRT/Windows x86-64 configuration을 우선한다.** ERT와 target-specific verification은 별도 확장으로 관리한다.
9. **Source model 및 기존 MIL evidence를 변경하지 않는다.** Source hash와 parameter integrity를 execution 전후 확인한다.
10. **Build metadata를 결과와 함께 기록한다.** 이는 B2B 재현성을 위한 정보이며 product requirement가 아니다.

## 12. Open Questions

다음 항목은 implementation 또는 tolerance-freeze revision 전에 결정해야 한다.

1. Generated artifacts, build cache, reports 및 B2B result의 정확한 directory 구조와 retention policy는 무엇인가?
2. Model execution과 SIL execution을 동일 runner에서 순차 실행할지, 독립 runner 결과를 immutable artifact로 비교할지?
3. `raw_pi_output`을 DUT interface 변경 없이 SIL에서 안정적으로 보존·관찰할 수 있는가?
4. Model/SIL time vector의 exact 또는 machine-representation equality를 구현에서 어떤 방식으로 계산하고 evidence로 저장할 것인가?
5. Difference가 처음 나타나는 sample을 판정할 때 exact inequality를 사용할지, machine representation 분석을 병행할지?
6. Evaluation Set의 실행 순서와 최종 regression result 집계 형식을 어떻게 고정할 것인가?
7. GRT host SIL characterization 완료 후 ERT configuration을 별도 baseline으로 관리할지?
8. Compiler version, build flags 및 generated-code checksum을 어떤 metadata schema로 저장할지?

본 문서는 **v1.0 Frozen** protocol이다. Numerical tolerance는 아직 미정이며 Phase A characterization 결과를 검토한 후 별도 revision 및 승인 절차를 통해 freeze한다.

## Revision Note

### v1.0

- Closed-loop top-model Model versus SIL architecture를 freeze했다.
- 3-scenario Characterization Set을 freeze했다.
- 나머지 frozen scenario를 independent Evaluation Set으로 사용하는 구성을 freeze했다.
- 동일 time grid와 동일 sample index에 기반한 comparison rule을 freeze했다.
- Numerical tolerance는 아직 정의하지 않으며 Phase A characterization 후 별도 protocol revision에서 freeze한다.
