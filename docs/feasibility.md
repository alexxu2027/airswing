# M0 Feasibility Report

Results of the Gate 0 tests from the PRD. Recordings are referenced by file name; stats were computed with the same method as the viewer.

**Test date:** 2026-10-20  
**iPhone / iOS:** iPhone, iOS 26.5.1  
**AirPods:** AirPods Pro 3 (firmware not recorded); all samples reported from the right earbud  
**App build:** AirSwing Probe 0.1.0, Actions run #1  

## Summary

| Gate | Result |
| --- | --- |
| 0C: Build and install without a Mac | **Go** at $0 |
| 0A: Handheld motion stream | **Go**, with Automatic Ear Detection off |
| 0B: Sampling and dynamic range | **Go** for slow-to-moderate drills; possible ceiling near 1000°/s per axis |

**Product decision:** users will be required to turn off Automatic Ear Detection. iOS doesn't let apps change this setting, so onboarding must walk users through it, detect when the stream stops after the earbud leaves the ear, and mention the side effects (audio no longer pauses on removal).

## Gate 0C: Build and install without a Mac

| Step | Result | Notes |
| --- | --- | --- |
| GitHub Actions builds unsigned `.ipa` | Pass | XcodeGen + `xcodebuild` on `macos-latest`, free for public repos |
| Sideloadly signs with free Apple ID | Pass | Needed iTunes from apple.com (not Microsoft Store) before the phone was detected |
| App installs and opens on iPhone | Pass | Developer Mode on, Apple ID trusted |
| Update by re-sideloading a new build | Not yet tested | |
| Cost so far | $0 | Free Apple ID installs expire after 7 days |

**Decision:** Go

## Gate 0A: Data stream availability

Only the condition that matters for the product was run three times; the others were skipped once ear detection off was chosen as a requirement.

| Condition | Run? | Notes |
| --- | --- | --- |
| Worn in ear, ear detection on | Spot-checked only | Live stream confirmed before recording |
| Handheld, ear detection on | Skipped | Not needed: product requires ear detection off |
| Handheld, ear detection off | **3 consecutive trials** | See below |
| Open palm, then closed hand | Deferred | Revisit when tuning grip calibration |
| On desk, then rotated by hand | Deferred | Still periods in the trials below serve as a stationary baseline |

Three consecutive handheld trials, ear detection off (go criterion):

| Trial | File | Duration | Rate | Gaps > 100 ms | Est. dropout | Interruptions | Motion visible? |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A | `airswing_handheld-ed-off_20261020-172642.csv` | 71.7 s | 49.8 Hz | 1 (282 ms) | 0.4% | None logged | Yes |
| B | `airswing_handheld-ed-off_20261020-172824.csv` | 69.0 s | 50.0 Hz | 0 | 0.0% | None logged | Yes |
| C | `airswing_handheld-ed-off_20261020-172948.csv` | 67.9 s | 50.0 Hz | 0 | 0.0% | None logged | Yes |

Trial A's file was renamed after export; its internal `condition` line says "Worn in ear" because the picker was left on the default. It was recorded handheld with ear detection off.

In every trial the still–move–still routine is clearly visible: median rotation speed is about 0.0–0.2 rad/s while still and 1–3 rad/s while moving.

Still to do: repeat after reconnecting the AirPods, and on a different day.

**Decision:** Go

## Gate 0B: Sampling and dynamic range

| Test | File | Rate | Interval | Dropout | Peak rotation | Peak accel | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Stationary baseline | Still segments of trials A–C | 50 Hz | 20 ms | 0% | ~0.1 rad/s | — | Low noise at rest |
| Slow orientation changes | Trials A–C | 50 Hz | 20 ms | ≤ 0.4% | 6.4 rad/s | — | |
| Quicker swings + fast motion | `airswing_handheld-ed-off_20261020-173504.csv` | 50.0 Hz | 20 ms, none over 25 ms | 0% | 17.4 rad/s on one axis (18.9 combined) | 9.5 g | No dropouts even at the fastest motion |

Observed rate is a steady 50 Hz, well above the 20 Hz target, and fast motion causes no gaps.

**Possible ceiling:** no axis exceeded 17.45 rad/s, which is exactly 1000°/s. The peaks are rounded, not flat-topped, so there's no clear sign of clipping, but the largest value landing at 1000°/s is suspicious. Several peaks on other axes topped out at 16–17 rad/s. Treat ±1000°/s per axis as a likely sensor limit until proven otherwise: the app should flag any rep that reaches about 16.5 rad/s on an axis as "possibly clipped", and drills should stay at slow-to-moderate speed as the PRD already requires. Acceleration peaks were single samples with no plateaus.

**Decision:** Go for slow-to-moderate tempo drills

## Findings and failure modes

- Off-ear streaming works with Automatic Ear Detection off. Ear detection on was not tested.
- 50 Hz gives 20 ms resolution, enough to place backswing/transition/downswing boundaries well inside the PRD's 250 ms initial target.
- Rotation peaks near 1000°/s may be clipped; full-speed swings are out of scope anyway.
- The app's condition label comes from the picker, so pick the condition before recording rather than renaming files afterwards.
- Windows setup snag: Sideloadly couldn't see the phone until iTunes from apple.com was installed and the laptop restarted.

## Overall M0 decision

**Go.** A handheld AirPods Pro 3 earbud streams reliable motion at 50 Hz to an iPhone, and the app builds and installs from Windows at no cost. Proceed to M1 (calibration, recording, manual rep marking, quality diagnostics), with ear-detection-off onboarding and a clipping flag.

Open follow-ups: reconnect and next-day repeats, re-sideload update test.
