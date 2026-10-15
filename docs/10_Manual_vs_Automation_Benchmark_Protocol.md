# Manual vs Automation Time Benchmark Protocol

## 1. 목적과 범위

이 protocol은 frozen scalability pool의 `selection_order` 1~25에 대해 사람이 직접 stimulus를 입력하고, simulation을 실행하고, 신호를 확인하고, PASS/FAIL을 판정하고, 결과를 기록하는 반복 workflow의 wall-clock time을 측정한다. 이후 동일한 25개 Test Case를 동일 환경에서 처리하는 automated runner의 시간과 비교하기 위한 manual benchmark protocol이다.

이 단계에서는 automation benchmark나 시간 절감률을 계산하지 않는다. Manual benchmark 자체를 자동화하지 않으며, 여기서 얻은 기록은 기존 verification evidence를 대체하거나 변경하지 않는다.

## 2. Benchmark 대상

대상은 `results/scalability_extension_v1/candidate_execution_spec_resolved.csv`의 frozen ordering을 그대로 따른다. Scalability Extension에서 사전에 정의한 nested budget `10 / 25 / 50 / 75 / 100` 중 frozen 25-case prefix이며, benchmark 결과를 본 뒤 유리한 Test Case를 고른 subset이 아니다. 모든 segment duration은 2.0 s이다.

| Order | Test Case | Requirement | SpeedRef values [rps] | Stop Time [s] | Oracle |
|---:|---|---|---|---:|---|
| 1 | `EXT-B01-CAND-023` | `REQ-VOLT-001` | `[-10.0]` | 2.0 | VOLT |
| 2 | `EXT-B04-TC-008` | `REQ-TRK-001` | `[0.5]` | 2.0 | TRK |
| 3 | `EXT-B01-CAND-011` | `REQ-DIR-001` | `[-0.5]` | 2.0 | DIR |
| 4 | `EXT-B05-TC-016` | `REQ-REV-001` | `[-4.0, 12.0]` | 4.0 | REV |
| 5 | `EXT-B01-CAND-025` | `REQ-VOLT-001` | `[-19.9, -19.9, 19.9, 19.9]` | 8.0 | VOLT |
| 6 | `EXT-B02-TC-015` | `REQ-TRK-001` | `[0.0, -4.0]` | 4.0 | TRK |
| 7 | `EXT-B07-TC-002` | `REQ-DIR-001` | `[-1.0]` | 2.0 | DIR |
| 8 | `EXT-B04-TC-020` | `REQ-REV-001` | `[0.5, -0.5]` | 4.0 | REV |
| 9 | `EXT-B04-TC-001` | `REQ-VOLT-001` | `[1.0]` | 2.0 | VOLT |
| 10 | `EXT-B01-CAND-007` | `REQ-TRK-001` | `[0.0]` | 2.0 | TRK |
| 11 | `EXT-B04-TC-017` | `REQ-DIR-001` | `[8.0]` | 2.0 | DIR |
| 12 | `EXT-B07-TC-025` | `REQ-REV-001` | `[-15.0, 15.0]` | 4.0 | REV |
| 13 | `EXT-B07-TC-017` | `REQ-VOLT-001` | `[-8.0, 8.0]` | 4.0 | VOLT |
| 14 | `EXT-B01-CAND-003` | `REQ-TRK-001` | `[19.9]` | 2.0 | TRK |
| 15 | `EXT-B04-TC-019` | `REQ-DIR-001` | `[19.9, -19.9]` | 4.0 | DIR |
| 16 | `EXT-B05-TC-019` | `REQ-REV-001` | `[5.0, 0.0, -5.0]` | 6.0 | REV |
| 17 | `EXT-B06-TC-007` | `REQ-VOLT-001` | `[19.9, -19.9, 0.0]` | 6.0 | VOLT |
| 18 | `EXT-B01-CAND-001` | `REQ-TRK-001` | `[1.0]` | 2.0 | TRK |
| 19 | `EXT-B06-TC-017` | `REQ-DIR-001` | `[-6.0]` | 2.0 | DIR |
| 20 | `EXT-B06-TC-024` | `REQ-REV-001` | `[15.0, -15.0]` | 4.0 | REV |
| 21 | `EXT-B06-TC-003` | `REQ-VOLT-001` | `[-0.1]` | 2.0 | VOLT |
| 22 | `EXT-B02-TC-014` | `REQ-TRK-001` | `[0.0, 4.0]` | 4.0 | TRK |
| 23 | `EXT-B01-CAND-010` | `REQ-DIR-001` | `[19.9]` | 2.0 | DIR |
| 24 | `EXT-B04-TC-021` | `REQ-REV-001` | `[-0.5, 0.5]` | 4.0 | REV |
| 25 | `EXT-B01-CAND-024` | `REQ-VOLT-001` | `[19.9, 19.9, -19.9, -19.9]` | 8.0 | VOLT |

