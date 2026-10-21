"""Replay AirSwing recordings through a Python port of the app's detector, for tuning.

    python tools/analyze.py <session folder or samples.csv> [...] [options]

For each recording: replays address hold -> practice swing -> Ready loop -> phase analysis,
prints every swing with tempo and the signals used for tuning (peak rotation, clipping,
acceleration jumps near impact), checks Mark events against detected swings, and saves a plot.

--fixture NAME copies the recording into ios/AirSwingTests/Fixtures/NAME with an expected.json,
so CI checks the Swift detector gives the same swings and phases (ReplayFixtureTests).

The port mirrors ReadyDetector.swift, Phases.swift, Quality.swift and SessionStats.swift
operation for operation. Change both together.
"""

import argparse
import json
import math
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "ios" / "AirSwingTests" / "Fixtures"

# DetectionSettings defaults (Session.swift).
HANDHELD = {
    "stillSpeed": 0.5,
    "readyHold": 0.8,
    "addressToleranceDegrees": 35.0,
    "swingStartSpeed": 1.0,
    "minPeakSpeed": 5.0,
    "finishHold": 0.5,
    "maxSwingDuration": 6.0,
    "clipSpeed": 16.5,
}
GLOVE = {**HANDHELD, "impactJump": 2.0}

GAP_THRESHOLD = 0.1
DOWNSWING_END_FRACTION = 0.3
MIN_BACKSWING_RATE = 0.5
BACKSWING_RANGE = (0.25, 3.0)
DOWNSWING_RANGE = (0.08, 1.5)
IMPACT_BEFORE = 0.10
IMPACT_AFTER = 0.15
CONFIDENCE = ["none", "low", "medium", "high"]


# MARK: Samples and quaternions

@dataclass
class Sample:
    t: float
    q: tuple
    rx: float
    ry: float
    rz: float
    ax: float
    ay: float
    az: float

    @property
    def speed(self):
        return math.sqrt(self.rx * self.rx + self.ry * self.ry + self.rz * self.rz)

    @property
    def rotation(self):
        return [self.rx, self.ry, self.rz]


def read_csv(path):
    samples, meta, events, saw_header = [], {}, [], False
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        if line.startswith("#"):
            body = line[1:].strip()
            if body.startswith("event,"):
                _, t, *msg = body.split(",")
                events.append((float(t), ",".join(msg)))
            elif "=" in body:
                k, v = body.split("=", 1)
                meta[k] = v
            continue
        if not saw_header:
            saw_header = True
            continue
        f = line.split(",")
        if len(f) < 12:
            continue
        try:
            d = [float(x) for x in f[:11]]
        except ValueError:
            continue
        samples.append(Sample(d[0], (d[1], d[2], d[3], d[4]), d[5], d[6], d[7], d[8], d[9], d[10]))
    return samples, meta, events


def q_normalized(q):
    w, x, y, z = q
    n = math.sqrt(w * w + x * x + y * y + z * z)
    return (w / n, x / n, y / n, z / n) if n > 0 else (1.0, 0.0, 0.0, 0.0)


def q_dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]


def q_angle(a, b):
    d = min(1.0, abs(q_dot(q_normalized(a), q_normalized(b))))
    return 2 * math.acos(d)


def q_average(qs):
    if not qs:
        return None
    ref = qs[0]
    w = x = y = z = 0.0
    for q in qs:
        k = -1.0 if q_dot(q, ref) < 0 else 1.0
        w += k * q[0]
        x += k * q[1]
        y += k * q[2]
        z += k * q[3]
    return q_normalized((w, x, y, z))


class SpeedSmoother:
    def __init__(self, window=0.1):
        self.window = window
        self.buffer = []
        self.sum = 0.0

    def add(self, t, speed):
        self.buffer.append((t, speed))
        self.sum += speed
        while self.buffer and t - self.buffer[0][0] > self.window + 1e-9:
            self.sum -= self.buffer[0][1]
            self.buffer.pop(0)
        return self.sum / len(self.buffer)


# MARK: Detection (ReadyDetector.swift)

class AddressCalibrator:
    def __init__(self, still_speed, hold=3.0):
        self.still_speed = still_speed
        self.hold = hold
        self.smoother = SpeedSmoother()
        self.held = []

    def process(self, s):
        if not self.smoother.add(s.t, s.speed) < self.still_speed:
            self.held = []
            return None
        self.held.append(s)
        span = s.t - self.held[0].t
        if span < self.hold:
            return None
        address = q_average([h.q for h in self.held])
        rest = 0.0
        for h in self.held:
            rest += h.speed
        return {"completedAt": s.t, "address": address, "restNoise": rest / len(self.held)}


