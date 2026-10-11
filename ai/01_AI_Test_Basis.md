# AI-Assisted Test Case Generation V1 — Test Basis

## Purpose and Allowed Use

This document is the complete input basis for generating AI-assisted,
requirements-based MIL test case candidates for the AS2308 speed-control
verification project. Candidates must remain executable in the MIL
environment and must trace to one of the requirements listed below.

The generator must not invent product performance thresholds or create new
Requirement IDs. Values or criteria that are not stated in this basis must
not be represented as product acceptance criteria.

## Device Under Test

- DUT: Speed PI Controller
- Input: `SpeedRef` [rps]
- Observable outputs:
  - `MotorSpeed` [rps]
  - `Vcmd` [V]

## Relevant Dynamic Requirements

### REQ-VOLT-001 — Controller Voltage Limitation

The speed-controller output voltage command `Vcmd` shall remain within
`-12 V <= Vcmd <= +12 V` over the complete simulation interval.

Verification observes the maximum and minimum `Vcmd` over the simulation.

### REQ-TRK-001 — Constant Speed Tracking

When a constant valid speed reference is maintained and persistent actuator
saturation does not occur, the closed-loop motor speed shall converge stably
to that reference.

Verification compares the reference with steady-state motor speed. No
additional numerical steady-state-error threshold is defined here.

### REQ-DIR-001 — Bidirectional Speed Control

A positive speed reference shall produce positive steady-state motor speed,
and a negative speed reference shall produce negative steady-state motor
speed.

Verification compares the sign of a non-zero reference with the sign of the
steady-state motor speed.

### REQ-REV-001 — Direction Reversal

When the speed-reference sign is reversed after steady operation in one
direction, motor speed shall transition from the original direction to the
new reference direction and converge stably.

Verification exercises both positive-to-negative and negative-to-positive
sequences and observes final direction and convergence. No numerical
reversal settling-time threshold is defined here.

## MIL Environment

- Reference path: `SpeedRef [rps]` passes through the required `2*pi`
  rps-to-rad/s unit conversion and then enters the Speed PI Controller.
- The verification reference path has no reference prefilter.
- Nominal SpeedRef domain: `|SpeedRef| < 20 rps`.
- DC-bus/controller voltage limit: `Vdc = 12 V`.
- Verification plant: reduced-order identified voltage-to-speed model,
  `G(s) = 2185.96 / (s + 17.76)`.
- The plant supports speed-domain MIL verification. It does not model
  current dynamics, PWM switching, encoder dynamics, or detailed electrical
  transients.

## Candidate Generation Constraints

- Every candidate must reference exactly one of the four Requirement IDs in
  this document.
- Every candidate must define executable `SpeedRef` stimulus values.
- A nominal candidate must keep every SpeedRef value strictly within the
  nominal domain.
- The expected behavior must be derived from the referenced requirement.
- Do not introduce numerical limits for tracking error, overshoot, settling
  time, reversal time, recovery time, or other performance measures unless
  such a limit is explicitly present in this basis.
- Test candidates are proposals. Schema validation does not establish
  requirement compliance.

