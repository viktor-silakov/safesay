import Darwin
import Foundation

struct SafesayError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func report(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("safesay: \(message)\n".utf8))
}

func printUsage() {
    print("""
        Usage: safesay [say arguments]
               safesay -f -
               safesay --mode foreground|background
               safesay --allow-app <bundle-id-or-executable-path>
               safesay --allow-current
               safesay --mic-status

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

func run(_ arguments: [String], storage: Storage) throws -> Int32 {
    let agent = LaunchAgent(storage: storage)
    let speaker = Speaker(allowList: { try storage.configuration().allowedApps })

    switch arguments.first {
    case "--help" where arguments.count == 1:
        printUsage()
        return 0
    case "--mode":
        guard arguments.count == 2, let mode = Mode(rawValue: arguments[1]) else {
            throw SafesayError("Usage: safesay --mode foreground|background")
        }
        try storage.configure { $0.mode = mode }
        if mode == .background { try agent.register() }
        print("Mode: \(mode.rawValue)")
        return 0
    case "--allow-app":
        guard arguments.count == 2, !arguments[1].isEmpty else {
            throw SafesayError("Usage: safesay --allow-app <bundle-id-or-executable-path>")
        }
        try storage.configure { $0.allowedApps.insert(arguments[1]) }
        print(arguments[1])
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
    default:
        break
    }

    let speech = SpeechArguments(arguments)
    if speech.silent { try execSay(arguments) }

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
            let job = try speech.job(stdin: Data(line.utf8))
            let status = try speakInCommand(job, storage: storage, speaker: speaker)
            if status != 0 { return status }
        }
        return 0
    }

    let input = speech.readsStdin ? FileHandle.standardInput.readDataToEndOfFile() : nil
    let job = try speech.job(stdin: input)
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

func speakInCommand(_ job: SpeechJob, storage: Storage, speaker: Speaker) throws -> Int32 {
    try privateDirectory(storage.stateDirectory)
    return try withLock(storage.speechLock) { try speaker.speak(job) }
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