def dominant_axis(s):
    r = s.rotation
    axis = 0
    for i in (1, 2):
        if abs(r[axis]) < abs(r[i]):
            axis = i
    return axis, (1 if r[axis] >= 0 else -1)


@dataclass
class Rep:
    ready_time: float
    start: float
    end: float
    peak_speed: float
    peak_time: float
    possibly_clipped: bool
    timed_out: bool
    analysis: dict = field(default=None)


class ReadyDetector:
    ADDRESS_MEMORY = 4

    def __init__(self, address, settings):
        self.address = address
        self.calibrated = address
        self.st = settings
        self.state = "notReady"
        self.smoothed = 0.0
        self.degrees = 0.0
        self.recent = []
        self.smoother = SpeedSmoother()
        self.state_since = 0.0
        self.last_still_time = 0.0
        self.last_still_pose = (1.0, 0.0, 0.0, 0.0)
        self.start_pose = (1.0, 0.0, 0.0, 0.0)
        self.ready_time = self.swing_start = self.peak_speed = self.peak_time = self.peak_axis = 0.0

    def process(self, s):
        st = self.st
        speed = self.smoother.add(s.t, s.speed)
        self.smoothed = speed
        self.degrees = q_angle(s.q, self.address) * 180 / math.pi
        still = self.smoothed < st["stillSpeed"]
        if still:
            self.last_still_time = s.t
            self.last_still_pose = s.q
        near = self.degrees <= st["addressToleranceDegrees"]

        events = []
        state = self.state
        if state == "notReady":
            if still and near:
                self.enter("settling", s.t)
        elif state == "settling":
            if not (still and near):
                self.enter("notReady", s.t)
            elif s.t - self.state_since >= st["readyHold"]:
                self.enter("ready", s.t)
                self.ready_time = s.t
                events.append(("ready", s.t))
        elif state == "ready":
            if speed >= st["swingStartSpeed"]:
                self.enter("swinging", s.t)
                self.swing_start = self.last_still_time
                self.start_pose = self.last_still_pose
                self.peak_speed = 0.0
                self.peak_axis = 0.0
                self.track(s)
                events.append(("swingStarted", self.swing_start))
            elif still and not near:
                self.enter("notReady", s.t)
                events.append(("lostReady", s.t))
        elif state == "swinging":
            self.track(s)
            if still:
                self.enter("finishing", s.t)
            elif s.t - self.swing_start >= st["maxSwingDuration"]:
                events.append(self.finish(s.t, True))
        elif state == "finishing":
            self.track(s)
            if not still:
                self.enter("swinging", s.t)
            elif s.t - self.state_since >= st["finishHold"]:
                events.append(self.finish(self.state_since, False))
        return events

    def enter(self, state, t):
        self.state = state
        self.state_since = t

    def track(self, s):
        if s.speed > self.peak_speed:
            self.peak_speed = s.speed
            self.peak_time = s.t
        self.peak_axis = max(self.peak_axis, abs(s.rx), abs(s.ry), abs(s.rz))

    def finish(self, end, timed_out):
        self.enter("notReady", end)
        if self.peak_speed < self.st["minPeakSpeed"]:
            return ("waggle", end)
        self.recent.append(self.start_pose)
        if len(self.recent) > self.ADDRESS_MEMORY:
            self.recent.pop(0)
        self.address = q_average([self.calibrated] + self.recent) or self.calibrated
        return ("rep", Rep(self.ready_time, self.swing_start, end, self.peak_speed, self.peak_time,
                           self.peak_axis >= self.st["clipSpeed"], timed_out))


# MARK: Phases (Phases.swift)

def window(samples, start, end):
    lo, hi = 0, len(samples)
    while lo < hi:
        mid = (lo + hi) // 2
        if samples[mid].t < start:
            lo = mid + 1
        else:
            hi = mid
    stop = lo
    while stop < len(samples) and samples[stop].t <= end:
        stop += 1
    return samples[lo:stop]


def crossing(t, v, i, level):
    if i + 1 >= len(v) or v[i + 1] == v[i]:
        return t[i]
    f = (level - v[i]) / (v[i + 1] - v[i])
    return t[i] + max(0.0, min(1.0, f)) * (t[i + 1] - t[i])


