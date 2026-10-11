import Foundation

/// What the power log says about battery cost (test builds only). Every interval between consecutive
/// samples belongs to the first sample's state, because a sample is taken at every transition.
///
/// - Within a process run, durations come from the monotonic clock, so wall-clock changes do not
///   distort them. A new run starts at a `launch` row, or wherever uptime or cumulative CPU time goes
///   backwards (a launch row lost with a killed process's buffer).
/// - An interval is **inactive** (the "LocalFlow inactive" baseline) when the process was suspended or
///   not running: it starts at a `terminate` row, or in the background with no session, where nothing
///   keeps the app running. Across runs its length comes from wall time; a negative one is dropped.
/// - An interval is **unknown**, and counted nowhere else, when an awake state went unsampled for
///   longer than `maxAwakeInterval` (the 60 s timer did not fire, so the app was not really awake), or
///   when a run ended unannounced in an awake state (a crash or jetsam, with unknown timing).
/// - Drain figures use only intervals that are unplugged at both ends, with known levels, and with no
///   level rise (a rise means it charged in between).
struct PowerLogSummary: Equatable, Sendable {
    static let defaultMaxAwakeInterval: TimeInterval = 600

    struct Totals: Equatable, Sendable {
        var seconds = 0.0
        var cpuSeconds = 0.0
        /// The part of `seconds` usable for drain, and the battery percentage points lost in it.
        var drainSeconds = 0.0
        var drainPercent = 0.0
    }

    /// A drain rate, shown only with at least `minimumSeconds` of qualifying time and at least
    /// `minimumPercent` points of drop; otherwise there is not enough data.
    struct Drain: Equatable, Sendable {
        static let minimumSeconds: TimeInterval = 3_600
        static let minimumPercent: Double = 3

        var seconds = 0.0
        var percent = 0.0

        var isConfident: Bool {
            seconds >= Self.minimumSeconds - 1e-9 && percent >= Self.minimumPercent - 1e-9
        }

        /// Percent per hour, nil when not confident.
        var percentPerHour: Double? { isConfident ? percent / (seconds / 3_600) : nil }
    }

    var sampleCount = 0
    /// Earliest to latest wall time of the samples.
    var span: DateInterval?
    /// Process runs seen.
    var runs = 0
    /// Awake time per host state. `idle` here is the app in front with no session.
    var states: [PowerHostState: Totals] = [:]
    /// Time suspended or not running; its drain is the baseline.
    var inactive = Totals()
    /// The background microphone with no dictation: what an always-open session costs.
    var micOpenBackground = Drain()
    var unknownSeconds = 0.0
    /// Time excluded from drain because the battery was not unplugged (or charged in between).
    var pluggedInSeconds = 0.0
    var transcriptions = 0

    var baseline: Drain { Drain(seconds: inactive.drainSeconds, percent: inactive.drainPercent) }

    /// "Always-open microphone ≈ (micOpen rate − baseline rate) × 24" in percent per day; nil until both
    /// rates are confident.
    var alwaysOpenPercentPerDay: Double? {
        guard let open = micOpenBackground.percentPerHour, let base = baseline.percentPerHour else { return nil }
        return (open - base) * 24
    }

    var cpuSecondsPerTranscription: Double? {
        guard transcriptions > 0 else { return nil }
        return (states[.transcribing]?.cpuSeconds ?? 0) / Double(transcriptions)
    }

    init() {}

    init(samples: [PowerSample], maxAwakeInterval: TimeInterval = defaultMaxAwakeInterval) {
        sampleCount = samples.count
        guard let first = samples.first else { return }
        let walls = samples.map(\.wallTime)
        span = DateInterval(start: walls.min() ?? first.wallTime, end: walls.max() ?? first.wallTime)
        runs = 1
        if first.hostState == .transcribing { transcriptions = 1 }
        for (a, b) in zip(samples, samples.dropFirst()) {
            let newRun = Self.startsNewRun(from: a, to: b)
            if newRun { runs += 1 }
            if b.hostState == .transcribing, newRun || a.hostState != .transcribing { transcriptions += 1 }

            let duration = newRun ? b.wallTime.timeIntervalSince(a.wallTime) : b.uptime - a.uptime
            guard duration > 0 else { continue }
            if a.trigger == .terminate || (a.appState == .background && a.hostState == .idle) {
                inactive.seconds += duration
                if let drop = qualifyingDrop(from: a, to: b, duration: duration) {
                    inactive.drainSeconds += duration
                    inactive.drainPercent += drop
                }
                continue
            }
            if newRun || duration > maxAwakeInterval {
                unknownSeconds += duration
                continue
            }
            var totals = states[a.hostState] ?? Totals()
            totals.seconds += duration
            totals.cpuSeconds += max(0, b.cpuSeconds - a.cpuSeconds)
            if let drop = qualifyingDrop(from: a, to: b, duration: duration) {
                totals.drainSeconds += duration
                totals.drainPercent += drop
                if a.hostState == .micOpen, a.appState == .background {
                    micOpenBackground.seconds += duration
                    micOpenBackground.percent += drop
                }
            }
            states[a.hostState] = totals
        }
    }

    // MARK: Private

    /// Cumulative CPU time may differ by the rounding of the two written columns.
    private static let cpuTolerance = 0.002

    private static func startsNewRun(from a: PowerSample, to b: PowerSample) -> Bool {
        b.trigger == .launch || b.uptime < a.uptime || b.cpuSeconds < a.cpuSeconds - cpuTolerance
    }

    /// The interval's drop in percentage points if it qualifies for drain figures. Time excluded for
    /// charging is added to `pluggedInSeconds`.
    private mutating func qualifyingDrop(from a: PowerSample, to b: PowerSample, duration: TimeInterval) -> Double? {
        guard a.batteryLevel >= 0, b.batteryLevel >= 0 else { return nil }
        guard a.batteryState == .unplugged, b.batteryState == .unplugged, b.batteryLevel <= a.batteryLevel + 1e-9 else {
            pluggedInSeconds += duration
            return nil
        }
        return (a.batteryLevel - b.batteryLevel) * 100
    }
}
