import Foundation

/// Runs `claude -p` (Claude Code, with the user's own account): the
/// instructions as the prompt, the input on stdin. The text of a meeting
/// leaves the Mac only here.
public enum ClaudeCLI {
    /// A long meeting takes a minute or two.
    public static let defaultTimeout: TimeInterval = 300

    public static func run(prompt: String, input: String, timeout: TimeInterval = defaultTimeout) throws -> String {
        let (executable, environment) = try locate()
        return try run(executable: executable, environment: environment, prompt: prompt, input: input, timeout: timeout)
    }

    static func run(executable: URL, environment: [String: String], prompt: String, input: String, timeout: TimeInterval) throws -> String {
        let result: Execution
        do {
            result = try execute(executable, arguments: ["-p", prompt], environment: environment, input: Data(input.utf8), timeout: timeout)
        } catch {
            throw ClaudeError.couldNotRun(error.localizedDescription)
        }
        if result.timedOut { throw ClaudeError.timedOut(Int(timeout)) }
        guard result.status == 0 else {
            let detail = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeError.failed(status: result.status, detail: detail)
        }
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeError.emptyOutput }
        return text
    }

    // MARK: - Finding claude

    /// Where claude usually lands when the shell can't tell.
    static let knownDirectories = ["~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]

    /// `KURONEKO_CLAUDE` when set; else `claude` in the PATH, which for the
    /// app opened from Finder is only /usr/bin:/bin:… — so the PATH of the
    /// user's login shell is asked for. claude runs with that PATH, since an
    /// npm install needs `node` from it.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        knownDirectories: [String] = knownDirectories,
        shellPath: (_ interactive: Bool) -> String? = { loginShellPath(interactive: $0) }
    ) throws -> (URL, [String: String]) {
        if let path = environment["KURONEKO_CLAUDE"], !path.isEmpty {
            return (URL(fileURLWithPath: path), environment)
        }
        let current = environment["PATH"] ?? ""
        if let found = find("claude", in: current) {
            return (found, environment)
        }
        let known = knownDirectories.map { $0.replacingOccurrences(of: "~", with: home) }.joined(separator: ":")
        // A non-interactive shell skips .zshrc, where PATH is often set; an
        // interactive one is only started when nothing else found claude.
        for interactive in [false, true] {
            let path = [shellPath(interactive) ?? "", known, current].filter { !$0.isEmpty }.joined(separator: ":")
            if let found = find("claude", in: path) {
                var environment = environment
                environment["PATH"] = path
                return (found, environment)
            }
        }
        throw ClaudeError.notFound
    }

    static func find(_ name: String, in path: String) -> URL? {
        path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func loginShellPath(interactive: Bool) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"]
            ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }
            ?? "/bin/zsh"
        // Markers, because an interactive shell may print a greeting.
        let marker = "__KURONEKO_PATH__"
        let arguments = (interactive ? ["-l", "-i"] : ["-l"]) + ["-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        guard let result = try? execute(URL(fileURLWithPath: shell), arguments: arguments, environment: nil, input: Data(), timeout: 10),
              !result.timedOut else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
        guard let start = text.range(of: marker), let end = text.range(of: marker, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    // MARK: - Processes

    struct Execution {
        var status: Int32
        var output: Data
        var errors: Data
        var timedOut: Bool
    }

    /// Input and output go through files instead of pipes: nothing blocks on
    /// a full pipe, and a helper left behind by a killed process can't hold
    /// the output open.
    static func execute(_ executable: URL, arguments: [String], environment: [String: String]?, input: Data, timeout: TimeInterval) throws -> Execution {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inputURL = folder.appendingPathComponent("input")
        let outputURL = folder.appendingPathComponent("output")
        let errorsURL = folder.appendingPathComponent("errors")
        try input.write(to: inputURL)
        try Data().write(to: outputURL)
        try Data().write(to: errorsURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = try FileHandle(forReadingFrom: inputURL)
        process.standardOutput = try FileHandle(forWritingTo: outputURL)
        process.standardError = try FileHandle(forWritingTo: errorsURL)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 3)
            }
        }
        return Execution(
            status: process.isRunning ? -1 : process.terminationStatus,
            output: (try? Data(contentsOf: outputURL)) ?? Data(),
            errors: (try? Data(contentsOf: errorsURL)) ?? Data(),
            timedOut: timedOut
        )
    }
}

public enum ClaudeError: Error, Equatable, CustomStringConvertible {
    case notFound
    case couldNotRun(String)
    case failed(status: Int32, detail: String)
    case timedOut(Int)
    case emptyOutput

    public var description: String {
        switch self {
        case .notFound:
            "claude não encontrado — instale o Claude Code ou aponte KURONEKO_CLAUDE para ele"
        case .couldNotRun(let reason):
            "não foi possível rodar o claude: \(reason)"
        case .failed(let status, let detail):
            "o claude falhou (\(status))\(detail.isEmpty ? "" : ": \(detail)")"
        case .timedOut(let seconds):
            "o claude não respondeu em \(seconds) s"
        case .emptyOutput:
            "o claude não devolveu nada"
        }
    }
}
