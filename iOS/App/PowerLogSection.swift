#if LOCALFLOW_POWER_LOG
import SwiftUI
import UIKit

/// Diagnostics → Power, in test builds only (ARCHITECTURE.md, "Power log"): the summary and the
/// always-open projection, the log's size and span, Export and Clear.
struct PowerLogSection: View {
    @State private var status: PowerRecorder.Status?
    @State private var export: PowerLogExport?
    @State private var confirmingClear = false

    var body: some View {
        Section {
            if let status {
                let summary = status.summary
                LabeledContent("Logged", value: "\(spanText(summary.span)) · \(sizeText(status.bytesOnDisk))")
                    .accessibilityIdentifier("diagnostics.power.logged")
                LabeledContent("Mic open, background", value: drainText(summary.micOpenBackground))
                    .accessibilityIdentifier("diagnostics.power.micOpen")
                LabeledContent("LocalFlow inactive", value: drainText(summary.baseline))
                    .accessibilityIdentifier("diagnostics.power.baseline")
                LabeledContent("Always-open mic", value: projectionText(summary.alwaysOpenPercentPerDay))
                    .accessibilityIdentifier("diagnostics.power.projection")
                LabeledContent("CPU per transcription", value: transcriptionText(summary))
                ForEach(PowerHostState.allCases, id: \.self) { state in
                    if let totals = summary.states[state] {
                        LabeledContent(stateLabel(state), value: totalsText(totals))
                            .font(.subheadline)
                    }
                }
                LabeledContent("Suspended or closed", value: hoursText(summary.inactive.seconds)).font(.subheadline)
                if summary.pluggedInSeconds > 0 {
                    LabeledContent("Charging (not in drain)", value: hoursText(summary.pluggedInSeconds)).font(.subheadline)
                }
                if summary.unknownSeconds > 0 {
                    LabeledContent("Unaccounted", value: hoursText(summary.unknownSeconds)).font(.subheadline)
                }
            } else {
                ProgressView()
            }
            Button("Export log") {
                let urls = PowerRecorder.shared.filesForExport()
                if !urls.isEmpty { export = PowerLogExport(urls: urls) }
                Task { await reload() }
            }
            .accessibilityIdentifier("diagnostics.power.export")
            Button("Clear log", role: .destructive) { confirmingClear = true }
                .accessibilityIdentifier("diagnostics.power.clear")
        } header: {
            Text("Power (test build)")
        } footer: {
            Text("Battery level, charging, thermal state, Low Power Mode, CPU time and memory, sampled each minute and at every change while LocalFlow runs; never audio or text. Stored on this iPhone only. Figures need at least 1 h and 3 % of drop, unplugged. LocalFlow's true share of total battery use is in Settings → Battery, which apps cannot read.")
        }
        .task { await reload() }
        .sheet(item: $export) { ActivityView(items: $0.urls) }
        .confirmationDialog("Delete the power log?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                PowerRecorder.shared.clear()
                Task { await reload() }
            }
        }
    }

    private func reload() async {
        status = await PowerRecorder.shared.status()
    }

    private func stateLabel(_ state: PowerHostState) -> String {
        switch state {
        case .idle: return "Open, no session"
        case .micOpen: return "Mic open"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .preparing: return "Preparing model"
        }
    }

    private func drainText(_ drain: PowerLogSummary.Drain) -> String {
        let basis = String(format: "%.1f h, %.0f %%", drain.seconds / 3_600, drain.percent)
        guard let rate = drain.percentPerHour else { return "Not enough data (\(basis))" }
        return String(format: "%.2f %%/h", rate) + " (\(basis))"
    }

    private func projectionText(_ percentPerDay: Double?) -> String {
        percentPerDay.map { String(format: "≈ %.0f %% per day", $0) } ?? "Not enough data"
    }

    private func transcriptionText(_ summary: PowerLogSummary) -> String {
        guard let seconds = summary.cpuSecondsPerTranscription else { return "No transcriptions yet" }
        return String(format: "%.2f s · %d", seconds, summary.transcriptions)
    }

    private func totalsText(_ totals: PowerLogSummary.Totals) -> String {
        "\(hoursText(totals.seconds)) · CPU " + String(format: "%.0f s · %.0f %%", totals.cpuSeconds, totals.drainPercent)
    }

    private func hoursText(_ seconds: Double) -> String {
        seconds < 3_600 ? String(format: "%.0f min", seconds / 60) : String(format: "%.1f h", seconds / 3_600)
    }

    private func spanText(_ span: DateInterval?) -> String {
        guard let span else { return "Nothing yet" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: span.duration) ?? "—"
    }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct PowerLogExport: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// The system share sheet for the log files (AirDrop, Files, Mail…). Nothing is sent unless the user
/// picks a destination.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
