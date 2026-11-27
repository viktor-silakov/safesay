import Darwin
import Foundation

private enum CLI {
    static let version = "0.1.0"
    static let shortOptions = [
        "-h": "--help",
        "-p": "--pause",
        "-R": "--resume",
        "-s": "--status",
        "-q": "--queue",
        "-c": "--cancel",
        "-t": "--ttl",
        "-m": "--mode",
        "-l": "--list-allowed",
        "-M": "--mic-status",
    ]
    static let longOptions = Set(shortOptions.values).union([
        "--allow-app", "--allow-current", "--clear-allowed", "--clear-queue",
        "--remove-allowed", "--version",
    ])
}

struct SafesayError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func report(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("safesay: \(message)\n".utf8))
}

func printUsage() {
    print("""
        Usage: safesay [--ttl DURATION] [say arguments]
               safesay -f -
               safesay --help | --version
               safesay --mode foreground|background
               safesay --queue | --cancel <id> | --clear-queue
               safesay --pause | --resume | --status
               safesay --allow-app <bundle-id-or-executable-path>
               safesay --allow-current
               safesay --remove-allowed <bundle-id-or-executable-path>
               safesay --list-allowed
               safesay --clear-allowed
               safesay --mic-status

        Short options:
        \(CLI.shortOptions.sorted { $0.key < $1.key }.map { "  \($0.key)  \($0.value)" }.joined(separator: "\n"))
          -v  --version when used alone

        Use -v VOICE to select a macOS voice, or -v '?' to list voices.
        Speech expires after 2h of waiting by default. Use durations such as 30s, 5m, or 2h.
        Use -f - to read text from the terminal. See `man say` for speech arguments.
        """)
}

func chooseMode() throws -> Mode? {
    let descriptor = open("/dev/tty", O_RDWR | O_NOCTTY)
    guard descriptor >= 0 else { return nil }
    let terminal = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? terminal.close() }
    let prompt = """
        Choose how safesay should run:
          1. Foreground (wait in this command)
          2. Background (queue speech in a macOS LaunchAgent)
        Select [1]:\u{20}
        """
    while true {
        try terminal.write(contentsOf: Data(prompt.utf8))
        var answer = Data()
        while let byte = try terminal.read(upToCount: 1), !byte.isEmpty {
            if byte.first == 10 { break }
            answer.append(byte)
        }
        switch String(decoding: answer, as: UTF8.self).trimmingCharacters(in: .whitespaces) {
        case "", "1": return .foreground
        case "2": return .background
        default: continue
        }
    }
}

func expandedArguments(_ arguments: [String]) -> [String] {
    if arguments == ["-v"] { return ["--version"] }
    guard let first = arguments.first, let option = CLI.shortOptions[first] else { return arguments }
    return [option] + arguments.dropFirst()
}

