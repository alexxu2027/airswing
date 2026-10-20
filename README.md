# AirSwing

Club-free golf tempo practice using a handheld AirPods Pro 3 earbud as the motion sensor.

**Current stage: M1, the recording tool.** M0 proved a handheld earbud streams reliable motion at 50 Hz with Automatic Ear Detection off ([docs/feasibility.md](docs/feasibility.md)). M1 records practice sessions, detects each swing with an address-pause "Ready" loop, and lets you confirm or reject each detected swing. Those reviews become the answer key for tempo detection in M2.

## What's here

| Path | What it is |
| --- | --- |
| `ios/AirSwing/` | The SwiftUI app: Practice, Sessions and Diagnostics tabs |
| `ios/AirSwingTests/` | Unit tests for detection, calibration, quality stats and storage; run in CI on a simulator |
| `project.yml` | XcodeGen spec; CI generates the Xcode project from it |
| `.github/workflows/ios-build.yml` | Runs the tests, then builds an unsigned `.ipa` on a GitHub-hosted Mac |
| `viewer/` | Browser page for checking recordings, published to GitHub Pages |
| `docs/feasibility.md` | M0 results |

## How a session works

1. **Set your address.** Hold the earbud the way you'd grip a club at address and keep still for 3 seconds. The app remembers that position.
2. **One slow practice swing.** Teaches the app which way your downswing turns (used for tempo in M2). You can skip it.
3. **Swing.** Settle at address and keep still for about a second: the screen turns green and the phone says "Ready". Swing, then hold your finish for half a second. Small waggles don't count. Repeat.
4. **Stop and save**, then open the session in **Sessions** and tap ✓ or ✗ on each detected swing.

The session saves automatically if the AirPods disconnect or you leave the app. The phone screen stays on during a session.

## Build the app (on GitHub)

Every push that touches `ios/` or `project.yml` runs the tests and builds the app. To build by hand: **Actions → iOS build → Run workflow**.

When the run finishes, open it and download **AirSwing-ipa** under Artifacts. Unzip it to get `AirSwing.ipa`.

## Install it on your iPhone (free, from Windows)

1. Install [Sideloadly](https://sideloadly.io) on Windows, plus iTunes from apple.com (not the Microsoft Store app). Restart after installing iTunes.
2. Connect the iPhone by USB and tap **Trust** on the phone.
3. Drag `AirSwing.ipa` into Sideloadly, enter your Apple ID, and click **Start**.
4. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
5. Trust your Apple ID under **Settings → General → VPN & Device Management**.

With a free Apple ID the install expires after 7 days; just sideload again.

## AirPods setup

- Turn off **Automatic Ear Detection** (Settings → your AirPods → Automatic Ear Detection). Motion data stops when the earbud leaves your ear otherwise.
- Hold one earbud and keep the other closed in its case.

## Session files

Each session is a folder under **Files → On My iPhone → AirSwing → Sessions**, and can also be shared from the session screen:

- `session.json`: settings, calibration, detected swings with your ✓/✗ reviews, events, and data quality.
- `samples.csv`: every raw reading. Lines starting with `#` are metadata and events (`# event,<seconds>,<text>`), then:

```
timestamp_s,qw,qx,qy,qz,rot_x,rot_y,rot_z,acc_x,acc_y,acc_z,sensor
```

Timestamps are seconds since the session started; rotation rate is rad/s; user acceleration is in g, as reported by Core Motion. `sensor` is which earbud reported it.

## Check recordings in the browser

Open the viewer at **https://alexxu2027.github.io/airswing/** and drop in one or more `samples.csv` files. It shows sample rate, gaps, estimated dropout, a pass/fail against the data-quality targets, and rotation-rate and sample-interval charts. Files are processed in the browser and never uploaded.
