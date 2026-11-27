import Darwin
import Foundation

struct SpeechArguments {
    private static let valuedOptions: Set<String> = [
        "voice", "rate", "output-file", "network-send", "audio-device", "input-file",
        "file-format", "data-format", "channels", "bit-rate", "quality",
    ]
    private static let shortOptions: [Character: String] = [
        "v": "voice", "r": "rate", "o": "output-file", "n": "network-send",
        "a": "audio-device", "f": "input-file", "i": "interactive",
    ]
    private static let queryOptions: Set<String> = ["voice", "audio-device", "file-format", "data-format"]
    private static let longOptions = valuedOptions.union(["interactive", "progress"])

    let arguments: [String]
    private(set) var silent = false
    private(set) var attached = false
    private var hasText = false
    private var input: (path: String, index: Int, prefix: String)?

    var readsStdin: Bool { input.map { $0.path == "-" } ?? !hasText }

    init(_ arguments: [String]) {
        self.arguments = arguments
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                hasText = hasText || index < arguments.count
                break
            }
            if argument == "-" || !argument.hasPrefix("-") {
                hasText = true
                continue
            }

            let option: String
            var inlineValue: String?
            var prefix = ""
            if argument.hasPrefix("--") {
                let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                if Self.longOptions.contains(name) {
                    option = name
                } else {
                    let matches = Self.longOptions.filter { $0.hasPrefix(name) }
                    guard matches.count == 1, let match = matches.first else { continue }
                    option = match
                }
                if parts.count == 2 {
                    inlineValue = String(parts[1])
                    prefix = "--\(name)="
                }
            } else {
                guard let flag = argument.dropFirst().first, let name = Self.shortOptions[flag] else { continue }
                option = name
                let remainder = String(argument.dropFirst(2))
                if !remainder.isEmpty {
                    inlineValue = remainder
                    prefix = "-\(flag)"
                }
            }

            if option == "interactive" || option == "progress" { attached = true }
            guard Self.valuedOptions.contains(option) else { continue }
            let value: String
            let valueIndex: Int
            if let inlineValue {
                value = inlineValue
                valueIndex = index - 1
            } else {
                guard index < arguments.count else { break }
                value = arguments[index]
                valueIndex = index
                index += 1
            }
            if option == "output-file" || (Self.queryOptions.contains(option) && value == "?") {
                silent = true
            }
            if option == "input-file" { input = (value, valueIndex, prefix) }
        }
    }

    func job(stdin: Data? = nil) throws -> SpeechJob {
        var forwarded = arguments
        if let input, input.path != "-" {
            let data = try Data(contentsOf: URL(fileURLWithPath: input.path))
            forwarded[input.index] = input.prefix + "-"
            return SpeechJob(arguments: forwarded, input: data)
        }
        return SpeechJob(arguments: forwarded, input: readsStdin ? stdin : nil)
    }
}

struct SpeechJob: Codable {
    let arguments: [String]
    let input: Data?
}

private var speechPID: pid_t = 0

func forwardTerminationSignals() {
    let handler: @convention(c) (Int32) -> Void = { signal in
        if speechPID > 0 { kill(speechPID, SIGKILL) }
        _exit(128 + signal)
    }
    signal(SIGINT, handler)
    signal(SIGTERM, handler)
    signal(SIGHUP, handler)
}

struct Speaker {
    var executable = "/usr/bin/say"
    var microphoneUsers = Microphone.users
    var pollInterval: TimeInterval = 0.05
    let allowList: () throws -> Set<String>

    func speak(_ job: SpeechJob) throws -> Int32 {
        let input = try job.input.map(anonymousInput)
        defer { try? input?.close() }

        while true {
            let allowed = try allowList()
            guard canSpeak(allowed: allowed) else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }

            try input?.seek(toOffset: 0)
            let say = Process()
            say.executableURL = URL(fileURLWithPath: executable)
            say.arguments = job.arguments
            say.standardInput = input ?? FileHandle.nullDevice
            try say.run()
            speechPID = say.processIdentifier

            var interrupted = false
            while say.isRunning {
                if !canSpeak(allowed: allowed) {
                    interrupted = say.isRunning
                    if interrupted { kill(say.processIdentifier, SIGKILL) }
                    break
                }
                Thread.sleep(forTimeInterval: pollInterval)
            }
            say.waitUntilExit()
            speechPID = 0
            if !interrupted {
                return say.terminationReason == .exit ? say.terminationStatus : 128 + say.terminationStatus
            }
        }
    }

    private func canSpeak(allowed: Set<String>) -> Bool {
        guard let users = try? microphoneUsers() else { return false }
        return users.allSatisfy { user in
            user.identifier.map(allowed.contains) ?? false
        }
    }

    private func anonymousInput(_ data: Data) throws -> FileHandle {
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("safesay.XXXXXX").path
        var path = Array(template.utf8CString)
        let descriptor = mkstemp(&path)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard unlink(path) == 0 else { throw posixError() }
        try handle.write(contentsOf: data)
        return handle
    }
}
