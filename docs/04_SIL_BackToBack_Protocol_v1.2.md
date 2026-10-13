# AS2308 SIL Back-to-Back Verification Protocol v1.2

| 항목 | 내용 |
|---|---|
| 문서 버전 | v1.2 |
| 문서 상태 | Frozen — Numerical Equivalence Criterion |
| 이전 Frozen Protocol | `docs/04_SIL_BackToBack_Protocol_v1.1.md` |
| Verification Level | Host SIL Back-to-Back Numerical Equivalence Verification |
| Source Model | `model/AS2308_MIL_Baseline_v3.slx` |
| Frozen Source Model SHA-256 | `4A7FDC070506CA641ACBD2C3EFEA2FEF71DDCC150CA3FC1F20F191B8B998ED4D` |
| Derived Verification Model | `model/verification/AS2308_SIL_B2B_Verification_v1.slx` |
| Frozen Derived Verification Model SHA-256 | `0223B483023B87DE70FA440558AF651DF4B21DCD9B8C7095772A6CDFAB18D565` |
| Numerical Environment | MATLAB/Simulink R2023b, Windows x86-64, GRT, double, fixed-step ode4, `ts = 0.0004 s` |

## 1. Purpose

본 revision은 Protocol v1.1 Frozen에 따라 완료된 Phase A Characterization 결과를 근거로, Phase B independent evaluation을 시작하기 전에 Model-Code numerical equivalence criterion을 freeze한 protocol이다.

MIL requirement verification과 SIL Back-to-Back numerical equivalence verification은 서로 다른 verification objective를 가진다. 본 protocol의 numerical criterion은 generated code가 동일한 verification environment에서 Simulink model과 수치적으로 동등하게 동작하는지를 판정하기 위한 것이며, product performance requirement 또는 product functional acceptance threshold가 아니다.

Phase A scenario는 numerical tolerance policy 설정에 사용되었으므로 Phase B independent evaluation evidence에는 포함하지 않는다.

## 2. Phase A Characterization Result

Protocol v1.1 Frozen의 characterization set에 대해 derived verification model의 Normal execution과 top-model SIL execution을 비교하였다.

| Scenario | Frozen Source Scenario | Result |
|---|---|---|
| `SIL-CHAR-001` | Manual `MTC-002 / IT-001`, `+2 rps`, `0–1 s` | `EXECUTION_OK` |
| `SIL-CHAR-002` | Manual `MTC-001 / IT-001`, `+16.75 rps`, `0–1 s` | `EXECUTION_OK` |
| `SIL-CHAR-003` | Manual `MTC-004 / IT-001`, `+15 rps → -15 rps`, `0–4 s` | `EXECUTION_OK` |

세 scenario에서 공통으로 다음 결과가 관찰되었다.

- Normal/SIL sample count, start time, stop time 및 time vector가 exact match하였다.
- `sampled_Vcmd`의 maximum absolute difference와 RMS difference는 모두 `0 V`였다.
- `sampled_MotorSpeed`의 maximum absolute difference와 RMS difference는 모두 `0 rps`였다.
- 두 signal의 differing sample count는 모든 scenario에서 `0`이었다.
- Continuous-sample-time logging warning은 발생하지 않았다.

추가 관찰 결과는 다음과 같다.

- `SIL-CHAR-002`: `t = 0 s`의 +12 V saturation sample에서 Model/SIL difference는 0이었다.
- `SIL-CHAR-003`: Vcmd sign transition은 양쪽 모두 `t = 2.0 s`, MotorSpeed sign transition은 양쪽 모두 `t = 2.0036 s`였으며 transition neighborhood maximum difference는 0이었다.

Phase A에서 exact equality가 관찰되었다는 사실만으로 모든 future SIL execution에 bitwise exact equality를 요구하지 않는다. Phase B 판정에는 Section 3의 frozen numerical tolerance formula를 적용한다.

## 3. Numerical Equivalence Tolerance

### 3.1 Per-Sample Formula

각 compared signal의 동일 sample index `k`에 대해 다음을 계산한다.

```text
scale(k) = max(1, abs(Model(k)), abs(SIL(k)))

numerical_tolerance(k) = 64 * eps(scale(k))
```

해당 sample의 numerical equivalence 조건은 다음과 같다.

