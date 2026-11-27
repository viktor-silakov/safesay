import Darwin
import Foundation

enum Mode: String, Codable {
    case foreground, background
}

struct Configuration: Codable {
    var mode: Mode?
    var allowedApps: Set<String> = []
    var paused = false

    init() {}

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        mode = try fields.decodeIfPresent(Mode.self, forKey: .mode)
        allowedApps = Set(try fields.decodeIfPresent([String].self, forKey: .allowedApps) ?? [])
        paused = try fields.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeIfPresent(mode, forKey: .mode)
        try fields.encode(allowedApps.sorted(), forKey: .allowedApps)
        if paused { try fields.encode(paused, forKey: .paused) }
    }

    private enum CodingKeys: String, CodingKey { case mode, allowedApps, paused }
}

struct QueueEntry {
    let id: UInt64
    let job: SpeechJob
    let queuedAt: Date

    var expiresAt: Date { queuedAt.addingTimeInterval(job.lifetime) }
}

struct Storage {
    let home: URL
    let configDirectory: URL
    let stateDirectory: URL
    let queueDirectory: URL

    private var config: URL { configDirectory.appendingPathComponent("config.json") }
    private var configLock: URL { configDirectory.appendingPathComponent("config.lock") }
    private var queueLock: URL { stateDirectory.appendingPathComponent("queue.lock") }
    private var queueSequence: URL { stateDirectory.appendingPathComponent("queue-sequence") }
    var speechLock: URL { stateDirectory.appendingPathComponent("speech.lock") }

    init(home: URL) {
        self.home = home.standardizedFileURL
        configDirectory = self.home.appendingPathComponent(".config/safesay", isDirectory: true)
        stateDirectory = self.home.appendingPathComponent("Library/Application Support/safesay", isDirectory: true)
        queueDirectory = stateDirectory.appendingPathComponent("queue", isDirectory: true)
    }

    func configuration() throws -> Configuration {
        do {
            return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: config))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Configuration()
        }
    }

    func configure(_ update: (inout Configuration) throws -> Void) throws {
        try withConfigurationLock {
            var current = try configuration()
            let old = try encode(current)
            try update(&current)
            let new = try encode(current)
            if old != new { try new.write(to: config, options: .atomic) }
        }
    }

    func withConfigurationLock<T>(_ action: () throws -> T) throws -> T {
        try privateDirectory(configDirectory)
        return try withLock(configLock, perform: action)
    }

    func enqueue(_ job: SpeechJob) throws {
        try privateDirectory(queueDirectory)
        try withQueueLock {
            let lastPending = try pendingJobs().last.flatMap(jobID) ?? 0
            let lastAssigned = try lastAssignedJobID()
            let (sequence, overflow) = max(lastPending, lastAssigned).addingReportingOverflow(1)
            if overflow { throw SafesayError("The queue has run out of job IDs.") }
            try Data(String(sequence).utf8).write(to: queueSequence, options: .atomic)
            let stage = stateDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            try encode(job).write(to: stage, options: .atomic)
            try FileManager.default.moveItem(at: stage, to: jobPath(sequence))
        }
    }

    func withQueueLock<T>(_ action: () throws -> T) throws -> T {
        try privateDirectory(stateDirectory)
        return try withLock(queueLock, perform: action)
    }

    func pendingJobs() throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil)
                .filter { jobID($0) != nil }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
    }

    func readJob(_ path: URL) throws -> QueueEntry {
        guard let id = jobID(path) else { throw SafesayError("Invalid queue job ID.") }
        let job = try JSONDecoder().decode(SpeechJob.self, from: Data(contentsOf: path))
        let queuedAt = try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let queuedAt else { throw SafesayError("The queued job has no timestamp.") }
        return QueueEntry(id: id, job: job, queuedAt: queuedAt)
    }

    func queueEntries(at now: Date = Date()) throws -> [QueueEntry] {
        guard !pendingJobsAreMissing else { return [] }
        return try withQueueLock {
            try pendingJobs().compactMap { path in
                guard let entry = try? readJob(path), entry.expiresAt > now else { return nil }
                return entry
            }
        }
    }

    func cancelJobs(id: UInt64? = nil) throws -> Int {
        guard !pendingJobsAreMissing else { return 0 }
        return try withQueueLock {
            let pending = try pendingJobs()
            let paths = pending.filter { id == nil || jobID($0) == id }
            guard !paths.isEmpty else { return 0 }
            if let latest = pending.last.flatMap(jobID), latest > (try lastAssignedJobID()) {
                try Data(String(latest).utf8).write(to: queueSequence, options: .atomic)
            }
            for path in paths { try FileManager.default.removeItem(at: path) }
            return paths.count
        }
    }

    func jobPath(_ id: UInt64) -> URL {
        queueDirectory.appendingPathComponent(String(format: "%020llu.job", id))
    }

    private var pendingJobsAreMissing: Bool { !FileManager.default.fileExists(atPath: queueDirectory.path) }

    private func jobID(_ path: URL) -> UInt64? {
        guard path.pathExtension == "job", let id = UInt64(path.deletingPathExtension().lastPathComponent),
              id > 0, jobPath(id).lastPathComponent == path.lastPathComponent else { return nil }
        return id
    }

    private func lastAssignedJobID() throws -> UInt64 {
        do {
            let value = try String(contentsOf: queueSequence, encoding: .utf8)
            guard let id = UInt64(value) else { throw SafesayError("The queue sequence is invalid.") }
            return id
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return 0
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

func privateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}

enum LockError: Error { case timedOut }

func withLock<T>(_ url: URL, until deadline: Date? = nil, perform: () throws -> T) throws -> T {
    let descriptor = open(url.path, O_CREAT | O_CLOEXEC | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw posixError() }
    defer { close(descriptor) }
    let operation = deadline == nil ? LOCK_EX : LOCK_EX | LOCK_NB
    while flock(descriptor, operation) != 0 {
        if errno == EINTR { continue }
        guard let deadline, errno == EWOULDBLOCK else { throw posixError() }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw LockError.timedOut }
        Thread.sleep(forTimeInterval: min(remaining, 0.2))
    }
    return try perform()
}

func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