def first_max(values):
    best = 0
    for i in range(1, len(values)):
        if values[best] < values[i]:
            best = i
    return best


def accel_jump(a, b):
    return math.sqrt((a.ax - b.ax) * (a.ax - b.ax) + (a.ay - b.ay) * (a.ay - b.ay) + (a.az - b.az) * (a.az - b.az))


def impact_index(samples, top, peak_time, jump):
    best_i, best = None, 0.0
    for i in range(max(top + 1, 1), len(samples)):
        dt = samples[i].t - peak_time
        if dt < -IMPACT_BEFORE:
            continue
        if dt > IMPACT_AFTER:
            break
        d = accel_jump(samples[i], samples[i - 1])
        if d > best:
            best_i, best = i, d
    return best_i if best_i is not None and best >= jump else None


def plateau_center(v, p):
    level = v[p] * 0.98
    lo = hi = p
    while lo > 0 and v[lo - 1] >= level:
        lo -= 1
    while hi + 1 < len(v) and v[hi + 1] >= level:
        hi += 1
    return (lo + hi) // 2


def analyze_phases(samples, rep, known_axis, st):
    if known_axis is not None:
        axis, sign = known_axis
    elif samples:
        axis, sign = dominant_axis(samples[first_max([s.speed for s in samples])])
    else:
        axis, sign = 0, 1

    def fail(issue):
        return {"phases": None, "confidence": "none", "issues": [issue], "axis": axis, "sign": sign}

    if len(samples) < 5:
        return fail("Too few samples in this swing.")
    if any(b.t - a.t > GAP_THRESHOLD for a, b in zip(samples, samples[1:])):
        return fail("Motion data had a gap during this swing.")

    t = [s.t for s in samples]
    v = [float(sign) * s.rotation[axis] for s in samples]
    p = first_max(v)
    if v[p] < st["minPeakSpeed"] * 0.5:
        return fail("No clear downswing on the swing axis.")
    k = next((i for i in range(p - 1, -1, -1) if v[i] <= 0), None)
    if k is None:
        return fail("No backswing before the downswing.")
    top = crossing(t, v, k, 0)

    issues, conf = [], 3
    impact = None
    if st.get("impactJump") is not None:
        peak = plateau_center(v, p)
        impact = impact_index(samples, k, t[peak], st["impactJump"])
        if impact is not None:
            end = t[impact]
        else:
            end = t[peak]
            issues.append("No impact found, so the downswing ends at peak rotation.")
    else:
        level = DOWNSWING_END_FRACTION * v[p]
        j = next((i for i in range(p + 1, len(v)) if v[i] <= level), None)
        if j is not None:
            end = crossing(t, v, j - 1, level)
        else:
            end = t[-1]
            issues.append("The downswing didn't settle before the swing ended.")
            conf = 1

    back = v[: k + 1]
    if min(back) > -MIN_BACKSWING_RATE:
        issues.append("The backswing barely registered on the swing axis.")
        conf = 1
    if any(x > MIN_BACKSWING_RATE for x in back):
        issues.append("Several direction changes before the downswing.")
        conf = 1

    backswing, downswing = top - rep.start, end - top
    if not BACKSWING_RANGE[0] <= backswing <= BACKSWING_RANGE[1]:
        issues.append(f"Unusual backswing length ({backswing:.2f} s).")
        conf = 1
    if not DOWNSWING_RANGE[0] <= downswing <= DOWNSWING_RANGE[1]:
        issues.append(f"Unusual downswing length ({downswing:.2f} s).")
        conf = 1
    if rep.possibly_clipped:
        issues.append("Peak rotation may have exceeded the sensor's range.")
        conf = min(conf, 2)

    return {"phases": {"start": rep.start, "top": top, "downswingEnd": end}, "confidence": CONFIDENCE[conf],
            "issues": issues, "axis": axis, "sign": sign, "impact": impact is not None}


# MARK: Swing arc (SwingArc.swift)

def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _unit(a):
    n = math.sqrt(_dot(a, a))
    return (a[0] / n, a[1] / n, a[2] / n)


def q_rotate(q, v):
    w, qv = q[0], q[1:]
    t = tuple(2 * c for c in _cross(qv, v))
    c = _cross(qv, t)
    return (v[0] + w * t[0] + c[0], v[1] + w * t[1] + c[1], v[2] + w * t[2] + c[2])


