import Foundation

/// Where the trackpad reads the field and moves the caret: the text proxy, or a fake in tests.
protocol TrackpadHost: AnyObject {
    /// The field's identity (`documentIdentifier`); nil while a field connects or goes away.
    var documentID: UUID? { get }
    var contextBefore: String? { get }
    var contextAfter: String? { get }
    /// `adjustTextPosition(byCharacterOffset:)`.
    func adjust(by offset: Int)
}

/// Runs a `TrackpadSession` against the host: touch samples in, at most one adjustment per display
/// frame out (`tick`). Before every adjustment it re-validates that the field (a non-nil identity) and
/// the edit generation are the ones the gesture started on; anything else ends the session without
/// another adjustment. The keyboard's `TrackpadDriver` supplies the display link and the TextKit
/// layout; everything else is here, so it is tested.
///
/// A session ends one of two ways: completed (it settled after the lift, timed out settling, or a key
/// ended it) or aborted (a stale field or generation, an outside change, an ambiguous report, a system
/// cancellation, hiding). `onFinished` says which. Typing never waits on a session (ARCHITECTURE.md,
/// "Typing model v2"): a key ends it on the spot (`interrupt`).
///
/// The context snapshot lives only in the session and is dropped when it ends; on cancelling or hiding,
/// at once. The learned offset unit, and whether the field reports each adjustment twice, are kept for
/// the current field only, and forgotten on hiding.
final class TrackpadController: AdjustmentOwner {
    private weak var host: TrackpadHost?
    private(set) var session: TrackpadSession?
    private var documentID: UUID?
    private var generation = 0
    private var unitCache: (documentID: UUID, unit: CursorOffsetUnit)?
    private var reportsCache: (documentID: UUID, reportsTwice: Bool)?
    private var touchRate = TouchRateEstimator()
    /// The keyboard hid while a cancelled session still watches a jump; see `hide`.
    private var isHiding = false
    /// Reports the last session in this field was still owed when it ended (a key ended it at once), by
    /// issue time: the next session expects them first.
    private var owedReports: (documentID: UUID, times: [TimeInterval])?
    /// Every report the last session in this field may still send (`TrackpadSession.lateReports`), by
    /// issue time, for at most `lateReportLifetime`: none is ever the echo of a later edit.
    private var lateReports: (documentID: UUID, times: [TimeInterval])?
    /// How long after it was issued a finished session's adjustment may still be reported.
    static let lateReportLifetime: TimeInterval = 1
    var parameters = TrackpadParameters.standard
    /// The current edit generation, owned by `EditingCore`.
    var currentGeneration: () -> Int = { 0 }
    /// Called once the session is gone: `true` when it completed, `false` when it was aborted.
    var onFinished: ((Bool) -> Void)?
    /// The latest time a frame, a key or a cancellation was seen at.
    private(set) var lastTimestamp: TimeInterval = 0
    /// During `onFinished` of a session a key ended (`interrupt`) only: the text before the caret where
    /// its last move lands (`TrackpadSession.landingBefore`), which the proxy may not show yet.
    private(set) var finishedLanding: String?
    /// During `onFinished` only: a key ended the session (`interrupt`).
    private(set) var finishedByKey = false

    init(host: TrackpadHost) {
        self.host = host
    }

    /// A gesture is running or settling.
    var isActive: Bool { session != nil }

    /// The touch delivery rate measured so far and the step scale it gives, for Diagnostics.
    var measuredTouchRate: (rate: Double, scale: Double)? {
        touchRate.touchRate.map { ($0, touchRate.eventStepScale) }
    }

    /// The offset unit learned in this field, if any; part of the field's fingerprint.
    func learnedUnit(for documentID: UUID?) -> CursorOffsetUnit? {
        guard let documentID, let unitCache, unitCache.documentID == documentID else { return nil }
        return unitCache.unit
    }

