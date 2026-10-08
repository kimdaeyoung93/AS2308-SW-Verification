# AS2308 MIL 반복 실행기

`run_mil_baseline.m`은 기존 `model/AS2308_MIL_Baseline_v1.slx`를 저장하거나
수정하지 않고 다음 속도 지령을 순서대로 실행한다.

- +10 rps
- +15 rps
- -15 rps

각 run에서 아래 신호를 수집한다.

- speed reference (rps)
- actual motor speed (rps)
- PI controller output voltage (V)

기본 시뮬레이션 시간은 5초이고, 마지막 1초 동안의 actual motor speed 평균을
steady-state speed로 정의한다. Steady-state error는 다음 식으로 계산한다.

```text
(commanded reference - steady-state speed) / commanded reference * 100
```

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
    'SteadyStateWindow_s', 2);
```

## 출력

기본 실행은 `results/`에 다음 CSV 파일을 만든다.

- `mil_run_plus_10_rps.csv`
- `mil_run_plus_15_rps.csv`
- `mil_run_minus_15_rps.csv`
- `mil_summary.csv`

각 run CSV에는 시간, 속도 지령, 실제 모터 속도, PI 출력 전압의 전체 시계열이
저장된다. 요약 CSV에는 각 run의 지령값, 로깅된 정상상태 지령값, 정상상태 속도,
정상상태 오차, 실행 시간 및 사용한 정상상태 구간이 저장된다.

## 모델 처리 방식

기존 모델의 Controller, Plant, gain 및 saturation 파라미터는 변경하지 않는다.
실행기는 기존 참조 생성 경로의 Pulse Generator 진폭과 Constant 값을
`Simulink.SimulationInput`으로 run별 오버라이드하여 고정 속도 지령을 만든다.
또한 필요한 세 신호의 logging 설정은 메모리에서만 켠 뒤 원래 상태로 복원하며,
`.slx` 파일을 저장하지 않는다.