def swing_arc(samples, phases):
    """(t, angle, offPlane) per sample; the backswing turns positive. None if there's no clear plane."""
    if len(samples) < 5:
        return None
    world = [q_rotate(s.q, (s.rx, s.ry, s.rz)) for s in samples]
    peak = world[first_max([_dot(x, x) for x in world])]
    total = [0.0, 0.0, 0.0]
    for x in world:
        k = 1 if _dot(x, peak) >= 0 else -1
        total = [total[i] + k * x[i] for i in range(3)]
    if _dot(total, total) == 0:
        return None
    n = _unit(total)
    other = [0.0, 0.0, 0.0]
    other[min(range(3), key=lambda i: abs(n[i]))] = 1.0
    u = _unit(_cross(n, other))
    v = _cross(n, u)
    q0 = samples[0].q
    pointer = q_rotate((q0[0], -q0[1], -q0[2], -q0[3]), u)
    points, prev = [], None
    for s in samples:
        p = q_rotate(s.q, pointer)
        a = math.atan2(_dot(p, v), _dot(p, u))
        if prev is not None:
            while a - prev > math.pi:
                a -= 2 * math.pi
            while a - prev < -math.pi:
                a += 2 * math.pi
        prev = a
        points.append((s.t, a, math.asin(max(-1.0, min(1.0, _dot(p, n))))))
    top = min(points, key=lambda x: abs(x[0] - phases["top"]))
    if top[1] < 0:
        points = [(t, -a, -o) for t, a, o in points]
    return points


# MARK: Replay (SessionReplay.swift)

def replay(samples, st, practice_swing):
    calibrator = AddressCalibrator(st["stillSpeed"])
    detector, calibration, awaiting = None, None, practice_swing
    reps, waggles = [], 0
    for s in samples:
        if detector is None:
            c = calibrator.process(s)
            if c is not None:
                calibration = c
                detector = ReadyDetector(c["address"], st)
            continue
        for kind, value in detector.process(s):
            if kind == "waggle":
                waggles += 1
            elif kind == "rep" and awaiting:
                awaiting = False
                calibration["practiceRep"] = value
                peak = next((x for x in samples if x.t == value.peak_time), None)
                if peak is not None:
                    calibration["axis"] = dominant_axis(peak)
            elif kind == "rep":
                value.analysis = analyze_phases(window(samples, value.start, value.end), value,
                                                calibration.get("axis"), st)
                reps.append(value)
    return calibration, reps, waggles


# MARK: Reporting

def tempo(rep):
    a = rep.analysis
    if not a or not a["phases"] or CONFIDENCE.index(a["confidence"]) < 2:
        return None
    p = a["phases"]
    down = p["downswingEnd"] - p["top"]
    return (p["top"] - p["start"]) / down if down > 0 else None


def diagnostics(samples, rep, st):
    """Signals for tuning: where rotation peaks, how long it clips, and the biggest acceleration jumps."""
    w = window(samples, rep.start, rep.end)
    a = rep.analysis or {}
    axis, sign = a.get("axis", 0), a.get("sign", 1)
    v = [sign * s.rotation[axis] for s in w]
    p = first_max(v) if v else 0
    clipped = sum(1 for s in w if max(abs(s.rx), abs(s.ry), abs(s.rz)) >= st["clipSpeed"])
    jumps = sorted(((accel_jump(w[i], w[i - 1]), w[i].t) for i in range(1, len(w))), reverse=True)[:2]
    acc = max((math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az) for s in w), default=0)
    peak_t = w[p].t if w else 0
    return {
        "peakAxis": v[p] if v else 0,
        "clippedSamples": clipped,
        "maxAcc": acc,
        "jumps": [(j, t - peak_t) for j, t in jumps],
    }


