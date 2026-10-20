# AirSwing

Club-free golf tempo practice using a handheld AirPods Pro 3 earbud as the motion sensor.

**Current stage: M0 feasibility spike.** Before building the app, we have to prove that an AirPod held in the hand streams usable motion data to an iPhone, and that the app can be built and installed without a Mac. Results go in [docs/feasibility.md](docs/feasibility.md).

## What's here

| Path | What it is |
| --- | --- |
| `ios/AirSwingProbe/` | One-screen SwiftUI app: shows AirPods motion status and live values, records trials, exports CSV |
| `project.yml` | XcodeGen spec; CI generates the Xcode project from it |
| `.github/workflows/ios-build.yml` | Builds an unsigned `.ipa` on a GitHub-hosted Mac |
| `viewer/` | Browser page for checking recordings, published to GitHub Pages |
| `docs/feasibility.md` | Gate 0 results template |

## Build the app (on GitHub)

Every push that touches `ios/` or `project.yml` builds the app. To build by hand: **Actions → iOS build → Run workflow**.

When the run finishes, open it and download **AirSwingProbe-ipa** under Artifacts. Unzip it to get `AirSwingProbe.ipa`.

## Install it on your iPhone (free, from Windows)

1. Install [Sideloadly](https://sideloadly.io) on Windows, plus the iTunes and iCloud versions it asks for (the downloads from Apple, not the Microsoft Store apps).
2. Connect the iPhone by USB and tap **Trust** on the phone.
3. Drag `AirSwingProbe.ipa` into Sideloadly, enter your Apple ID, and click **Start**.
4. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
5. Trust your Apple ID under **Settings → General → VPN & Device Management**.

With a free Apple ID the install expires after 7 days; just sideload again.

## Run a trial

1. Pair AirPods Pro 3 with the iPhone, open AirSwing Probe, and allow motion access.
2. Put one earbud in your ear first to confirm the stream works (live rate shows a number).
3. Pick a condition, tap **Start recording**, hold for 30+ seconds, tap **Stop and save**.
4. Tap the saved file to share it (AirDrop, Files, email) to your laptop. Files also appear in the Files app under **On My iPhone → AirSwing Probe**.

Keep motions slow and the earbud held securely. Don't swing at full speed.

## Check recordings in the browser

Open the viewer at **https://alexxu2027.github.io/airswing/** and drop in one or more CSVs. It shows the effective sample rate, gaps, estimated dropout, a pass/fail against the Gate 0A/0B targets, and rotation-rate and sample-interval charts. Files are processed in the browser and never uploaded.

## CSV format

Lines starting with `#` are metadata and events (`# event,<seconds>,<text>`). Then one header row and one row per sample:

```
timestamp_s,qw,qx,qy,qz,rot_x,rot_y,rot_z,acc_x,acc_y,acc_z,sensor
```

Timestamps are seconds since recording started; rotation rate is rad/s; user acceleration is in g, as reported by Core Motion. `sensor` is which earbud Core Motion reports (`left`, `right` or `default`).
