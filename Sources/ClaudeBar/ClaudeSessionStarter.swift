import Foundation

enum ClaudeSessionStartError: LocalizedError, Equatable {
    case executableNotFound
    case configuredPathNotExecutable(String)
    case launchFailed(String)
    case timedOut
    case commandFailed(status: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return L("anchor.error.not_found")
        case let .configuredPathNotExecutable(path):
            return L("anchor.error.not_executable", path)
        case let .launchFailed(message):
            return L("anchor.error.launch_failed", message)
        case .timedOut:
            return L("anchor.error.timed_out")
        case let .commandFailed(status, detail):
            let base = L("anchor.error.exit_status", Int(status))
            return detail.isEmpty ? base : "\(base) \(detail)"
        }
    }

    /// A failure before launch never reached Claude, so retrying it costs nothing. Anything after
    /// launch may already have consumed a request and started the window.
    var mayHaveSpentRequest: Bool {
        switch self {
        case .executableNotFound, .configuredPathNotExecutable, .launchFailed:
            return false
        case .timedOut, .commandFailed:
            return true
        }
    }
}

/// Finds the `claude` executable without relying on the shell environment. A GUI app inherits a
/// minimal `PATH` from `launchd`, so the usual installer, Homebrew, and Node version manager
/// locations have to be probed directly.
enum ClaudeCLILocator {
    private static let fixedCandidates = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude"
    ]

    private static let homeRelativeCandidates = [
        ".local/bin/claude",
        ".claude/local/claude",
        ".volta/bin/claude",
        ".bun/bin/claude"
    ]

    static func resolve(
        configuredPath: String?,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        if let configuredPath {
            let expanded = (configuredPath as NSString).expandingTildeInPath
            guard fileManager.isExecutableFile(atPath: expanded) else {
                throw ClaudeSessionStartError.configuredPathNotExecutable(expanded)
            }
            return URL(fileURLWithPath: expanded)
        }

        let candidates = fixedCandidates
            + homeRelativeCandidates.map { homeDirectory.appendingPathComponent($0).path }
            + nodeVersionManagerCandidates(fileManager: fileManager, homeDirectory: homeDirectory)
            + pathCandidates(environment: environment)

        guard let match = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw ClaudeSessionStartError.executableNotFound
        }
        return URL(fileURLWithPath: match)
    }

    /// nvm and fnm keep one bin directory per installed Node version. Newest version first, so a
    /// stale install does not win over the current one.
    private static func nodeVersionManagerCandidates(fileManager: FileManager, homeDirectory: URL) -> [String] {
        let roots = [
            (root: homeDirectory.appendingPathComponent(".nvm/versions/node"), bin: "bin"),
            (root: homeDirectory.appendingPathComponent(".local/share/fnm/node-versions"), bin: "installation/bin")
        ]

        return roots.flatMap { entry -> [String] in
            let versions = (try? fileManager.contentsOfDirectory(atPath: entry.root.path)) ?? []
            return versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { entry.root.appendingPathComponent("\($0)/\(entry.bin)/claude").path }
        }
    }

    private static func pathCandidates(environment: [String: String]) -> [String] {
        guard let path = environment["PATH"] else { return [] }
        return path.split(separator: ":").map { "\($0)/claude" }
    }
}

/// Runs `claude -p` once to spend a single request and start the 5-hour window.
struct ClaudeSessionStarter: Sendable {
    /// The anchoring prompt runs on a model chosen here rather than the user's default, so
    /// anchoring never changes which model their real work uses, and costs as little as possible.
    private static let model = "haiku"

    /// No tools and no MCP servers: this session exists to spend one request, not to touch files
    /// or spin up the user's integrations. Not persisted, so it never shows up in `/resume`.
    /// `--bare` is deliberately absent because it skips the keychain read that subscription
    /// login depends on.
    private static let arguments = [
        "-p",
        "--model", model,
        "--tools", "",
        "--strict-mcp-config",
        "--no-session-persistence"
    ]

    /// Tail of the CLI output kept for diagnostics. Long enough to show an error line, short
    /// enough that a verbose log or the model's reply does not end up in the UI.
    private static let failureDetailLimit = 240

    /// Returns the moment the request was sent.
    func start(prompt: String, timeout: TimeInterval) async throws -> Date {
        let executable = try ClaudeCLILocator.resolve(configuredPath: FiveHourAnchorPreferences.cliPath)
        let startedAt = Date()
        let invocation = ClaudeProcessInvocation(
            executable: executable,
            arguments: Self.arguments + [prompt],
            timeout: timeout,
            failureDetailLimit: Self.failureDetailLimit
        )
        try await invocation.run()
        return startedAt
    }
}

/// One `Process` run wrapped for async use. The process, pipe, and continuation are shared across
/// the termination handler, the reader handler, and the timeout timer, so all mutable state is
/// guarded by a lock.
private final class ClaudeProcessInvocation: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let failureDetailLimit: Int

    private var output = Data()
    private var continuation: CheckedContinuation<Void, Error>?
    private var isFinished = false
    private var didTimeOut = false

    init(executable: URL, arguments: [String], timeout: TimeInterval, failureDetailLimit: Int) {
        self.timeout = timeout
        self.failureDetailLimit = failureDetailLimit
        process.executableURL = executable
        process.arguments = arguments
        // Outside any project, so no project CLAUDE.md or settings are picked up.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = Self.environment(for: executable)
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = FileHandle.nullDevice
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.appendOutput(chunk)
            }

            process.terminationHandler = { [weak self] process in
                self?.finish(status: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                finish(error: .launchFailed(error.localizedDescription))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.timeOut()
            }
        }
    }

    private func appendOutput(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        output.append(chunk)
    }

    private func timeOut() {
        lock.lock()
        let alreadyFinished = isFinished
        if !alreadyFinished {
            didTimeOut = true
        }
        lock.unlock()

        guard !alreadyFinished else { return }
        process.terminate()
        finish(error: .timedOut)
    }

    private func finish(status: Int32) {
        lock.lock()
        let timedOut = didTimeOut
        let detail = failureDetail()
        lock.unlock()

        guard !timedOut else { return }
        finish(error: status == 0 ? nil : .commandFailed(status: status, detail: detail))
    }

    private func finish(error: ClaudeSessionStartError?) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        lock.unlock()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Caller holds `lock`.
    private func failureDetail() -> String {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > failureDetailLimit else { return text }
        return "..." + text.suffix(failureDetailLimit)
    }

    /// An npm-installed `claude` is a `#!/usr/bin/env node` script, so `node` has to be reachable.
    /// A GUI app's `PATH` does not include the Node install directory, so the executable's own
    /// directory is prepended.
    private static func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executable.deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(executableDirectory):\(existingPath)"
        return environment
    }
}