def report(name, samples, meta, events, st, practice_swing, calibration, reps, waggles, truth):
    marks = [(t, m) for t, m in events if m.startswith("mark ")]
    print(f"\n=== {name}")
    for key in ("condition", "mount", "club", "note"):
        if meta.get(key):
            print(f"  {key}: {meta[key]}")
    duration = samples[-1].t - samples[0].t if samples else 0
    print(f"  {len(samples)} samples over {duration:.1f} s; settings: "
          + ", ".join(f"{k}={v}" for k, v in st.items() if HANDHELD.get(k) != v))
    if calibration is None:
        print("  !! address never set (no 3 s still hold), so nothing was detected")
        return
    print(f"  address set at {calibration['completedAt']:.2f} s; practice swing: "
          + ("used" if practice_swing and "practiceRep" in calibration else "skipped/none")
          + (f"; swing axis {'+-'[calibration['axis'][1] < 0]}{'xyz'[calibration['axis'][0]]}" if "axis" in calibration else ""))
    print(f"  {len(reps)} swings, {waggles} waggles" + (f"; truth {truth} swings" if truth is not None else ""))
    print("   #  start    back   down  tempo  conf    impact clip  peak  maxAcc  top jumps (g @ s from peak)")
    for i, r in enumerate(reps, 1):
        a, d = r.analysis, diagnostics(samples, r, st)
        p = a["phases"]
        back = f"{p['top'] - p['start']:.2f}" if p else "  —"
        down = f"{p['downswingEnd'] - p['top']:.2f}" if p else "  —"
        tp = tempo(r)
        jumps = "  ".join(f"{j:.1f}@{dt:+.2f}" for j, dt in d["jumps"])
        print(f"  {i:2d} {r.start:7.2f}  {back:>5}  {down:>5}  {f'{tp:.2f}' if tp else '   —':>5}  {a['confidence']:<6}  "
              f"{'yes' if a.get('impact') else 'no':<5}  {d['clippedSamples']:3d}  {d['peakAxis']:5.1f}  {d['maxAcc']:5.1f}   {jumps}"
              + ("  TIMED OUT" if r.timed_out else ""))
        for issue in a["issues"]:
            print(f"        - {issue}")
    tempos = sorted(x for x in (tempo(r) for r in reps) if x)
    if tempos:
        print(f"  median tempo {tempos[len(tempos) // 2]:.2f}:1 from {len(tempos)} of {len(reps)} swings")
    for t, m in marks:
        before = [i for i, r in enumerate(reps, 1) if r.end <= t and t - r.end <= 5]
        print(f"  {m} at {t:.2f} s: " + (f"after swing {before[-1]}" if before else "no swing in the 5 s before (missed?)"))


def plot(path, name, samples, events, st, reps):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    n = len(reps)
    fig, axes = plt.subplots(1 + n, 2, figsize=(14, 3 + 2.4 * n), squeeze=False,
                             gridspec_kw={"width_ratios": [5, 1]})
    axes[0][1].axis("off")
    ax = axes[0][0]
    t = [s.t for s in samples]
    ax.plot(t, [s.speed for s in samples], lw=0.6, color="#555")
    for i, r in enumerate(reps, 1):
        ax.axvspan(r.start, r.end, color="#4a90d9", alpha=0.2)
        ax.text(r.start, ax.get_ylim()[1] * 0.9 if ax.get_ylim()[1] else 1, str(i), fontsize=8)
    for et, m in events:
        if m.startswith("mark "):
            ax.axvline(et, color="#d94a4a", lw=1)
    ax.axhline(st["clipSpeed"], color="#d9a54a", lw=0.6, ls="--")
    ax.set_title(f"{name}: rotation speed (rad/s), swings shaded, marks red")
    for i, r in enumerate(reps, 1):
        ax = axes[i][0]
        w = window(samples, r.start - 0.3, r.end + 0.3)
        a = r.analysis
        tt = [s.t for s in w]
        ax.plot(tt, [a["sign"] * s.rotation[a["axis"]] for s in w], color="#4a90d9", lw=1, label="swing axis rad/s")
        ax2 = ax.twinx()
        ax2.plot(tt, [math.sqrt(s.ax ** 2 + s.ay ** 2 + s.az ** 2) for s in w], color="#999", lw=0.8, label="|acc| g")
        ax2.plot(tt[1:], [accel_jump(w[j], w[j - 1]) for j in range(1, len(w))], color="#d94a4a", lw=0.8, label="acc jump g")
        if a["phases"]:
            for key, c in (("start", "k"), ("top", "g"), ("downswingEnd", "m")):
                ax.axvline(a["phases"][key], color=c, lw=1, ls="--")
        tp = tempo(r)
        ax.set_title(f"swing {i}: {a['confidence']}" + (f", tempo {tp:.2f}:1" if tp else "")
                     + (" (impact)" if a.get("impact") else ""), fontsize=9)
        ax.axhline(0, color="#ccc", lw=0.5)
        if i == 1:
            ax.legend(loc="upper left", fontsize=7)
            ax2.legend(loc="upper right", fontsize=7)
        arc_ax = axes[i][1]
        arc_ax.axis("off")
        arc_ax.set_aspect("equal")
        p = a["phases"]
        arc = swing_arc(window(samples, p["start"], r.end), p) if p else None
        if arc:
            def xy(points):
                rs = [min(1.4, max(0.6, 1 - o)) for _, _, o in points]
                return ([-r_ * math.sin(an) for r_, (_, an, _) in zip(rs, points)],
                        [-r_ * math.cos(an) for r_, (_, an, _) in zip(rs, points)])
            top_i = min(range(len(arc)), key=lambda j: abs(arc[j][0] - p["top"]))
            end_i = max(top_i, min(range(len(arc)), key=lambda j: abs(arc[j][0] - p["downswingEnd"])))
            for seg, color, width in ((arc[end_i:], "#f3c1a8", 2), (arc[: top_i + 1], "#999", 2.5), (arc[top_i: end_i + 1], "#e0672f", 3)):
                arc_ax.plot(*xy(seg), color=color, lw=width)
            arc_ax.set_xlim(-1.5, 1.5)
            arc_ax.set_ylim(-1.5, 1.5)
            arc_ax.set_title(f"turn {math.degrees(arc[top_i][1]):.0f}°", fontsize=9)
    fig.tight_layout()
    fig.savefig(path, dpi=90)
    plt.close(fig)


