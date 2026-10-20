# M0 Feasibility Report

Fill this in as you run the Gate 0 tests from the PRD. Attach the exported CSVs to `docs/recordings/` (or link them) so every number here is traceable.

**Tester:**  
**iPhone model / iOS version:**  
**AirPods model / firmware:**  
**App build (Actions run #):**  

## Gate 0C: Build and install without a Mac

| Step | Result | Notes |
| --- | --- | --- |
| GitHub Actions builds unsigned `.ipa` | | |
| Sideloadly signs with free Apple ID | | |
| App installs and opens on iPhone | | |
| Update by re-sideloading a new build | | |
| Cost so far | $0 | |

**Decision:** Go / No-go

## Gate 0A: Data stream availability

Record at least 30 seconds per trial. Check each CSV in the viewer.

| # | Condition | Streamed? | Samples | Duration | Rate (Hz) | Gaps | Dropout | Interruptions / events | CSV |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Worn in ear, ear detection on | | | | | | | | |
| 2 | Handheld, ear detection on | | | | | | | | |
| 3 | Handheld, ear detection off | | | | | | | | |
| 4 | Open palm, then closed hand | | | | | | | | |
| 5 | On desk, then rotated by hand | | | | | | | | |

Three consecutive handheld trials (go criterion):

| Trial | Condition | Duration | Rate | Unexplained interruption? | Slow rotations visible? |
| --- | --- | --- | --- | --- | --- |
| A | | | | | |
| B | | | | | |
| C | | | | | |

Repeat after reconnecting, and again on a different day:

| Date | Condition | Result |
| --- | --- | --- |
| | | |

**Decision:** Go / Conditional go / No-go

## Gate 0B: Sampling and dynamic range

| Test | Rate (Hz) | Median interval | Dropout | Clipping / discontinuities | Notes |
| --- | --- | --- | --- | --- | --- |
| Stationary baseline | | | | | |
| Slow orientation changes | | | | | |
| Controlled medium-speed swing | | | | | |

Target: ≥ 20 Hz effective rate and < 5% dropout in controlled trials.

**Decision:** Go / Restrict to slow tempo drills / No-go

## Findings and failure modes

-

## Overall M0 decision

-
