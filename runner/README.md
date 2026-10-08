# AS2308 MIL 반복 실행기

`run_mil_baseline.m`은 기존 `model/AS2308_MIL_Baseline_v1.slx`를 저장하거나
수정하지 않고 다음 characterization 속도 지령을 순서대로 실행한다.

- +5 rps
- +10 rps
- +15 rps
- -5 rps
- -10 rps
- -15 rps

각 run에서 아래 신호를 수집한다.

- speed reference (rps)
- actual motor speed (rps)
- PI controller output voltage (V)

기본 시뮬레이션 시간은 5초이고, 마지막 1초를 steady-state 구간으로 사용한다.

## Metric 정의

- **Steady-state speed [rps]**: 마지막 steady-state 구간의 actual motor speed 평균
- **Steady-state error [%]**:

```text
(commanded reference - steady-state speed) / commanded reference * 100
```

- **Peak speed [rps]**: 명령 방향으로 가장 멀리 도달한 actual speed. 양수 명령은
  최댓값, 음수 명령은 최솟값을 사용한다.
- **Overshoot [%]**: 먼저 actual speed에 `sign(commanded reference)`를 곱해 명령
  방향을 양수로 정규화한 뒤 다음 식으로 계산한다.

```text
directed peak = max(sign(commanded reference) * actual speed)
overshoot = max(0, (directed peak - abs(commanded reference))
                    / abs(commanded reference) * 100)
```

  따라서 음수 reference에서도 overshoot가 부호에 의해 뒤집히지 않는다.
- **Settling time [s]**: actual speed가 commanded reference 중심의 ±2% band에
  들어간 후 simulation 종료까지 다시 벗어나지 않는 최초 시간. 종료 시점에도
  band 밖이면 `NaN`이다. 2%는 metric 계산을 위한 기본 band이며 PASS/FAIL
  threshold가 아니다. `SettlingBand_pct` 옵션으로 변경할 수 있다.
- **Maximum/Minimum controller voltage [V]**: 전체 run에서 PI controller 출력
  전압의 최댓값과 최솟값
- **+12 V/-12 V saturation 발생 여부**: controller voltage가 각각 `+Vdc` 또는
  `-Vdc` limit에 도달한 sample이 하나라도 존재하는지 나타내는 logical 값
- **Saturation cumulative time [s]**: `abs(controller voltage) = Vdc`인 saturation
  indicator를 시간에 대해 사다리꼴 적분한 값

이 Runner는 metric만 산출하며 PASS/FAIL 판정이나 acceptance criterion을
적용하지 않는다.

## 실행 방법

MATLAB에서 repository 루트로 이동한 뒤 다음 명령을 실행한다.

```matlab
addpath('runner');
[summaryTable, runData] = run_mil_baseline();
```

또는 repository 내부의 다른 위치에서 실행하려면 `runner`의 절대 경로를
`addpath`에 전달한다. 함수는 자신의 위치를 기준으로 `model/`과 `results/`를
찾으므로 MATLAB의 현재 폴더에는 의존하지 않는다.

실행 시간과 steady-state 구간은 name-value 인수로 바꿀 수 있다.

```matlab
[summaryTable, runData] = run_mil_baseline( ...
    'StopTime_s', 8, ...
    'SteadyStateWindow_s', 2, ...
    'SettlingBand_pct', 2);
```

## 출력

기본 실행은 `results/`에 다음 CSV 파일을 만든다.

- `mil_run_plus_5_rps.csv`
- `mil_run_plus_10_rps.csv`
- `mil_run_plus_15_rps.csv`
- `mil_run_minus_5_rps.csv`
- `mil_run_minus_10_rps.csv`
- `mil_run_minus_15_rps.csv`
- `mil_summary.csv`

각 run CSV에는 시간, 속도 지령, 실제 모터 속도, PI 출력 전압의 전체 시계열이
저장된다. 요약 CSV에는 각 run의 정상상태, peak, overshoot, settling, controller
voltage 및 saturation metric과 계산 설정이 저장된다.

## 모델 처리 방식

기존 모델의 Controller, Plant, gain 및 saturation 파라미터는 변경하지 않는다.
실행기는 기존 참조 생성 경로의 Pulse Generator 진폭과 Constant 값을
`Simulink.SimulationInput`으로 run별 오버라이드하여 고정 속도 지령을 만든다.
또한 필요한 세 신호의 logging 설정은 메모리에서만 켠 뒤 원래 상태로 복원하며,
`.slx` 파일을 저장하지 않는다.

## Plant model limitation

현재 Plant는 실제 AS2308 실험 데이터에서 식별한 다음 1차 voltage-to-speed
저차 모델이다.

```text
G(s) = 2185.96 / (s + 17.76)
```

따라서 이 MIL characterization 결과는 해당 저차 속도 응답 모델과 정상 PI
Controller의 조합에 대한 것이다. Current dynamics, PWM switching, encoder
quantization/measurement, motor electrical transient를 검증하는 모델은 아니며,
그 현상에 대한 검증 결과로 해석하면 안 된다.

## Reference filter transient 비교

`compare_reference_filter.m`은 동일한 정상 Controller와 Plant에 +15 rps step을
인가하고 다음 두 경우를 비교한다.

- baseline reference filter 적용: `20/(s+20)`
- reference filter bypass: `1`

두 run 사이에서 변경되는 것은 `Transfer Fcn1`의 run-time block parameter뿐이며,
`.slx`에는 저장되지 않는다. Controller, PI gain, Anti-windup 및 Plant parameter는
변경하지 않는다.

```matlab
[comparisonTable, filterRunData] = compare_reference_filter();
```

Overshoot와 settling time은 baseline characterization과 동일한 정의를 사용한다.
기본 settling band는 명령값 중심 ±2%이며 metric 계산용 정의일 뿐 PASS/FAIL
기준이 아니다.

생성 파일:

- `results/reference_filter_applied_15_rps.csv`
- `results/reference_filter_bypassed_15_rps.csv`
- `results/reference_filter_comparison_summary.csv`

두 run CSV에는 time, filtered 또는 bypassed reference, actual speed, controller
voltage가 저장된다. Summary에는 peak speed, overshoot, settling time 및 controller
voltage 최댓값/최솟값이 저장된다.
