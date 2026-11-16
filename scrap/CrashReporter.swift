import AppKit
import Darwin

nonisolated enum CrashReporter {
    static let keptReports = 10
    static let issuesURL = "https://github.com/swagdotsh/scrap/issues/new"
    private static let handledSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
    private static let maxFrames: Int32 = 128

    nonisolated(unsafe) private static var pendingPath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var header: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var headerLength = 0
    nonisolated(unsafe) private static var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    nonisolated(unsafe) private static var exceptionWritten = false
    nonisolated(unsafe) private(set) static var previousReport: CrashReport?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crashes", isDirectory: true)
    }

    private static var pendingURL: URL { directory.appendingPathComponent("pending.crash") }

    static func start() {
        previousReport = takePendingReport()
        install()
    }

    // MARK: - Recording

    private static func install() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pendingPath = strdup(pendingURL.path)
        header = strdup(headerText())
        headerLength = header.map { strlen($0) } ?? 0
        frames = .allocate(capacity: Int(maxFrames))

        let stackSize = 128 * 1024
        var stack = stack_t(ss_sp: malloc(stackSize), ss_size: stackSize, ss_flags: 0)
        sigaltstack(&stack, nil)

        for signalNumber in handledSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signalNumber in CrashReporter.handleSignal(signalNumber) }
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signalNumber, &action, nil)
        }

        NSSetUncaughtExceptionHandler { exception in CrashReporter.record(exception) }
    }

    static func headerText(info: [String: Any]? = Bundle.main.infoDictionary,
                           os: String = ProcessInfo.processInfo.operatingSystemVersionString) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let chip = "Apple silicon (arm64)"
        #else
        let chip = "Intel (x86_64)"
        #endif
        return "scrap \(version) (\(build))\nmacOS \(os)\n\(chip)\n\n"
    }

    private static func record(_ exception: NSException) {
        var text = headerText()
        text += "Exception: \(exception.name.rawValue)\n"
        if let reason = exception.reason { text += "Reason: \(reason)\n" }
        text += "\nBacktrace:\n" + exception.callStackSymbols.joined(separator: "\n") + "\n\n"
        if (try? text.write(to: pendingURL, atomically: false, encoding: .utf8)) != nil { exceptionWritten = true }
    }

    private static func handleSignal(_ signalNumber: Int32) {
        if let pendingPath {
            let flags = exceptionWritten ? (O_WRONLY | O_APPEND) : (O_WRONLY | O_CREAT | O_TRUNC)
            let fd = open(pendingPath, flags, 0o644)
            if fd >= 0 {
                if !exceptionWritten, let header { _ = write(fd, header, headerLength) }
                writeStatic(fd, "Signal: ")
                writeStatic(fd, signalName(signalNumber))
                writeStatic(fd, "\n\nBacktrace:\n")
                if let frames {
                    let count = backtrace(frames, maxFrames)
                    backtrace_symbols_fd(frames, count, fd)
                }
                close(fd)
            }
        }
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
    }

    private static func writeStatic(_ fd: Int32, _ text: StaticString) {
        text.withUTF8Buffer { buffer in _ = write(fd, buffer.baseAddress, buffer.count) }
    }

    private static func signalName(_ signalNumber: Int32) -> StaticString {
        switch signalNumber {
        case SIGABRT: "SIGABRT (abort)"
        case SIGBUS: "SIGBUS (bus error)"
        case SIGFPE: "SIGFPE (arithmetic error)"
        case SIGILL: "SIGILL (illegal instruction)"
        case SIGSEGV: "SIGSEGV (bad memory access)"
        case SIGTRAP: "SIGTRAP (Swift runtime error)"
        default: "unknown signal"
        }
    }

    // MARK: - Reports

    private static func takePendingReport() -> CrashReport? {
        let fileManager = FileManager.default
        guard let data = try? Data(contentsOf: pendingURL), !data.isEmpty else { return nil }
        let crashedAt = (try? fileManager.attributesOfItem(atPath: pendingURL.path))?[.modificationDate] as? Date ?? Date()
        let report = CrashReport(text: demangled(String(decoding: data, as: UTF8.self)), date: crashedAt)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let saved = directory.appendingPathComponent("scrap-crash-\(formatter.string(from: crashedAt)).txt")
        try? report.text.write(to: saved, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: pendingURL)
        prune()
        return report
    }

    private static func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let reports = files.filter { $0.hasPrefix("scrap-crash-") && $0.hasSuffix(".txt") }.sorted()
        for name in reports.dropLast(keptReports) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func demangled(_ text: String) -> String {
        typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return text }
        let demangle = unsafeBitCast(symbol, to: Demangle.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
                let token = String(word)
                guard token.hasPrefix("$s") || token.hasPrefix("_$s") else { return token }
                let mangled = token.hasPrefix("_") ? String(token.dropFirst()) : token
                guard let result = mangled.withCString({ demangle($0, strlen($0), nil, nil, 0) }) else { return token }
                defer { free(result) }
                return String(cString: result)
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func revealReports() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

nonisolated struct CrashReport: Equatable {
    let text: String
    let date: Date

    var summary: String {
        text.split(separator: "\n").first { $0.hasPrefix("Signal: ") || $0.hasPrefix("Exception: ") }.map(String.init) ?? "Crash"
    }

    func issueURL(maxBodyLength: Int = 6000) -> URL {
        var details = text
        if details.count > maxBodyLength {
            details = String(details.prefix(maxBodyLength)) + "\n… (report shortened)"
        }
        let body = """
        **What were you doing when scrap quit?**


        **Crash report**
        ```
        \(details)
        ```
        """
        var components = URLComponents(string: CrashReporter.issuesURL)!
        components.queryItems = [URLQueryItem(name: "title", value: "Crash: \(summary)"),
                                 URLQueryItem(name: "body", value: body)]
        return components.url!
    }
}