func run(_ rawArguments: [String], storage: Storage) throws -> Int32 {
    let arguments = expandedArguments(rawArguments)
    let agent = LaunchAgent(storage: storage)
    let speaker = Speaker(configuration: storage.configuration)

    switch arguments.first {
    case "--help":
        guard arguments.count == 1 else { throw SafesayError("Usage: safesay --help") }
        printUsage()
        return 0
    case "--version":
        guard arguments.count == 1 else { throw SafesayError("Usage: safesay --version") }
        print("safesay \(CLI.version)")
        return 0
    case "--mode":
        guard arguments.count == 2, let mode = Mode(rawValue: arguments[1]) else {
            throw SafesayError("Usage: safesay --mode foreground|background")
        }
        try storage.configure { $0.mode = mode }
        if mode == .background { try agent.register() }
        print("Mode: \(mode.rawValue)")
        return 0
    case "--queue":
        guard arguments.count == 1 else { throw SafesayError("Usage: safesay --queue") }
        let now = Date()
        let entries = try storage.queueEntries(at: now)
        if entries.isEmpty {
            print("No queued jobs.")
        } else {
            print("ID\tAGE\tTEXT")
            for entry in entries {
                let age = Int(max(0, now.timeIntervalSince(entry.queuedAt)))
                print("\(entry.id)\t\(age)s\t\(entry.job.preview)")
            }
        }
        return 0
    case "--cancel":
        guard arguments.count == 2, let id = UInt64(arguments[1]), id > 0 else {
            throw SafesayError("Usage: safesay --cancel <id>")
        }
        guard try storage.cancelJobs(id: id) > 0 else { throw SafesayError("No queued job with ID \(id).") }
        print("Canceled job \(id).")
        return 0
    case "--clear-queue":
        guard arguments.count == 1 else { throw SafesayError("Usage: safesay --clear-queue") }
        print("Canceled jobs: \(try storage.cancelJobs())")
        return 0
    case "--pause", "--resume":
        guard arguments.count == 1 else { throw SafesayError("Usage: safesay --pause | --resume") }
        let paused = arguments[0] == "--pause"
        try storage.configure { $0.paused = paused }
        print(paused ? "Speech paused." : "Speech resumed.")
        return 0
    case "--status":
        guard arguments.count == 1 else { throw SafesayError("Usage: safesay --status") }
        try printStatus(storage: storage, agent: agent)
        return 0
    case "--allow-app":
        guard arguments.count == 2, !arguments[1].isEmpty else {
            throw SafesayError("Usage: safesay --allow-app <bundle-id-or-executable-path>")
        }
        try storage.configure { $0.allowedApps.insert(arguments[1]) }
        print(arguments[1])
        return 0
    case "--remove-allowed":
        guard arguments.count == 2, !arguments[1].isEmpty else {
            throw SafesayError("Usage: safesay --remove-allowed <bundle-id-or-executable-path>")
        }
        let id = arguments[1]
        var removed = false
        try storage.configure { removed = $0.allowedApps.remove(id) != nil }
        print(removed ? "Removed exception for \(id)." : "No exception for \(id).")
        return 0
    case "--list-allowed":
        guard arguments.count == 1 else { throw SafesayError("Usage: safesay --list-allowed") }
        let allowed = try storage.configuration().allowedApps.sorted()
        print(allowed.isEmpty ? "No allowed applications." : allowed.joined(separator: "\n"))
        return 0
    case "--clear-allowed":
        guard arguments.count == 1 else { throw SafesayError("Usage: safesay --clear-allowed") }
        try storage.configure { $0.allowedApps.removeAll() }
        print("Allowed applications cleared.")
        return 0
    case "--allow-current", "--mic-status":
        guard arguments.count == 1 else { throw SafesayError("Unexpected arguments.") }
        let users = try Microphone.users()
        if users.isEmpty {
            print("Microphone idle.")
            return 0
        }
        if arguments[0] == "--allow-current" {
            let identifiers = Set(users.compactMap(\.identifier))
            try storage.configure { $0.allowedApps.formUnion(identifiers) }
        }
        let allowed = try storage.configuration().allowedApps
        for user in users {
            let status = user.identifier.map(allowed.contains) == true ? "allowed" : "blocked"
            print("\(user.identifier ?? "Unknown process") (PID \(user.pid), \(status))")
        }
        return 0
    case "--worker":
        guard arguments.count == 2 else { throw SafesayError("Invalid worker invocation.") }
        forwardTerminationSignals()
        try agent.processQueue(speaker: speaker)
        return 0
    case "--reload-agent":
        guard arguments.count == 1 else { throw SafesayError("Invalid agent reload invocation.") }
        try agent.reloadIfRegistered()
        return 0
    default:
        break
    }

    let options = try speechOptions(arguments)
    let speech = SpeechArguments(options.arguments, commandOptions: CLI.longOptions)
    if let option = speech.singleDashLongOption {
        throw SafesayError("Invalid option '\(option)'. Use '-\(option)'.")
    }
    if speech.silent { try execSay(speech.arguments) }

    var mode = try storage.configuration().mode
    if mode == nil {
        try storage.configure { config in
            if config.mode == nil, let selected = try chooseMode() {
                config.mode = selected
            }
            mode = config.mode
        }
    }

    let terminalInput = isatty(STDIN_FILENO) == 1
    if arguments.isEmpty && terminalInput {
        if mode == .background { try agent.register() }
        if let mode { print("Mode: \(mode.rawValue)\n") }
        printUsage()
        return 0
    }

    forwardTerminationSignals()
    if speech.readsStdin && terminalInput {
        while let line = readLine(strippingNewline: false) {
            let job = try speech.job(stdin: Data(line.utf8), ttl: options.ttl)
            let status = try speakInCommand(job, storage: storage, speaker: speaker)
            if status != 0 { return status }
        }
        return 0
    }

    let input = speech.readsStdin ? FileHandle.standardInput.readDataToEndOfFile() : nil
    let job = try speech.job(stdin: input, ttl: options.ttl)
    if mode == .background && !speech.attached,
       try storage.withConfigurationLock({
           guard try storage.configuration().mode == .background else { return false }
           try agent.register()
           try storage.enqueue(job)
           return true
       }) {
        return 0
    }
    return try speakInCommand(job, storage: storage, speaker: speaker)
}

