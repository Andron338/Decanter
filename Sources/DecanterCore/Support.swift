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
    public static var template: URL { root.appendingPathComponent("Template", isDirectory: true) }
    public static var runtimeManifest: URL { root.appendingPathComponent("runtime.json") }
    public static var library: URL { root.appendingPathComponent("library.json") }

    public static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

public struct ProcessResult {
    public let status: Int32
    public let output: String
}

public enum Shell {
    /// Runs a process to completion, capturing stdout+stderr. Throws on non-zero exit unless `check` is false.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        cwd: URL? = nil,
        check: Bool = true
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }
                if let cwd { process.currentDirectoryURL = cwd }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                if check && process.terminationStatus != 0 {
                    let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
                    continuation.resume(throwing: DecanterError(
                        "\(executable.lastPathComponent) exited with status \(process.terminationStatus)\n\(tail)"))
                } else {
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, output: output))
                }
            }
        }
    }

    @discardableResult
    public static func run(_ path: String, _ arguments: [String], check: Bool = true) async throws -> ProcessResult {
        try await run(URL(fileURLWithPath: path), arguments, check: check)
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("Decanter", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
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