```text
abs(Model(k) - SIL(k)) <= numerical_tolerance(k)
```

여기서 `eps(scale(k))`는 현재 IEEE-754 double representation에서 `scale(k)` 크기 주변의 floating-point spacing을 의미한다.

### 3.2 Interpretation

본 tolerance는 다음 특성을 가진다.

- IEEE-754 double precision의 machine-scale spacing에 기반한다.
- Model 및 SIL signal magnitude에 따라 sample별로 scaling된다.
- Product functional tolerance 또는 product performance threshold가 아니다.
- Simulink model과 generated C implementation 사이의 floating-point numerical equivalence만을 위한 project-specific criterion이다.
- `1%`, `1e-3`, `1e-6`, `1e-9` 등 임의의 fixed absolute 또는 relative threshold를 사용하지 않는다.
- Multiplier `64`는 ISO 26262, Automotive SPICE(A-SPICE), MathWorks 또는 기타 외부 표준에서 요구하는 값이 아니다.
- Multiplier `64`는 현재 project에서 Phase B 실행 전에 사전 정의하는 conservative machine-precision-scale numerical margin이다.
- Phase A에서 observed difference가 0이었다는 결과에 수치적으로 fitting하여 multiplier `64`를 도출한 것이 아니다.
- Phase A에서 exact equality를 확인했더라도 future generated-code execution에 bitwise exact equality를 acceptance criterion으로 강제하지 않기 위해 machine-scale margin을 사용한다.
- 본 criterion은 Section 10의 current frozen numerical environment에만 적용한다.

Phase B 결과를 관찰한 뒤 본 formula의 multiplier 또는 scaling definition을 조정하지 않는다.

## 4. Time-Grid and Sample Alignment

Section 3의 numerical tolerance는 signal value에만 적용한다. Time grid에는 numerical tolerance를 적용하지 않는다.

Numerical comparison 전에 다음 조건이 모두 exact match해야 한다.

- Sample count
- Start time
- Stop time
- 전체 time vector의 각 sample time

Primary comparison은 동일 sample index에서 수행한다.

```text
difference(k) = Model(k) - SIL(k)
```

Interpolation, resampling 또는 extrapolation으로 time grid를 맞추는 행위는 금지한다. Time-grid mismatch로 동일 sample index comparison을 정상 수행할 수 없으면 해당 execution의 status는 `EXECUTION_ERROR`이다.

## 5. Required Comparison Signals

Required signals는 다음과 같다.

- Primary: `sampled_Vcmd`
- Secondary: `sampled_MotorSpeed`

두 signal 모두 모든 required sample에서 Section 3의 per-sample numerical tolerance를 만족해야 한다. 어느 signal에서든 한 sample 이상 tolerance를 초과하면 해당 execution은 `FAIL`이다.

Continuous internal signal logging은 required SIL observation mechanism으로 사용하지 않는다. Derived verification model의 discrete root output interface를 사용한다.

## 6. Phase B Status Semantics

Tolerance freeze 이후 Phase B execution에는 다음 status만 사용한다.

### PASS

- Normal 및 top-model SIL execution이 정상 완료된다.
- Required root outputs와 time vectors가 정상 수집된다.
- Time grid가 Section 4에 따라 exact match한다.
- `sampled_Vcmd`의 모든 required sample이 numerical tolerance를 만족한다.
- `sampled_MotorSpeed`의 모든 required sample이 numerical tolerance를 만족한다.

### FAIL

- Execution, output acquisition, time-grid alignment 및 same-index comparison은 정상 완료된다.
- 하나 이상의 required signal sample에서 Section 3의 frozen numerical tolerance를 초과한다.

### EXECUTION_ERROR

다음과 같은 infrastructure/configuration 문제로 정상 numerical comparison을 수행할 수 없는 경우이다.

- Code generation, build 또는 SIL application failure
- Normal/SIL simulation failure
- Required output acquisition failure
- Empty, non-finite 또는 invalid signal data
- Sample count, start time, stop time 또는 time vector mismatch
- 기타 동일 sample index comparison을 불가능하게 하는 configuration 문제

`FAIL`은 정상적으로 완료된 data comparison에서 numerical criterion을 초과한 결과이며, `EXECUTION_ERROR`는 정상 comparison 자체가 불가능한 상태이다. 두 상태를 혼용하지 않는다.