func speechOptions(_ arguments: [String]) throws -> (arguments: [String], ttl: TimeInterval?) {
    guard let first = arguments.first, first == "--ttl" || first.hasPrefix("--ttl=") else {
        return (arguments, nil)
    }
    let usage = "Usage: safesay --ttl <duration> [say arguments]. Example durations: 30s, 5m, 2h."
    let inline = first.hasPrefix("--ttl=")
    guard inline || arguments.count > 1 else { throw SafesayError(usage) }
    var duration = inline ? String(first.dropFirst("--ttl=".count)) : arguments[1]
    let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600]
    let multiplier = duration.last.flatMap { units[$0] }
    if multiplier != nil { duration.removeLast() }
    guard let value = TimeInterval(duration) else { throw SafesayError(usage) }
    let seconds = value * (multiplier ?? 1)
    guard seconds > 0, seconds.isFinite else { throw SafesayError(usage) }
    return (Array(arguments.dropFirst(inline ? 1 : 2)), seconds)
}

func printStatus(storage: Storage, agent: LaunchAgent) throws {
    let config = try storage.configuration()
    let agentStatus = try agent.status()
    let jobs = try storage.queueEntries().count
    let blockers = (try? Microphone.users())?.filter { user in
        user.identifier.map(config.allowedApps.contains) != true
    }.map { $0.identifier ?? "Unknown process (PID \($0.pid))" }

    print("Mode: \(config.mode?.rawValue ?? "foreground (default)")")
    print("Speech: \(config.paused ? "paused" : "enabled")")
    print("LaunchAgent: \(agentStatus)")
    print("Queued jobs: \(jobs)")
    if let blockers {
        print("Microphone blockers: \(blockers.isEmpty ? "none" : blockers.joined(separator: ", "))")
    } else {
        print("Microphone blockers: unavailable")
    }
}

func speakInCommand(_ job: SpeechJob, storage: Storage, speaker: Speaker) throws -> Int32 {
    let deadline = Date().addingTimeInterval(job.lifetime)
    try privateDirectory(storage.stateDirectory)
    do {
        let status = try withLock(storage.speechLock, until: deadline) { try speaker.speak(job, until: deadline) }
        if let status { return status }
    } catch LockError.timedOut {}
    report("Speech expired before playback.")
    return 0
}

func execSay(_ arguments: [String]) throws -> Never {
    var argv = (["/usr/bin/say"] + arguments).map { strdup($0) }
    argv.append(nil)
    execv("/usr/bin/say", &argv)
    let error = posixError()
    argv.forEach { free($0) }
    throw error
}

let arguments = Array(CommandLine.arguments.dropFirst())
let home = homeDirectory(arguments: arguments)
do {
    exit(try run(arguments, storage: Storage(home: home)))
} catch {
    report(error.localizedDescription)
    exit(1)
}

func homeDirectory(arguments: [String]) -> URL {
    if arguments.first == "--worker", arguments.count == 2 {
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }
    if let path = ProcessInfo.processInfo.environment["HOME"], path.hasPrefix("/") {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}
