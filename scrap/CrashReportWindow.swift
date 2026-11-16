import AppKit
import SwiftUI

@MainActor
final class CrashReportWindow {
    static let shared = CrashReportWindow()
    private var window: NSWindow?

    func show(_ report: CrashReport) {
        let view = CrashReportView(report: report) { [weak self] in self?.close() }
        let window = window ?? NSWindow(contentViewController: NSHostingController(rootView: view))
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "scrap quit unexpectedly"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
    }
}

private struct CrashReportView: View {
    let report: CrashReport
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28)).foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("scrap quit unexpectedly").font(.title3.bold())
                    Text("\(report.date.formatted(date: .abbreviated, time: .shortened)) · \(report.summary)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Reporting it helps fix it. The report below has scrap's version, your macOS version, your Mac's chip and where in scrap's code it crashed. It doesn't include your last.fm account or what you were listening to. Nothing is sent until you submit the issue on GitHub, and you can edit it first.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(report.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .accessibilityLabel("Crash report")
            HStack {
                Button("Show in Finder") { CrashReporter.revealReports() }
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                    copied = true
                }
                Button("Report on GitHub…") {
                    NSWorkspace.shared.open(report.issueURL())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
    }
}