## 7. Independent Phase B Evaluation Set

Phase B input pool은 기존 frozen Manual Dynamic MIL Suite v1.0의 9 top-level executions와 Official AI MIL Suite v1의 9 top-level executions이다.

다음 Phase A characterization executions는 tolerance policy 설정에 사용되었으므로 independent evaluation set에서 제외한다.

- Manual `MTC-002 / IT-001`
- Manual `MTC-001 / IT-001`
- Manual `MTC-004 / IT-001`

또한 ID가 다르더라도 Phase A Characterization scenario와 scenario identity가 실질적으로 동일한 execution은 Phase B independent evidence에서 제외한다. Scenario identity는 최소 다음 항목의 조합으로 정의한다.

- Waveform segment sequence
- Reference magnitude
- Transition time
- Total duration
- Initial reference semantics

위 항목이 Phase A의 3개 scenario 중 하나와 동일하면 execution ID 또는 suite가 다르더라도 independent evaluation 대상이 아니다. 이러한 execution의 실행 자체를 금지하지는 않는다. 필요한 경우 `SUPPLEMENTAL / NON-INDEPENDENT`로 별도 실행하고 결과를 기록할 수 있으나, Phase B independent execution 또는 `PASS` count에는 포함하지 않는다.

Manual 9개와 AI 9개에서 Phase A Manual execution ID 3개를 제외한 15개는 Phase B candidate maximum이다. 실제 independent execution count는 Phase A ID exclusion과 scenario-identity de-duplication/exclusion을 완료한 뒤 확정한다.

Evaluation runner 구현 전에 다음을 assertion한다.

- Manual 및 AI frozen source에서 읽은 top-level execution ID가 유일한지 확인한다.
- Phase A에서 사용된 Manual execution ID 3개를 exclusion하는지 확인한다.
- 모든 candidate의 scenario identity를 위 정의에 따라 구성하고 Phase A scenario identity와 동일한 execution을 independent set에서 exclusion하는지 확인한다.
- Phase A ID exclusion과 scenario-identity exclusion 결과를 구분하여 기록한다.
- Remaining independent execution count를 실행 전에 assertion하고 보고한다.
- Remaining scenario의 input magnitude, segment order, transition time, duration 및 waveform을 변경하지 않는다.
- Candidate maximum 15와 실제 independent execution count가 다르면 ID 및 scenario-identity exclusion 근거를 실행 전에 보고한다.

Phase B 결과는 이미 freeze된 tolerance를 검증하는 independent evidence이다. Evaluation 결과를 사용하여 tolerance를 재조정하지 않는다.

## 8. Diagnostic Evidence

각 Phase B execution과 required signal에 대해 최소 다음을 기록한다.

- Sample count
- Time-grid exact-match 여부
- Maximum absolute difference
- RMS difference
- Maximum numerical tolerance used
- Maximum normalized numerical error
- Differing sample count
- Tolerance-exceeding sample count
- First tolerance-exceeding sample index
- First tolerance-exceeding sample time

Maximum normalized numerical error는 다음과 같이 계산한다.

```text
normalized_numerical_error(k) =
    abs(Model(k) - SIL(k)) / numerical_tolerance(k)
```

Execution-level maximum은 모든 required sample에서 계산한 위 값의 최댓값이다. `PASS`인 경우에도 exact equality 여부와 differing sample count를 별도로 기록한다. Exact equality는 diagnostic evidence이며 별도의 acceptance criterion이 아니다.

## 9. Build-Reuse Evidence

Phase A에서 R2023b의 실제 build behavior는 다음과 같이 관찰되었다.

- 3개 characterization scenario에 대해 full build는 총 2회 발생했다.
- `SIL-CHAR-001`에서 최초 code generation, compilation 및 link가 발생했다.
- 동일 duration을 사용하는 `SIL-CHAR-002`에서는 generated executable이 재사용되었고 compilation/link가 생략되었다.
- StopTime이 1 s에서 4 s로 변경된 `SIL-CHAR-003`에서는 code generation, compilation 및 relink가 다시 발생했다.
- `SIL-CHAR-001`과 `SIL-CHAR-002`의 executable checksum은 동일했고, `SIL-CHAR-003`에서는 executable checksum이 변경되었다.

