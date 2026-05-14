import Foundation
import os

public enum Log {
    public static let subsystem = "org.macconnect.MacConnect"
    public static let net = Logger(subsystem: subsystem, category: "net")
    public static let pair = Logger(subsystem: subsystem, category: "pair")
    public static let plugin = Logger(subsystem: subsystem, category: "plugin")
    public static let app = Logger(subsystem: subsystem, category: "app")
}

/// Small app-local lifecycle log for intermittent field failures where
/// unified logging has already rolled over. This intentionally records
/// state transitions only, not payload contents or clipboard data.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog()

    private let queue = DispatchQueue(label: "macconnect.diagnostics")
    private let maxBytes = 512 * 1024
    private let maxRotatedFiles = 4
    private let directoryURL: URL?
    private let fileURL: URL?

    public init() {
        guard !Self.isRunningTests else {
            directoryURL = nil
            fileURL = nil
            return
        }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            directoryURL = nil
            fileURL = nil
            return
        }
        let directory = appSupport
            .appendingPathComponent("MacConnect", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoryURL = directory
        fileURL = directory.appendingPathComponent("lifecycle.log")
    }

    public var directory: URL? {
        directoryURL
    }

    public func record(_ category: String, _ message: String) {
        guard let fileURL else { return }
        queue.async {
            self.write(fileURL: fileURL, category: category, message: message)
        }
    }

    public func recordSync(_ category: String, _ message: String) {
        guard let fileURL else { return }
        queue.sync {
            self.write(fileURL: fileURL, category: category, message: message)
        }
    }

    private func write(fileURL: URL, category: String, message: String) {
        rotateIfNeeded(fileURL)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            Log.app.notice("Diagnostic log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotateIfNeeded(_ fileURL: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maxBytes else { return }

        let fm = FileManager.default
        for index in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
            let source = rotatedURL(for: fileURL, index: index)
            let target = rotatedURL(for: fileURL, index: index + 1)
            if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: target)
            }
            if fm.fileExists(atPath: source.path) {
                try? fm.moveItem(at: source, to: target)
            }
        }
        let first = rotatedURL(for: fileURL, index: 1)
        if fm.fileExists(atPath: first.path) {
            try? fm.removeItem(at: first)
        }
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.moveItem(at: fileURL, to: first)
        }
    }

    private func rotatedURL(for fileURL: URL, index: Int) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).\(index)")
    }

    private static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["MACCONNECT_ENABLE_DIAGNOSTICS_IN_TESTS"] == "1" {
            return false
        }
        let processName = ProcessInfo.processInfo.processName.lowercased()
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || processName.contains("xctest")
            || processName.contains("packagetests")
            || processName.hasSuffix("tests")
            || NSClassFromString("XCTest.XCTestCase") != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
