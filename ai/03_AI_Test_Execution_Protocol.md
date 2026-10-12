# AI Test Case Execution Adapter Protocol

## Status and purpose

This protocol deterministically converts the 9 frozen Official AI Suite V1
candidates into reproducible MIL execution specifications. It does not change
candidate intent, input magnitude, Requirement meaning, or Oracle criteria.

This step defines execution data only. It does not run Simulink and does not
produce PASS, FAIL, INCONCLUSIVE, or error results.

## Common execution parameters

- Constant-reference segment hold duration: `2.0 s`
- Single constant test duration: `2.0 s`
- N-segment sequence duration: `N * 2.0 s`
- Existing project sample time: `ts = 0.0004 s`
- Existing terminal evaluation window: `0.05 s`

The `2.0 s` segment duration is a test execution parameter. It is not a
product performance Requirement, settling-time Requirement, or new acceptance
threshold. It provides a common reproducible execution environment for Manual
and AI Suite runs.

The original AI candidates contain qualitative timing such as “hold long
enough” but no explicit numeric duration. This protocol resolves that execution
ambiguity without editing the original `input_values`.

## Deterministic waveform mapping

Each ordered `input_values` element becomes one piecewise-constant segment.
For one-based segment index `i`:

- `start_s = (i - 1) * 2.0`
- `end_s = i * 2.0`
- `SpeedRef = input_values[i]` for that segment

All non-final segments use the half-open interval `[start_s, end_s)`. The final
segment includes the simulation endpoint. The transition at a shared boundary
uses the next segment's value.

Examples:

- `[5.0]` resolves to `+5 rps` from `0 s` through `2 s`.
- `[5.0, -5.0]` resolves to `+5 rps` on `0–2 s` and `-5 rps`
  on `2–4 s`.
- `[10.0, -10.0, 10.0, -10.0]` resolves to four 2-second
  segments and an 8-second total duration.

The adapter preserves the original ordered numeric values in
`original_input_values` and adds a separate machine-readable resolved waveform.

## Requirement-to-Oracle mapping

### REQ-VOLT-001

- Evaluation scope: complete simulation interval
- Oracle: existing Voltage Oracle
- Evaluation window length recorded in the resolved specification: complete
  test duration

### REQ-DIR-001

- Evaluation scope: final plateau's final `0.05 s`
- Oracle: existing Direction Oracle

### REQ-TRK-001

- Evaluation scope: final `0.05 s` of every constant plateau
- Apply the Tracking applicability gate first
- If applicable, use the existing Tracking Oracle

### REQ-REV-001

- Evaluation scope: final `0.05 s` of every plateau immediately following an
  actual SpeedRef sign reversal
- Oracle result: existing Direction Oracle AND existing Tracking Oracle
- A multi-segment sequence is evaluated after each sign reversal

No existing Oracle implementation or threshold is changed by this mapping.

## Tracking applicability gate

REQ-TRK-001 is conditional on operation without persistent actuator
saturation. The adapter therefore defines a gate for each evaluated tracking
plateau.

In that plateau's terminal `0.05 s`, persistent clamp means every evaluated
sample is in either of these states:

- `raw_pi_output` requests above the positive saturation limit while `Vcmd` is
  clamped at the positive limit, or
- `raw_pi_output` requests below the negative saturation limit while `Vcmd` is
  clamped at the negative limit.

The limits are the existing configured saturation limits. No tolerance or
duration threshold is added. Requiring the clamp condition over the complete
existing terminal window distinguishes a persistent terminal condition from
transient saturation earlier in the segment.

- Persistent terminal clamp: `INCONCLUSIVE_PRECONDITION`
- Otherwise: evaluate the existing Tracking Oracle and report `PASS` or `FAIL`
- Simulation, signal, or Oracle processing failure: `EXECUTION_ERROR`

Transient saturation outside the terminal window is not a Tracking failure.
`INCONCLUSIVE_PRECONDITION` is not counted as a DUT Requirement failure, but it
remains visible in AI Suite test-quality results.

## Result states reserved for the future runner

- `PASS`
- `FAIL`
- `INCONCLUSIVE_PRECONDITION`
- `EXECUTION_ERROR`

The resolved execution specification created in this step records
`NOT_EXECUTED`; none of these result states is assigned yet.

## Scope restrictions

- Keep all 9 frozen candidates.
- Preserve every original input magnitude, including `+19.9 rps`.
- Do not consult Manual Test Cases, Mutation information, or Coverage results.
- Do not alter the existing Oracle code or thresholds.
- Do not run Simulink in this adapter build step.