Test Case의 순서, 값, segment duration 또는 Stop Time을 바꾸지 않는다.

## 3. 측정 구간

환경 준비 시간은 benchmark에 포함하지 않는다. 먼저 MATLAB을 실행하고 repository root로 이동한 뒤 다음 명령으로 temporary manual harness 준비가 끝난 것을 확인한다.

```matlab
addpath('runner');
session = prepare_manual_benchmark();
```

START는 TC #1 specification을 보고 첫 stimulus 입력 작업을 시작하기 직전이다.

END는 TC #25의 PASS/FAIL 결과를 `benchmark/manual_benchmark_sheet.csv`에 기록한 직후이다.

측정에 포함되는 시간:

- stimulus 입력
- Stop Time 확인 및 설정
- simulation 실행
- signal inspection
- manual Oracle 판정
- 결과 기록
- Test Case 사이의 수동 전환

측정에서 제외되는 시간:

- MATLAB 최초 실행
- repository clone
- 이 protocol 또는 프로젝트 설명을 처음 읽는 시간
- `prepare_manual_benchmark` 실행 및 harness 준비
- 휴식 또는 의도적인 중단

하나의 외부 stopwatch로 전체 START-to-END 시간을 연속 측정한다. 각 행의 start/end/elapsed field도 사람이 직접 기록하며 script로 계산하지 않는다.

## 4. Temporary manual harness

`prepare_manual_benchmark`는 frozen source model을 직접 편집하지 않는다. 기존에 검증된 `scalability_stimulus_harness('create', ...)` interface로 OS temporary directory에 source model 복사본을 만들고, 복사본의 기존 stimulus 블록만 From Workspace 입력으로 교체한다. Controller, plant, Oracle, signal logging point는 변경하지 않는다.

준비 함수는 생성 전후 source model SHA-256을 비교한다. Temporary model의 From Workspace 블록은 `manual_speedref`를 읽고 `Interpolate=off`, `OutputAfterFinalValue=Holding final value`를 사용한다. Temporary model 변경은 source `.slx`에 저장되지 않는다.

Benchmark 종료 후 다음 명령으로 temporary model과 directory를 정리한다.

```matlab
scalability_stimulus_harness('cleanup', session.harness);
```

## 5. Test Case별 수동 절차

각 Test Case에 대해 아래 작업을 사람이 한 번씩 수행한다. 다음 Test Case를 자동으로 불러오거나 loop로 실행하지 않는다.

1. 이 문서 또는 frozen specification에서 현재 Test Case의 ID, requirement, SpeedRef values, Stop Time을 확인한다.
2. Command Window에서 `manual_speedref`를 직접 입력한다.
3. Temporary model의 Stop Time을 표의 값으로 직접 확인하거나 설정한다.
4. Simulink Run 버튼으로 simulation을 한 번 실행한다.
5. Simulink Data Inspector 또는 `logsout`에서 `reference`, `motorspeed`, `Vcmd`를 확인한다.
6. Section 7의 해당 manual rule을 직접 적용한다.
7. `manual_benchmark_sheet.csv`에 start/end/elapsed, PASS 또는 FAIL, 필요한 note를 직접 기록한다.
8. 사람이 표의 다음 행으로 이동한다.

