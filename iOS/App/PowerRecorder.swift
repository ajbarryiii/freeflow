#if LOCALFLOW_POWER_LOG
import Darwin
import Foundation
import UIKit

/// Test builds only (`make POWER_LOG=1`; ARCHITECTURE.md, "Power log"). Records content-free power
/// proxies to `Application Support/PowerLog` in the app's own container, never the App Group.
///
/// It samples on every host-state and app-state transition, on battery, thermal and Low Power Mode
/// notifications, at launch and termination, and from a 60 s timer. It never keeps the process awake:
/// the timer is an ordinary run-loop timer that stops while iOS suspends the app, and no background task
/// or audio is used on its behalf. Samples are buffered and written at most every 5 minutes, and at
/// every background transition or termination.
@MainActor
final class PowerRecorder {
    static let shared = PowerRecorder()

    static let periodicInterval: TimeInterval = 60
    static let writeInterval: TimeInterval = 300
    /// Bounds memory if writes keep failing (a full disk): the oldest buffered rows are dropped.
    static let maxPendingSamples = 2_000

    static let directoryName = "PowerLog"
    static let fileName = "power-log.csv"
    static let rotatedFileName = "power-log.1.csv"

    /// What Diagnostics shows: the summary of everything logged, including rows not yet written.
    struct Status: Sendable {
        var summary: PowerLogSummary
        var bytesOnDisk: Int
        var fileCount: Int
    }

    private let directory: URL?
    private let files: PowerLogFiles?
    private let build: String
    private let device: String
    private var pending: [PowerSample] = []
    private var lastWriteUptime: TimeInterval = 0
    private var hostState = PowerHostState.idle
    private var computeUnits: @MainActor () -> ComputePolicy.Units? = { nil }
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isStarted = false

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        files = directory.map {
            PowerLogFiles(directory: $0, fileName: Self.fileName, rotatedFileName: Self.rotatedFileName)
        }
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        device = Self.hardwareModel()
    }

    /// Call once at launch, before the host's run recovery publishes its first status.
    func start(computeUnits: @escaping @MainActor () -> ComputePolicy.Units?) {
        guard !isStarted else { return }
        isStarted = true
        self.computeUnits = computeUnits
        lastWriteUptime = Self.uptime()
        UIDevice.current.isBatteryMonitoringEnabled = true
        observeNotifications()
        let timer = Timer(timeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.record(.periodic) }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        record(.launch)
    }

    /// The host's passive observer hook (`HostSessionCore.onPublish`): samples when the derived state
    /// changes. It reads the status only and never acts on the host.
    func hostStatusPublished(_ status: HostStatus) {
        let state = PowerHostState(status: status)
        guard state != hostState else { return }
        hostState = state
        if isStarted { record(.state) }
    }

    /// Writes buffered rows now (the user is exporting) and returns the files, oldest first.
    func filesForExport() -> [URL] {
        write(at: Self.uptime())
        return files?.existingFiles ?? []
    }

    func clear() {
        pending.removeAll()
        try? files?.clear()
        lastWriteUptime = Self.uptime()
    }

    /// Reads and summarizes the log off the main thread.
    func status() async -> Status {
        let buffered = pending
        guard let directory else {
            return Status(summary: PowerLogSummary(samples: buffered), bytesOnDisk: 0, fileCount: 0)
        }
        let fileName = Self.fileName, rotatedFileName = Self.rotatedFileName
        return await Task.detached(priority: .utility) {
            let files = PowerLogFiles(directory: directory, fileName: fileName, rotatedFileName: rotatedFileName)
            return Status(summary: PowerLogSummary(samples: files.readSamples() + buffered),
                          bytesOnDisk: files.totalBytes, fileCount: files.existingFiles.count)
        }.value
    }

    // MARK: Private

    private func record(_ trigger: PowerTrigger) {
        let now = Self.uptime()
        pending.append(sample(trigger, uptime: now))
        if pending.count > Self.maxPendingSamples { pending.removeFirst(pending.count - Self.maxPendingSamples) }
        if trigger == .background || trigger == .terminate {
            write(at: now)
        } else if now - lastWriteUptime >= Self.writeInterval {
            lastWriteUptime = now
            // Never inside the host's publish call (a `.state` sample): the file work runs on the next turn.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.write(at: Self.uptime()) }
            }
        }
    }

    /// A failed write keeps the rows for the next attempt.
    private func write(at now: TimeInterval) {
        lastWriteUptime = now
        guard let files, !pending.isEmpty else { return }
        do {
            try files.append(pending)
            pending.removeAll()
        } catch {}
    }

    private func sample(_ trigger: PowerTrigger, uptime: TimeInterval) -> PowerSample {
        let device = UIDevice.current
        let appState: PowerAppState
        switch trigger {
        case .foreground: appState = .foreground   // willEnterForeground still reports `.background`
        case .background: appState = .background
        default: appState = UIApplication.shared.applicationState == .background ? .background : .foreground
        }
        let batteryState: PowerBatteryState
        switch device.batteryState {
        case .unplugged: batteryState = .unplugged
        case .charging: batteryState = .charging
        case .full: batteryState = .full
        case .unknown: batteryState = .unknown
        @unknown default: batteryState = .unknown
        }
        let thermalState: PowerThermalState
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = .nominal
        case .fair: thermalState = .fair
        case .serious: thermalState = .serious
        case .critical: thermalState = .critical
        @unknown default: thermalState = .critical
        }
        var usage = rusage()
        let cpu = getrusage(RUSAGE_SELF, &usage) == 0
            ? (user: Self.seconds(usage.ru_utime), system: Self.seconds(usage.ru_stime)) : (user: 0, system: 0)
        let footprint = ProcessMemory.footprint()
        return PowerSample(
            wallTime: Date(), uptime: uptime, trigger: trigger, hostState: hostState, appState: appState,
            batteryLevel: Double(device.batteryLevel), batteryState: batteryState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: thermalState,
            cpuUserSeconds: cpu.user, cpuSystemSeconds: cpu.system, memoryMB: footprint?.currentMB,
            memoryPeakMB: footprint?.peakMB, computeUnits: computeUnits(), build: build, device: self.device)
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ trigger: PowerTrigger) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record(trigger) }
            })
        }
        on(UIApplication.willEnterForegroundNotification, .foreground)
        on(UIApplication.didEnterBackgroundNotification, .background)
        on(UIApplication.willTerminateNotification, .terminate)
        on(UIDevice.batteryLevelDidChangeNotification, .battery)
        on(UIDevice.batteryStateDidChangeNotification, .battery)
        on(ProcessInfo.thermalStateDidChangeNotification, .thermal)
        on(Notification.Name.NSProcessInfoPowerStateDidChange, .powerMode)
    }

    /// Continues while the device sleeps (unlike `systemUptime`), so suspended intervals within one run
    /// keep their real length.
    private static func uptime() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    /// The hardware model identifier, such as `iPhone16,1`; the simulated model on the simulator.
    private static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        guard uname(&info) == 0 else { return "?" }
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
#endif