def write_fixture(fixture, csv_path, st, practice_swing, reps, waggles):
    folder = FIXTURES / fixture
    folder.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(csv_path, folder / "samples.csv")
    swings = []
    for r in reps:
        p = r.analysis["phases"]
        swings.append({
            "start": r.start, "end": r.end, "peakTime": r.peak_time, "possiblyClipped": r.possibly_clipped,
            "top": p["top"] if p else None, "downswingEnd": p["downswingEnd"] if p else None,
            "confidence": r.analysis["confidence"],
        })
    expected = {"practiceSwing": practice_swing, "settings": st, "swings": swings, "waggles": waggles}
    (folder / "expected.json").write_text(json.dumps(expected, indent=2) + "\n", encoding="utf-8")
    print(f"  wrote fixture {folder.relative_to(REPO)}")


def load(path):
    """A session folder (session.json + samples.csv) or a bare samples.csv."""
    path = Path(path)
    csv_path = path / "samples.csv" if path.is_dir() else path
    session = None
    if (csv_path.parent / "session.json").exists():
        session = json.loads((csv_path.parent / "session.json").read_text(encoding="utf-8"))
    return csv_path, session


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="session folders or samples.csv files")
    ap.add_argument("--mount", choices=["handheld", "glove"], help="settings preset (default: what the session recorded)")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE", help="override a detection setting")
    ap.add_argument("--practice-swing", choices=["yes", "no"], help="default: from session.json, else no")
    ap.add_argument("--truth", type=int, help="how many real swings the recording has")
    ap.add_argument("--fixture", help="save as ios/AirSwingTests/Fixtures/NAME (one input only)")
    ap.add_argument("--plot", default="analysis", help="folder for plots, next to each input (empty to skip)")
    args = ap.parse_args()
    if args.fixture and len(args.inputs) != 1:
        sys.exit("--fixture takes exactly one input")

    for inp in args.inputs:
        csv_path, session = load(inp)
        samples, meta, events = read_csv(csv_path)
        if args.mount:
            st = dict(GLOVE if args.mount == "glove" else HANDHELD)
        elif session:
            st = {**HANDHELD, **{k: v for k, v in session.get("settings", {}).items() if v is not None}}
        else:
            st = dict(GLOVE if meta.get("mount") == "glove" else HANDHELD)
        for kv in args.set:
            k, v = kv.split("=", 1)
            if k not in GLOVE:
                sys.exit(f"unknown setting {k}; known: {', '.join(GLOVE)}")
            st[k] = None if v == "none" else float(v)
        st = {k: v for k, v in st.items() if v is not None}
        if args.practice_swing:
            practice = args.practice_swing == "yes"
        else:
            practice = bool(session and (session.get("calibration") or {}).get("practiceRep"))

        calibration, reps, waggles = replay(samples, st, practice)
        name = session.get("name") if session else csv_path.name
        report(name, samples, meta, events, st, practice, calibration, reps, waggles, args.truth)
        if args.plot and reps:
            out = csv_path.parent / args.plot
            out.mkdir(exist_ok=True)
            png = out / (csv_path.parent.name + ".png" if csv_path.name == "samples.csv" else csv_path.stem + ".png")
            plot(png, name, samples, events, st, reps)
            print(f"  plot: {png}")
        if args.fixture:
            write_fixture(args.fixture, csv_path, st, practice, reps, waggles)


if __name__ == "__main__":
    main()