    /// Starts a gesture in the field the host serves now, laid out by `layout`. A session still running
    /// (a watch since hiding, or a guard after an outside change) ends first. False without a field
    /// identity.
    @discardableResult
    func begin(layout: any LineLayout, linePitch: Double, layoutWidth: Double) -> Bool {
        if session != nil { finish(completed: false) }
        guard let host, let documentID = host.documentID else { return false }
        self.documentID = documentID
        generation = currentGeneration()
        let unit = unitCache.flatMap { $0.documentID == documentID ? $0.unit : nil }
        if unit == nil { unitCache = nil }
        let reportsTwice = reportsCache.flatMap { $0.documentID == documentID ? $0.reportsTwice : nil }
        if reportsTwice == nil { reportsCache = nil }
        let owed = owedReports.flatMap { $0.documentID == documentID ? $0.times : nil } ?? []
        owedReports = nil
        touchRate.beginGesture()
        var parameters = self.parameters
        parameters.eventStepScale = touchRate.eventStepScale
        session = TrackpadSession(before: host.contextBefore, after: host.contextAfter, unit: unit,
                                  reportsTwice: reportsTwice,
                                  owedReports: owed.filter { lastTimestamp - $0 <= parameters.syncTimeout },
                                  parameters: parameters, layout: layout, linePitch: linePitch, layoutWidth: layoutWidth)
        return true
    }

    /// One delivered touch event's finger movement, at its touch timestamp.
    func move(dx: Double, dy: Double, timestamp: TimeInterval) {
        guard session != nil else { return }
        touchRate.record(timestamp)
        session?.setEventStepScale(touchRate.eventStepScale)
        session?.drag(dx: dx, dy: dy)
    }

    /// The finger lifted: the target stays, and settling continues toward it.
    func end(at timestamp: TimeInterval) {
        session?.end(at: timestamp)
    }

    /// A key was typed, or dictated text inserted (ARCHITECTURE.md, "Typing model v2"): the session ends
    /// on the spot. Nothing more is issued; an outstanding probe's outcome is abandoned, and the caret is
    /// wherever the host has it once what was already issued lands (the proxy applies adjustments and
    /// edits in order).
    func interrupt(at timestamp: TimeInterval) {
        lastTimestamp = max(lastTimestamp, timestamp)
        guard let session else { return }
        let completed = isValid && !session.isCancelled
        finishedByKey = true
        defer { finishedByKey = false }
        finish(completed: completed, landing: completed ? session.landingBefore : nil)
    }

    /// The system cancelled the gesture: an outstanding probe is rolled back at once, here, so nothing
    /// is left to a later frame; then the session only waits to hear from its last adjustment.
    func cancel(at timestamp: TimeInterval) {
        lastTimestamp = max(lastTimestamp, timestamp)
        guard var session else { return }
        guard isValid else { return finish(completed: false) }
        let rollback = session.cancel(at: timestamp)
        self.session = session
        if let rollback, rollback != 0 { host?.adjust(by: rollback) }
    }

    /// The keyboard is hiding: roll back an outstanding probe now and drop the snapshot (and its
    /// laid-out copy), every expected context and the learned unit at once. Only a jump past the edge
    /// still out keeps the text-free session (and the field's identity) until its time limit, at most
    /// `syncTimeout`.
    func hide(at timestamp: TimeInterval) {
        cancel(at: timestamp)
        unitCache = nil
        reportsCache = nil
        owedReports = nil
        lateReports = nil
        if let session, !session.isSettled {
            isHiding = true
            return
        }
        finish(completed: false)
    }

    /// The document changed under the gesture (an outside change), or a report could not be attributed:
    /// the gesture ends without another step toward the target. If the caret may be inside a cluster
    /// (something out may leave it there, or the field shows it there), the session first watches the
    /// field until the caret is on a whole-cluster boundary (`TrackpadSession.abortGuarding`); a key
    /// ends that at once, like any session.
    func abort() {
        // Already watching the boundary after an outside change: another one changes nothing.
        guard session?.guardsBoundary != true else { return }
        guard var session, !session.isCancelled, let host, let documentID, host.documentID == documentID,
              session.mayLeaveCaretInsideCluster
                || TrackpadSession.repairOffset(before: host.contextBefore, after: host.contextAfter,
                                                direction: session.repairDirection) != nil else {
            return finish(completed: false)
        }
        session.abortGuarding(at: lastTimestamp)
        self.session = session
    }

