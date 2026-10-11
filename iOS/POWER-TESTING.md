# Power testing (test builds only)

How much battery does an always-open microphone (an idle LocalFlow session) and
transcription cost? Two tools answer this together (ARCHITECTURE.md, "Power
log"):

- **The power log.** A test build records content-free proxies to a CSV while
  LocalFlow runs, over days of normal use. An agent analyzes the CSV.
- **Apple's Power Profiler.** It gives exact per-subsystem energy impact for
  short controlled runs.

The power log holds numbers and enums only: battery level and state, thermal
state, Low Power Mode, process CPU time, memory, host and app state, the build
number and the hardware model. It never holds audio, text, transcripts, or
field or app context. It stays on the phone until you export it.

## Build

`POWER_LOG=1` compiles the recorder into the host app only, never the
keyboard. The default is `0`, and production builds must stay `0`. Changing it
rebuilds automatically.

```bash
make -C iOS all PLATFORM=device POWER_LOG=1 "${SIGN[@]}"     # SIGN as in README.md → Device
make -C iOS install-device PLATFORM=device POWER_LOG=1 "${SIGN[@]}" DEVICE=<name or id>
```

To publish to the OTA page, add `POWER_LOG=1` to the `make -C iOS all` line of
the publish script.

Check a build before you publish it:

```bash
nm iOS/build/device/obj/LocalFlow | grep -c PowerRecorder   # > 0 power build, 0 normal build
```

In a power build, Diagnostics has a **Power (test build)** section.

## Collect

The phone records whenever LocalFlow runs, so daily use already produces data.
A fair, controlled comparison needs matched conditions, because the display
usually costs more than the microphone.

LocalFlow ends a session when the phone locks and after at most 60 minutes
without dictation. So the microphone can only stay open with the **screen on**,
and the baseline must have the screen on too.

1. Charge to at least 80 %, then unplug. Charging intervals never count.
2. Fix the conditions for both runs and write them down:
   - brightness (Auto-Brightness off)
   - Settings → Display & Brightness → Auto-Lock: Never
   - Wi-Fi, Bluetooth and Low Power Mode
   - no media playing
   - the same static screen in front, for example one Notes page
3. **Run A, microphone open, at least 2 h.**
   1. In LocalFlow, set Session length to 60 min and tap Start session.
   2. Switch to the static screen and leave the phone untouched.
   3. Dictate once every 50 minutes or so to keep the session alive; the log
      separates the dictation from the open-microphone time.
4. **Run B, baseline, at least 2 h.** End the session, or don't start one. Send
   LocalFlow to the background, then use the same static screen for the same
   time. Suspended time is logged as "LocalFlow inactive".
5. Note the start and end times of each run and anything else that happened:
   calls, other apps, a warm room, a change of network. Run A and B on the same
   day and in alternating order if you repeat them.
6. Optional: a screen-off baseline overnight, which shows the phone's own idle
   drain.

The in-app summary needs at least 1 h and a 3-point drop before it shows a
rate. Its baseline uses all inactive time, including screen-off nights, so its
always-open projection is only a first look. Use matched windows (below) for
the real figure.

## Retrieve

Export from the phone with Diagnostics → Power → Export log, which opens the
share sheet with both files.

Or copy over the pairing from the Mac, which works over SSH. Use the device
name from `xcrun devicectl list devices` and the app's `BUNDLE_ID`. Paths are
relative to the app's data container.

```bash
mkdir -p ~/localflow-power
for f in power-log.1.csv power-log.csv; do   # the rotated file may not exist
  xcrun devicectl device copy from --device "<device name or id>" \
    --domain-type appDataContainer --domain-identifier com.ajbarryiii.localflow.ios.dev \
    --source "Library/Application Support/PowerLog/$f" --destination ~/localflow-power/$f
done
```

The phone must be unlocked, or have been unlocked since it booted. The files
are never in the App Group.

## Analyze

`power-log.csv` is the current file. `power-log.1.csv`, when present, is the
older file (the log rotates at 4 MB, about two weeks). Read the older file
first. Each file starts with the header row, then `# schema=1`. Skip lines
starting with `#`, and ignore a last line that has no final newline (a write
cut short). Fields with a comma are quoted (`"iPhone16,1"`). Decimals always
use `.`.

| Column | Meaning |
| --- | --- |
| `wall_time` | ISO 8601 UTC, milliseconds |
| `uptime_s` | monotonic seconds, counting sleep; comparable within one process run only |
| `trigger` | `periodic` (60 s), `state`, `battery`, `thermal`, `powerMode`, `launch`, `foreground`, `background`, `terminate` |
| `host_state` | `idle` (no audio session), `micOpen` (session, no dictation), `recording`, `transcribing`, `preparing` (model load or compile) |
| `app_state` | `foreground` or `background` |
| `battery_level` | `UIDevice.batteryLevel`, 0–1, `-1` when unknown |
| `battery_state` | `unplugged`, `charging`, `full`, `unknown` |
| `low_power_mode` | `true` or `false` |
| `thermal_state` | `nominal`, `fair`, `serious`, `critical` |
| `cpu_user_s`, `cpu_system_s` | the process's cumulative CPU time; restarts at 0 with each launch |
| `memory_mb`, `memory_peak_mb` | footprint as jetsam counts it; empty if unavailable |
| `compute_units` | `cpuAndNeuralEngine` or `cpuOnly` while a model runtime is loaded, else empty |
| `build`, `device` | `CFBundleVersion` and the hardware model |

A sample is taken at every transition, so each interval between two
consecutive rows belongs to the **first** row's state. The in-app summary
(`HostCore/PowerLogSummary.swift`) uses these rules:

- **Process runs.** A new run starts at a `launch` row, or where `uptime_s` or
  the CPU sum goes backwards. Within a run, use `uptime_s` differences; across
  runs only `wall_time` exists.
- **Inactive.** An interval starting at a `terminate` row, or at
  `background` + `idle`, is LocalFlow suspended or not running: the baseline.
- **Unknown.** Awake states with no row for more than 10 minutes (the 60 s
  timer did not fire), and runs that ended without a `terminate` row while
  active, are unknown: leave them out.
- **Drain.** Use only intervals with `unplugged` at both ends, known levels,
  and no level rise (a rise means it charged in between). Rate = points
  dropped ÷ hours.
- **CPU.** Use deltas of `cpu_user_s + cpu_system_s` within a run.
  Transcriptions are the entries into `transcribing`.

Report:

- For each controlled run (the times from Collect), the drain rate in %/h.
  The open-microphone cost is rate(A) − rate(B), and × 24 for a day.
- Per-state time, CPU seconds, and CPU seconds per transcription.
- Memory peaks.
- Thermal or Low Power Mode changes that may explain outliers.
- Uncertainty. Levels are coarse (look at the distinct values). Battery
  percentage is not linear in energy, temperature shifts it, and 2 h runs give
  only a few points of drop.

Two caveats:

- **CPU time is not energy.** iOS charges the microphone and audio hardware to
  system daemons, not to LocalFlow.
- **Neural Engine work is not process CPU time.** The CPU columns understate
  transcription cost; only the battery drain and Power Profiler's system lane
  include it.

## Power Profiler (Apple, iOS 26 or later)

Steps from Apple's [Measuring your app's power use with Power
Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)
and WWDC25 session 226, [Profile and optimize power usage in your
app](https://developer.apple.com/videos/play/wwdc2025/226/).

1. Turn on Developer Mode (Settings → Privacy & Security; the phone must have
   been connected to Xcode once).
2. Settings → Developer → Performance Trace: turn on Performance Trace, set the
   tracing mode to **Power Profiler**, and turn on the switch next to LocalFlow
   in the monitored apps.
   - Apple lists apps installed by Xcode, TestFlight or enterprise
     distribution; check that a `devicectl`/OTA development build appears.
   - With no app selected, only system power is recorded.
3. Open Control Center → + → Add a Control → **Performance Trace**.
4. Tap the control to start, do the run (Run A or B above, or a series of
   dictations), and tap it again to stop. A trace can last up to 10 hours.
5. Settings → Developer → Performance Trace → the Share button next to the
   trace: AirDrop it to the Mac. Double-click it in Finder to expand it, then
   open the result in Instruments.

Record away from Xcode. A phone paired with Xcode is kept awake, and sleep
periods then never appear.

What each lane tells you:

- **System Power Usage** (whole device, % of battery per hour): the only lane
  that includes the microphone and audio hardware and Neural Engine work.
  Select a region to see its average. Compare a micOpen region with a
  no-session region in the same screen state to get the microphone's cost.
  Compare dictation bursts with micOpen around them to get transcription's
  cost.
- **Track markers** (charger connected, thermal state, display brightness,
  periods when Apple silicon is asleep). An open session should prevent
  sleep; sleep periods returning after the session ends show what the open
  microphone takes away. Discard charging regions.
- **LocalFlow's CPU Power Impact:** the audio tap, the decoder and the Swift
  work around Core ML. It spikes during transcription and preparation, and
  should stay near zero while micOpen is idle.
- **LocalFlow's GPU Power Impact:** should be near zero; the model runs on the
  Neural Engine.
- **LocalFlow's Display Power Impact:** LocalFlow's own screens (onboarding,
  bounce) while in front.
- **LocalFlow's Networking Power Impact:** should be zero; LocalFlow has no
  network code.

There is no Neural Engine lane and no audio lane. Neural Engine transcription
and microphone cost appear only in System Power Usage. Per-app impact values
are scores comparable on one device model only.
