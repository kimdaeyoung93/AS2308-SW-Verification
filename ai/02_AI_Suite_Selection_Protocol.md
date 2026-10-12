# AI Test Suite V1 Selection Protocol

## Status and purpose

This protocol is frozen before selecting the Official AI Test Suite V1. It
defines a deterministic selection procedure for choosing 9 top-level test
executions from the 25 VALID candidates in Official AI Candidate Set V1.

This protocol does not select any candidate. Candidate selection is a later,
separate action.

## A. Comparison budget

- The suite contains exactly 9 top-level test executions.
- This is the same execution budget used for the Manual Suite comparison.
- One candidate counts as one top-level execution, including a candidate that
  contains a multi-segment scenario.
- This execution-count definition is frozen before selection.

## B. Information permitted for selection

The selector may use only:

- Candidate content from the validated AI candidate pool
- Requirement ID
- `test_scope`
- `test_design_technique`
- SpeedRef input polarity
- Reversal and multi-segment characteristics
- Existing Validator VALID status, represented by membership in the validated
  candidate file

## C. Information prohibited from selection

The selector must not read, infer from, or score using:

- Mutation Set
- Mutation Results
- Kill Matrix
- Manual Test Cases
- Manual input values
- Manual mutation effectiveness
- Coverage contribution or Coverage results

Mutation detection potential and expected mutation kill score are not
selection objectives.

## D. Requirement quota

The Requirement quota uses largest-remainder proportional allocation from the
25-candidate pool to the 9-execution budget.

| Requirement | Pool count | Exact allocation | Frozen quota |
| --- | ---: | ---: | ---: |
| REQ-VOLT-001 | 6 | 6 / 25 * 9 = 2.16 | 2 |
| REQ-TRK-001 | 7 | 7 / 25 * 9 = 2.52 | 3 |
| REQ-DIR-001 | 6 | 6 / 25 * 9 = 2.16 | 2 |
| REQ-REV-001 | 6 | 6 / 25 * 9 = 2.16 | 2 |

The quota is a hard constraint:

- VOLT: 2
- TRK: 3
- DIR: 2
- REV: 2

The constrained search space is:

`C(6,2) * C(7,3) * C(6,2) * C(6,2) = 118,125 combinations`.

## E. Scope target

The 14 nominal / 11 stress pool distribution is proportionally mapped to:

- nominal: 5
- stress: 4

For a candidate combination, scope deviation is:

`abs(selected_nominal - 5) + abs(selected_stress - 4)`

The selector minimizes this value. An exact 5/4 split has deviation zero.

## F. Test-design-technique target

Largest-remainder proportional allocation gives the following target:

- Boundary Value Analysis: 4
- Equivalence Partitioning: 2
- State Transition: 1
- Scenario-Based: 2

Technique deviation is the sum of the absolute deviation from all four target
counts. The selector minimizes this sum after scope deviation.

## G. Input diversity

When the preceding objectives are equal, the selector applies these diversity
objectives in order:

1. Maximize polarity coverage. One point is awarded if any selected candidate
   contains a positive SpeedRef value and one point if any selected candidate
   contains a negative SpeedRef value.
2. Prefer a combination containing at least one reversal scenario.
3. Prefer a combination containing at least one multi-segment scenario.
4. Maximize the number of unique input signatures.

An input signature is the normalized `input_type` plus its ordered numeric
SpeedRef values. Sign, magnitude, value order, and segment count are preserved.

These diversity objectives do not estimate mutation effectiveness.

## H. Deterministic tie-break and optimization order

The selector applies a lexicographic objective. Earlier items always take
priority over later items:

1. Satisfy the frozen Requirement quota as a hard constraint.
2. Minimize scope deviation from nominal 5 / stress 4.
3. Minimize total technique deviation from BVA 4 / EP 2 / State Transition 1 /
   Scenario-Based 2.
4. Maximize positive/negative polarity coverage.
5. Prefer inclusion of a reversal scenario.
6. Prefer inclusion of a multi-segment scenario.
7. Maximize unique input-signature count.
8. Compare the sorted candidate IDs lexicographically and select the first.

No weighted sum is used. Therefore, a lower-priority objective cannot offset a
worse higher-priority objective.

## Planned outputs for the later selection step

The selector will create these files only when official selection is explicitly
requested:

- `ai/output/ai_suite_v1_selected.csv`
- `ai/output/ai_suite_v1_selection_summary.csv`

The selected-candidate output will include selection order, candidate ID,
Requirement ID, scope, test-design technique, input summary, polarity,
reversal status, multi-segment status, and selection reason.

Running input checks or self-checks must not create either output file.