금지되는 작업:

- Test Case 자동 loading 또는 자동 전환
- 25개 Test Case loop
- Test Case별 자동 simulation
- `run_ai_scalability_suite` 또는 다른 automated runner 호출
- `evaluate_voltage_limit`, `evaluate_tracking`, `evaluate_direction` 호출
- metric, PASS/FAIL 또는 elapsed time 자동 계산
- 결과 자동 기록

## 6. Stimulus 입력 형식

`manual_speedref`는 `[time_s, SpeedRef_rps]`의 2-column numeric matrix이다. 각 행의 time에서 새 값이 시작되며 interpolation은 사용하지 않는다. 사용자는 frozen values를 보고 matrix를 직접 입력한다. 준비 함수는 Test Case profile을 생성하거나 입력하지 않는다.

Constant -10 rps, Stop Time 2.0 s:

```matlab
manual_speedref = [
    0.0  -10.0
];
```

Two-level `[-4.0, 12.0]`, Stop Time 4.0 s:

```matlab
manual_speedref = [
    0.0   -4.0
    2.0   12.0
];
```

Four-segment `[-19.9, -19.9, 19.9, 19.9]`, Stop Time 8.0 s:

```matlab
manual_speedref = [
    0.0  -19.9
    2.0  -19.9
    4.0   19.9
    6.0   19.9
];
```

`[0.0, -4.0]`은 첫 행을 `[0.0, 0.0]`, 두 번째 행을 `[2.0, -4.0]`으로 직접 입력하고 Stop Time을 4.0 s로 설정한다.

## 7. Automated Healthy semantics와 동일한 수동 판정

Manual 판정은 `runner/run_ai_scalability_suite.m`의 Healthy BASELINE evaluation logic을 그대로 따른다. 판정에는 logged `reference`, `motorspeed`, `Vcmd`, `raw_pi_output`을 사용한다. Data Inspector cursor, signal table 또는 Command Window의 기본 indexing, `max`, `min`, `abs`, `sign`을 이용할 수 있지만, Test Case별 metric helper나 자동 판정 script를 만들지 않는다.

### 7.1 Frozen evaluation interval

각 행의 `evaluation_scope`, `evaluation_window_s`, `evaluation_intervals_s`는 authoritative execution specification에서 복사한 값이다. 사용자는 `evaluation_intervals_s`에 기록된 interval과 segment index를 그대로 사용하며 terminal window를 임의로 이동하거나 다시 정의하지 않는다. `0.05 s`는 frozen project evaluation setting이며 새로운 acceptance criterion이나 product performance requirement가 아니다.

`applicability_check_required=true`인 TRK 행은 Tracking metric보다 applicability를 먼저 판정한다. REV 행의 `evaluation_intervals_s`는 reportable reversal target window를 식별한다. REV setup precondition은 Section 7.5에 따라 previous non-zero plateau의 terminal 0.05 s를 사용한다.

### 7.2 VOLT — REQ-VOLT-001

`evaluation_scope=complete_simulation_interval`인 전체 simulation 구간에서 모든 `Vcmd` sample을 확인한다.

```text
max(Vcmd) <= +12 V
AND
min(Vcmd) >= -12 V
```

두 조건을 모두 만족하면 PASS, 아니면 FAIL이다. Numerical tolerance를 추가하지 않는다. `raw_pi_output`은 VOLT PASS/FAIL에 사용하지 않는다.

### 7.3 DIR — REQ-DIR-001

Sheet의 terminal `evaluation_intervals_s`에 있는 모든 sample을 확인한다. 해당 interval의 `reference`는 non-zero constant여야 하며 모든 sample에서 다음을 만족하면 PASS이다.

