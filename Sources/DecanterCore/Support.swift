import CryptoKit
import Foundation

public struct DecanterError: LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Everything Decanter owns lives under one folder so removing it is a clean uninstall.
public enum Paths {
    public static var root: URL = {
        if let override = ProcessInfo.processInfo.environment["DECANTER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Decanter", isDirectory: true)
    }()

    public static var runtimes: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public static var components: URL { root.appendingPathComponent("Components", isDirectory: true) }
    public static var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public static var bottles: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    public static var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public static var covers: URL { root.appendingPathComponent("Covers", isDirectory: true) }
    public static var template: URL { root.appendingPathComponent("Template", isDirectory: true) }
    public static var runtimeManifest: URL { root.appendingPathComponent("runtime.json") }
    public static var library: URL { root.appendingPathComponent("library.json") }
    public static var bottleList: URL { root.appendingPathComponent("bottles.json") }

    public static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// "5 minutes", "30 seconds", for messages.
    var spokenLength: String {
        let seconds = Int(timeInterval.rounded())
        if seconds >= 60, seconds % 60 == 0 { return seconds == 60 ? "a minute" : "\(seconds / 60) minutes" }
        return seconds == 1 ? "a second" : "\(seconds) seconds"
    }
}

public struct ProcessResult {
    public let status: Int32
    public let output: String
}

public enum Shell {
    /// Runs a process to completion, capturing stdout+stderr. Throws on non-zero exit unless `check` is false.
    ///
    /// Cancelling the calling task stops the process (and throws `CancellationError`); so does `timeout`
    /// running out (and throws a `DecanterError` saying so). It returns when the process exits, even if
    /// something it started in the background keeps its output open, as `wineserver` can.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        cwd: URL? = nil,
        check: Bool = true,
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let output = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                output.finish()
            } else {
                output.append(data)
            }
        }
        let stopper = Stopper(process)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                stopper.launched()
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { stopper.stop(timedOut: true) }
                }
            }
        } onCancel: {
            stopper.stop(timedOut: false)
        }

        // Whatever is still in the pipe arrives right away; a background child holding it open
        // must not keep the caller waiting.
        for _ in 0..<20 where !output.isFinished { try? await Task.sleep(for: .milliseconds(25)) }
        pipe.fileHandleForReading.readabilityHandler = nil
        let text = String(decoding: output.data, as: UTF8.self)

        if stopper.timedOut, let timeout {
            throw DecanterError("\(executable.lastPathComponent) didn't finish within \(timeout.spokenLength) and was stopped.")
        }
        try Task.checkCancellation()
        if check && status != 0 {
            let tail = text.split(separator: "\n").suffix(6).joined(separator: "\n")
            throw DecanterError("\(executable.lastPathComponent) exited with status \(status)\n\(tail)")
        }
        return ProcessResult(status: status, output: text)
    }

    /// Ends a process for a timeout or a cancellation, including one that comes before it has started.
    private final class Stopper: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var started = false, stopRequested = false
        private(set) var timedOut = false

        init(_ process: Process) { self.process = process }

        func launched() {
            lock.lock()
            started = true
            let stopNow = stopRequested
            lock.unlock()
            if stopNow { stop(timedOut: false) }
        }

        func stop(timedOut: Bool) {
            lock.lock()
            let canStop = started && process.isRunning
            stopRequested = true
            if timedOut && canStop { self.timedOut = true }
            lock.unlock()
            guard canStop else { return }
            process.terminate()
            // A process that ignores the request is ended for good a little later.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var finished = false
        func append(_ data: Data) { lock.lock(); buffer.append(data); lock.unlock() }
        func finish() { lock.lock(); finished = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    @discardableResult
    public static func run(
        _ path: String, _ arguments: [String], check: Bool = true, timeout: Duration? = nil
    ) async throws -> ProcessResult {
        try await run(URL(fileURLWithPath: path), arguments, check: check, timeout: timeout)
    }
}

public enum Checksum {
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads a file to disk with progress reporting.
public final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    public static func download(
        from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = Downloader(destination: destination, onProgress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        // Cancelling the calling task cancels the transfer, which then ends with URLError.cancelled.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                var request = URLRequest(url: url)
                request.setValue("Decanter", forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: request)
                delegate.attach(task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
        try Task.checkCancellation()
    }

    private let cancelLock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    /// A transfer that starts after a cancellation is cancelled as it starts.
    private func attach(_ task: URLSessionDownloadTask) {
        cancelLock.lock()
        self.task = task
        let cancelNow = cancelled
        cancelLock.unlock()
        if cancelNow { task.cancel() }
    }

    private func cancel() {
        cancelLock.lock()
        cancelled = true
        let running = task
        cancelLock.unlock()
        running?.cancel()
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = DecanterError("Download failed: HTTP \(http.statusCode)")
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? failure {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int
        let browser_download_url: URL
        let digest: String?

        /// The asset's SHA-256 in lowercase hex, from GitHub's `sha256:…` digest; nil without one.
        var sha256: String? {
            guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
            let hex = digest.dropFirst("sha256:".count).lowercased()
            return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
        }
    }
    let tag_name: String
    let prerelease: Bool
    let assets: [Asset]
}

enum GitHub {
    static func releases(_ repo: String) async throws -> [GitHubRelease] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=10")!)
        request.setValue("Decanter", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DecanterError("Couldn't reach GitHub to look up \(repo) releases.")
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }
}