이 build behavior는 실제 R2023b execution evidence로 기록한다. Undocumented workaround를 사용하여 one-build reuse를 강제하지 않는다.

Build 횟수, build reuse 또는 execution elapsed time은 numerical acceptance criterion이 아니다. Build activity 자체로 Phase B `PASS` 또는 `FAIL`을 결정하지 않는다.

## 10. Environment Scope and Limitations

본 numerical equivalence criterion은 다음 frozen host environment에 한정된다.

- MATLAB/Simulink R2023b
- Windows x86-64 host
- Current GRT configuration
- Microsoft Visual C++ 2022 C toolchain used by Phase A
- IEEE-754 double datatype
- Fixed-step solver
- `ode4`
- `ts = 0.0004 s`
- Current controller, verification plant 및 derived observation interface

본 criterion을 다음 환경에 자동 적용하지 않는다.

- 다른 compiler 또는 compiler option
- 다른 operating system 또는 host architecture
- Arduino Due 또는 다른 target MCU
- PIL/HIL
- Production ECU
- Different datatype 또는 solver configuration
- ADC, PWM, encoder, CAN, interrupt 및 real-time scheduling behavior

SIL numerical equivalence `PASS`는 product requirement satisfaction, hardware correctness, real-time deadline satisfaction 또는 결함 부재를 의미하지 않는다.

## 11. Integrity and Revision Rule

- Frozen Source Model SHA-256은 `4A7FDC070506CA641ACBD2C3EFEA2FEF71DDCC150CA3FC1F20F191B8B998ED4D`이다.
- Frozen Derived Verification Model SHA-256은 `0223B483023B87DE70FA440558AF651DF4B21DCD9B8C7095772A6CDFAB18D565`이다.
- 본 v1.2 protocol은 Phase B 실행 전에 `Frozen` 상태로 확정되었다.
- Frozen source model, derived verification model, existing MIL/SIL result 및 v1.1 Frozen protocol을 수정하지 않는다.
- Phase B 결과를 확인한 뒤 numerical tolerance를 변경하지 않는다.
- Tolerance 변경이 필요하면 기존 v1.2 protocol과 그 결과를 보존하고 명시적인 새 protocol revision으로만 변경한다.
- Phase B runner는 execution 전후 source 및 derived model SHA-256을 모두 위 frozen identity와 exact match 확인하며 어느 모델도 저장하지 않는다.
- Execution 전 또는 후 어느 hash라도 mismatch이면 status는 `EXECUTION_ERROR`이다. Runner는 모델을 자동 수정하거나 복구하지 않는다.

## 12. Phase Separation

### Phase A — Characterization

- 사전에 freeze된 3개 representative scenario를 사용하였다.
- Model/SIL numerical difference와 build-reuse behavior를 관찰하였다.
- Phase A에서 exact equality와 stable execution을 확인한 후, future execution에 bitwise exact equality를 강제하지 않기 위해 Phase B 실행 전에 Section 3의 project-specific machine-precision-scale numerical criterion을 사전 정의하였다.
- Phase A scenario는 tolerance의 independent validation evidence로 사용하지 않는다.

### Protocol Freeze

- 본 v1.2 protocol은 Phase B 실행 전에 Frozen되었다.
- Frozen status는 Git commit으로 확정한다.
- Numerical formula, signal set, time-grid rule 및 status semantics를 고정한다.

### Phase B — Independent Evaluation

- Phase A 3개 scenario를 제외한 remaining frozen Manual/AI scenario를 실행한다.
- Frozen tolerance를 변경하지 않고 `PASS`, `FAIL`, `EXECUTION_ERROR`를 판정한다.
- Phase B 결과로 tolerance를 다시 tuning하지 않는다.

## Revision Note

### v1.2 Frozen

- Protocol v1.1 Frozen의 Phase A Characterization 결과를 기록하였다.
- Signal magnitude에 scaling되는 `64 * eps(scale(k))` numerical equivalence criterion을 freeze하였다.
- Signal value tolerance와 exact time-grid requirement를 분리하였다.
- Phase A characterization set과 Phase B independent evaluation set을 분리하였다.
- R2023b에서 관찰된 2회 full-build 및 same-duration executable reuse evidence를 기록하였다.
- 본 revision은 Phase B execution 전에 Frozen 상태로 전환되었으며 Git commit으로 확정한다.