```text
reference .* motorspeed > 0
```

하나라도 만족하지 않으면 FAIL이다. Tracking accuracy, settling performance 또는 minimum speed magnitude는 DIR 판정에 포함하지 않는다.

### 7.4 TRK — REQ-TRK-001 applicability와 판정

각 `evaluation_intervals_s`의 terminal 0.05 s에 대해 먼저 persistent actuator clamp를 확인한다. 필요한 신호는 `reference`, `motorspeed`, `Vcmd`, `raw_pi_output`이다.

Window의 모든 sample에서 다음 positive 또는 negative clamp 조건 중 하나가 지속되면 해당 segment는 `PRECONDITION_NOT_MET`이다.

```text
positive clamp: raw_pi_output > +12 V
                AND abs(Vcmd - 12 V) <= clamp_tolerance

negative clamp: raw_pi_output < -12 V
                AND abs(Vcmd + 12 V) <= clamp_tolerance

clamp_tolerance = 64 * eps(max([1; abs(Vcmd(window)); 12]))
```

이 machine-scale tolerance는 automated runner가 Vcmd의 clamp equality를 확인할 때 사용하는 기존 수치 처리이며 Tracking acceptance threshold가 아니다. Persistent clamp이면 Tracking metric을 적용하지 않고 `manual_applicability=PRECONDITION_NOT_MET`, `manual_result=INCONCLUSIVE_PRECONDITION`으로 기록한다.

Persistent clamp가 아니면 `manual_applicability=APPLICABLE`로 기록하고 같은 frozen interval에서 다음을 확인한다.

```text
max(abs(reference - motorspeed)) <= 1e-9 rps
```

조건을 만족하면 PASS, 아니면 FAIL이다. `1e-9 rps`는 project-specific numerical-zero tolerance이며 product performance requirement가 아니다. Multi-segment TRK에서 어느 evaluation segment라도 precondition을 충족하지 못하면 Test Case 결과는 `INCONCLUSIVE_PRECONDITION`이다. 판정 대상 segment에서 Tracking FAIL이 있으면 FAIL이 우선한다.

### 7.5 REV — REQ-REV-001 previous-nonzero semantics

REV는 단순히 마지막 plateau만 확인하지 않는다. Segment를 시간 순서대로 검토한다.

- `reference == 0`: Direction과 Tracking을 평가하지 않고 `NOT_EVALUATED`로 둔다. Previous non-zero state를 변경하지 않는다.
- `reference ~= 0`: 해당 plateau의 terminal 0.05 s에서 DIR과 TRK를 평가한다. Plateau combined pass는 `Direction PASS AND Tracking PASS`이다.
- Current non-zero sign이 previous non-zero sign과 반대이면 current segment가 reversal target이다.

Reversal target의 previous non-zero plateau가 combined PASS여야 setup precondition이 성립한다.

- Previous non-zero plateau가 combined PASS가 아니면 `manual_applicability=PRECONDITION_NOT_MET`, `manual_result=INCONCLUSIVE_PRECONDITION`이다.
- Previous non-zero plateau가 combined PASS이고 current reversal target도 combined PASS이면 PASS이다.
- Setup precondition은 충족했지만 current reversal target의 Direction 또는 Tracking이 FAIL이면 FAIL이다.

Zero intermediate가 있어도 직전 segment가 아니라 previous non-zero plateau를 사용한다. 예를 들어 `[5, 0, -5]`에서 reversal target은 segment 3이고 setup plateau는 segment 1이다. REV에서 setup precondition이 충족되면 summary-level `manual_applicability`는 automated Healthy result와 같이 `NOT_REQUIRED`로 기록한다.

## 8. 공정성 규칙

