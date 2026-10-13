//
//  InjectorV3.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/9.
//

import CocoaLumberjackSwift
import Foundation

final class InjectorV3 {
    enum LoggerType {
        case os
        case file
    }

    static let temporaryRoot: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent(Constants.gAppIdentifier, isDirectory: true)
        .appendingPathComponent("InjectorV3", isDirectory: true)

    static let main = try! InjectorV3(Bundle.main.bundleURL)

    // The manual injection UI, automatic reinjection and `trollfoolscli` (spawned by the
    // TrollStore integration) can all modify the same application bundle. Modifying a
    // bundle concurrently can corrupt an operation or make both operations fail, so every
    // inject/eject action is serialized within the process (NSRecursiveLock) and across
    // processes (flock on a shared lock file).
    private static let operationLock = NSRecursiveLock()
    private static var operationLockDepth = 0

    static let operationLockFileURL = URL(
        fileURLWithPath: "/var/mobile/Library/TrollFools/.operation.lock"
    )

    private static let operationLockFD: Int32 = {
        let directoryURL = operationLockFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        // A read-only descriptor is sufficient for flock(2) and still works when the lock
        // file was created by another user (root CLI vs. mobile app).
        let fd = open(operationLockFileURL.path, O_CREAT | O_RDONLY | O_CLOEXEC, 0o666)
        if fd >= 0 {
            _ = fchmod(fd, 0o666)
        } else {
            DDLogError("Unable to open operation lock file: \(String(cString: strerror(errno)))")
        }
        return fd
    }()

    func withOperationLock<T>(_ body: () throws -> T) rethrows -> T {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }

        // flock(2) is not reentrant per descriptor: unlocking in a nested call would
        // release the outer lock. Only the outermost call takes and releases it.
        let fd = Self.operationLockFD
        let isOutermost = Self.operationLockDepth == 0
        if isOutermost, fd >= 0 {
            while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        }
        Self.operationLockDepth += 1
        defer {
            Self.operationLockDepth -= 1
            if isOutermost, fd >= 0 {
                flock(fd, LOCK_UN)
            }
        }

        return try body()
    }

    let bundleURL: URL
    let temporaryDirectoryURL: URL
    let isPrivileged: Bool = geteuid() == 0

    var appID: String!
    var teamID: String!

    private(set) var executableURL: URL!
    private(set) var frameworksDirectoryURL: URL!
    private(set) var logsDirectoryURL: URL!

    var useWeakReference: Bool = false
    var preferMainExecutable: Bool = false
    var useFrameworkEnumerationFallback: Bool = true
    var injectStrategy: Strategy = .lexicographic
    var didUseMachOEnumerationFallback: Bool = false

    let logger: DDLog
    let loggerType: LoggerType

    private init() { fatalError("Not implemented") }

    init(_ bundleURL: URL, loggerType: LoggerType = .file) throws {
        self.bundleURL = bundleURL
        temporaryDirectoryURL = Self.temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)

        logger = DDLog()
        self.loggerType = loggerType

        let executableURL = try locateExecutableInBundle(bundleURL)
        let frameworksDirectoryURL = try locateFrameworksDirectoryInBundle(bundleURL)
        let appID = try identifierOfBundle(bundleURL)
        let teamID = try teamIdentifierOfMachO(executableURL) ?? ""

        self.appID = appID
        self.teamID = teamID
        self.executableURL = executableURL
        self.frameworksDirectoryURL = frameworksDirectoryURL
        logsDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Logs/\(appID)")

        setupLoggers()
    }

    // MARK: - Instance Methods

    func terminateApp() {
        TFUtilKillAll(executableURL.lastPathComponent, true)
    }

    // MARK: - Logger

    private func setupLoggers() {
        if loggerType == .file {
            try? FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)

            let fileLogger = DDFileLogger(logFileManager: DDLogFileManagerDefault(logsDirectory: logsDirectoryURL.path))

            fileLogger.rollingFrequency = 60 * 60 * 24
            fileLogger.logFileManager.maximumNumberOfLogFiles = 7
            fileLogger.doNotReuseLogFiles = true

            logger.add(fileLogger)
        }

        logger.add(DDOSLogger.sharedInstance)

        DDLogWarn("Logger setup \(appID!)", asynchronous: false, ddlog: logger)
    }

    var latestLogFileURL: URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: logsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey]
        ) else {
            return nil
        }

        var latestLogFileURL: URL?
        var latestCreationDate: Date?
        while let fileURL = enumerator.nextObject() as? URL {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey]),
                  let isRegularFile = resourceValues.isRegularFile, isRegularFile,
                  let creationDate = resourceValues.creationDate
            else {
                continue
            }

            if latestCreationDate == nil || creationDate > latestCreationDate! {
                latestLogFileURL = fileURL
                latestCreationDate = creationDate
            }
        }

        return latestLogFileURL
    }

    // MARK: - Persistent

    static let persistentPlugInsRootURL: URL = {
        let url = URL(fileURLWithPath: "/var/mobile/Library/TrollFools/PersistentPlugins")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    lazy var persistentPlugInsDirectoryURL: URL = {
        let url = Self.persistentPlugInsRootURL.appendingPathComponent(appID, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