    /// Whatever is left ends at once, a watch since hiding included.
    func stop() {
        finish(completed: false)
    }

    /// The keyboard appeared anew. A watch kept since hiding goes on in the same field (it holds no text and
    /// has its own limit; the jump it watches may only now show where it stopped); anything else ends.
    func appeared() {
        if isHiding, let session, session.isCancelled, let host, let documentID, host.documentID == documentID { return }
        finish(completed: false)
    }

    /// The editing side saw another field, or none (as it does for every callback once hidden): end the
    /// gesture at once, unless a hidden keyboard is still watching a cancelled jump, which checks the
    /// field on every frame itself.
    func fieldChanged() {
        guard !isHiding else { return }
        finish(completed: false)
    }

    /// One display frame.
    func tick(at timestamp: TimeInterval) {
        lastTimestamp = max(lastTimestamp, timestamp)
        guard var session else { return }
        guard isValid, let host else { return finish(completed: false) }
        let offset = session.frame(before: host.contextBefore, after: host.contextAfter, timestamp: timestamp)
        self.session = session
        if let offset, offset != 0 { host.adjust(by: offset) }
        if !isHiding, let documentID {
            if let unit = session.unit { unitCache = (documentID, unit) }
            if let reportsTwice = session.reportsTwice { reportsCache = (documentID, reportsTwice) }
        }
        if session.isAmbiguous, !session.isCancelled { return abort() }
        if session.isFinished(at: timestamp) { finish(completed: !session.isCancelled) }
    }

    func acknowledge(before: String?, after: String?) -> Bool {
        session?.acknowledge(before: before, after: after) ?? false
    }

    func acknowledgeAsIssued(before: String?, after: String?) -> Bool {
        session?.acknowledgeAsIssued(before: before, after: after) ?? false
    }

    func fits(before: String?, after: String?) -> Bool {
        session?.fits(before: before, after: after) ?? false
    }

    /// When the oldest report a gesture may still send was issued: the running session's, or the last
    /// finished one's in this field (within `lateReportLifetime`). Reports arrive in order, so an edit
    /// made after it cannot be echoed before that report has arrived.
    func oldestOwedReport(now: TimeInterval) -> TimeInterval? {
        if let session { return session.lateReports.first }
        guard var late = lateReports, let host, host.documentID == late.documentID else { return nil }
        late.times.removeAll { now - $0 > Self.lateReportLifetime }
        lateReports = late.times.isEmpty ? nil : late
        return late.times.first
    }

    /// No gesture runs, and the last one in this field may still send a report: a callback nothing
    /// else explains is the oldest of them (ARCHITECTURE.md, "Typing model v2": never an echo). It
    /// confirms nothing and still counts as an outside change; the next gesture no longer waits for it.
    func consumeLateReport(now: TimeInterval) -> Bool {
        guard session == nil, oldestOwedReport(now: now) != nil, var late = lateReports else { return false }
        late.times.removeFirst()
        lateReports = late.times.isEmpty ? nil : late
        if var owed = owedReports, !owed.times.isEmpty {
            owed.times.removeFirst()
            owedReports = owed.times.isEmpty ? nil : owed
        }
        return true
    }

    /// The field and the generation are still the ones the gesture started on. While a hidden keyboard
    /// finishes watching a cancelled jump, or a session guards the boundary after an outside change,
    /// only the field counts: hiding and the outside change advanced the generation.
    private var isValid: Bool {
        guard let host, let documentID, host.documentID == documentID else { return false }
        return isHiding || session?.guardsBoundary == true || currentGeneration() == generation
    }

    private func finish(completed: Bool, landing: String? = nil) {
        guard let session else {
            if isHiding { isHiding = false; documentID = nil }
            return
        }
        if isHiding {
            isHiding = false
            documentID = nil
        }
        if let documentID, !session.owedReports.isEmpty {
            owedReports = (documentID, session.owedReports)
        }
        if let documentID {
            let late = session.lateReports
            lateReports = late.isEmpty ? nil : (documentID, late)
        }
        finishedLanding = landing
        self.session = nil
        onFinished?(completed)
        finishedLanding = nil
    }
}