- 평소 MATLAB/Simulink를 다루는 정상 속도로 수행하며 일부러 느리게 하지 않는다.
- Automated result를 보면서 PASS/FAIL을 복사하지 않는다.
- 기존 `healthy_execution_results.csv`를 열어 정답을 확인하지 않는다.
- Test Case 결과를 미리 기록하지 않는다.
- Manual/automation 측정은 동일 hardware와 MATLAB environment를 사용한다.
- Frozen prefix 25의 Test Case ordering을 유지한다.
- Manual benchmark는 25개 전체를 사용자가 한 번씩 직접 수행한다.
- 이후 automation benchmark도 동일한 frozen 25개를 사용한다.
- Manual과 Automation은 동일한 frozen evaluation interval 및 PASS, FAIL, INCONCLUSIVE semantics를 사용한다.
- Manual은 사람이 stimulus 설정, 실행, 신호 확인, 판정, 기록을 직접 수행하고 Automation은 runner가 동일 workflow를 수행한다.
- 측정 중 automation runner를 사용하지 않는다.
- Typing mistake가 발생하면 실제 manual workflow의 일부로 바로 수정하되 retry를 숨기거나 시간을 제외하지 않는다.
- 결과를 확인한 뒤 protocol을 수정하지 않는다. 수정이 필요하면 benchmark를 시작하지 않고 protocol과 sheet를 먼저 수정하여 다시 동결한다.

## 9. 결과 기록

`benchmark/manual_benchmark_sheet.csv`의 specification column은 frozen source에서 미리 채워져 있다. 다음 column은 benchmark 시작 전에 blank여야 하며 사용자가 직접 채운다.

- `manual_start_time`
- `manual_end_time`
- `manual_elapsed_s`
- `manual_applicability`
- `manual_result`
- `notes`

기존 Healthy 결과나 예상 PASS/FAIL을 미리 입력하지 않는다.

`manual_result`에 허용되는 값은 다음 네 가지뿐이다.

- `PASS`
- `FAIL`
- `INCONCLUSIVE_PRECONDITION`
- `EXECUTION_ERROR`

`manual_applicability`는 Healthy summary semantics에 맞춰 기록한다. VOLT와 DIR은 `NOT_REQUIRED`, applicable TRK는 `APPLICABLE`, persistent-clamp TRK는 `PRECONDITION_NOT_MET`이다. REV는 setup precondition이 충족되면 `NOT_REQUIRED`, 충족되지 않으면 `PRECONDITION_NOT_MET`이다.

입력 실수 또는 simulation failure로 유효한 신호와 판정을 얻지 못하면 PASS/FAIL을 추정하지 않고 `EXECUTION_ERROR`와 원인을 `notes`에 기록한다. 해당 Test Case만 재시도하여 시간이나 결과를 유리하게 바꾸지 않는다.

다음 중 하나가 발생하면 개별 행을 선택적으로 재시도하지 말고 전체 benchmark run을 무효 처리한다: frozen 순서 또는 evaluation interval 위반, 측정 중 automated runner나 기존 Healthy 결과 참조, stopwatch 구간 누락, environment 변경, 또는 중단 후 일부 Test Case만 재개한 경우. 재측정이 필요하면 원인을 기록하고 TC #1부터 새 run으로 다시 시작한다.

## 10. 결과 해석 제한

이 benchmark 결과와 time reduction percentage는 "해당 frozen prefix 25 Test Case를 동일 환경에서 반복 실행·판정·기록하는 workflow"의 시간 비교에만 적용한다.

다음 항목으로 일반화하지 않는다.

- 모든 자동차 software verification 업무의 시간 절감률
- HIL verification 시간 절감률
- 실제 ECU verification 시간 절감률
- 모든 Test Case에서 동일한 시간 절감률
- frozen 700회 전체 수동 verification의 직접 실측값

25개 Test Case 결과를 700회 전체의 manual execution 시간으로 단순 외삽하지 않는다. 실제 HIL 또는 ECU verification productivity로 일반화하지 않는다. Manual 측정값을 확보한 뒤에만 동일 frozen 25개 Test Case의 별도 automation benchmark를 설계·수행한다.
