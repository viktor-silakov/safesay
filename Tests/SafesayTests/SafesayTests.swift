import Foundation
import XCTest
@testable import safesay

final class SafesayTests: XCTestCase {
    func testSpeechArgumentClassification() throws {
        XCTAssertTrue(SpeechArguments(["-v?"]).silent)
        XCTAssertTrue(SpeechArguments(["hello", "--out=test.aiff"]).silent)
        XCTAssertFalse(SpeechArguments(["--", "-o", "test.aiff"]).silent)
        XCTAssertFalse(SpeechArguments(["-f", "--output-file=test.aiff"]).silent)
        XCTAssertTrue(SpeechArguments(["--interactive=/green", "hello"]).attached)
        XCTAssertTrue(SpeechArguments(["--input-file=-"]).readsStdin)
        XCTAssertFalse(SpeechArguments(["-r200", "hello"]).readsStdin)
    }

    func testQueueRetainsFileInputAndOrder() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("text.txt")
        try Data("first".utf8).write(to: path)
        let storage = Storage(home: home)
        try privateDirectory(storage.stateDirectory)
        try storage.enqueue(SpeechArguments(["--input-file=\(path.path)"]).job())
        try storage.enqueue(SpeechArguments(["second"]).job())
        try FileManager.default.removeItem(at: path)

        let jobs = try storage.pendingJobs().map {
            try JSONDecoder().decode(SpeechJob.self, from: Data(contentsOf: $0))
        }
        XCTAssertEqual(jobs.first?.arguments, ["--input-file=-"])
        XCTAssertEqual(jobs.first?.input, Data("first".utf8))
        XCTAssertEqual(jobs.last?.arguments, ["second"])
    }

    func testLegacyJobsExpireAndIDsAreNotReusedAfterCancellation() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = Storage(home: home)
        try privateDirectory(storage.queueDirectory)
        let oldJob = storage.jobPath(8)
        try Data(#"{"arguments":["old"]}"#.utf8).write(to: oldJob)
        let queuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: queuedAt], ofItemAtPath: oldJob.path)

        let entries = try storage.queueEntries(at: queuedAt.addingTimeInterval(7199))
        XCTAssertEqual(entries.first?.job.preview, "old")
        XCTAssertEqual(entries.first?.expiresAt, queuedAt.addingTimeInterval(7200))
        XCTAssertTrue(try storage.queueEntries(at: queuedAt.addingTimeInterval(7200)).isEmpty)
        XCTAssertEqual(try storage.cancelJobs(id: 8), 1)
        try storage.enqueue(SpeechArguments(["new"]).job(ttl: 60))
        XCTAssertEqual(try storage.queueEntries().map(\.id), [9])
        XCTAssertEqual(try storage.cancelJobs(), 1)
        try storage.enqueue(SpeechArguments(["latest"]).job())
        XCTAssertEqual(try storage.queueEntries().map(\.id), [10])
        XCTAssertEqual(try storage.cancelJobs(id: 9), 0)
    }

    func testSpeechOptionsForwardNativeArguments() throws {
        let options = try speechOptions(["--ttl", "5m", "-v", "Alex", "hello"])
        XCTAssertEqual(options.ttl, 300)
        XCTAssertEqual(options.arguments, ["-v", "Alex", "hello"])
        XCTAssertEqual(try speechOptions(["--ttl=2h", "hello"]).ttl, 7200)
        XCTAssertEqual(try speechOptions(["--", "--ttl"]).arguments, ["--", "--ttl"])
        XCTAssertThrowsError(try speechOptions(["--ttl", "-5s"]))
        XCTAssertThrowsError(try speechOptions(["--ttl"]))
    }

    func testPausedPhraseExpiresBeforeItCanStart() throws {
        let speaker = Speaker(executable: "/does-not-exist", microphoneUsers: { [] }, configuration: {
            var config = Configuration()
            config.paused = true
            return config
        })
        let job = SpeechJob(arguments: ["quiet"], input: nil)
        XCTAssertNil(try speaker.speak(job, until: Date().addingTimeInterval(0.1)))
    }

    func testCancellationInterruptsPlayback() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let speaker = Speaker(executable: "/bin/sh", microphoneUsers: { [] }, pollInterval: 0.01,
                              configuration: { Configuration() })
        let script = #": > "$1"; exec /bin/sleep 2"#
        let job = SpeechJob(arguments: ["-c", script, "sh", started.path], input: nil)
        let result = try speaker.speak(job, until: Date().addingTimeInterval(5)) {
            FileManager.default.fileExists(atPath: started.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertNil(result)
    }

    func testSpeakerWaitsAndReplaysWhenCaptureStarts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("speech.log")
        let allowed = MicrophoneUser(pid: 10, identifier: "example.allowed")
        let blocked = MicrophoneUser(pid: 20, identifier: "example.blocked")
        var initialProbe = true
        var interruptedProbes = 0
        var observedTwoStarts = false
        let speaker = Speaker(executable: "/bin/sh", microphoneUsers: {
            let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if initialProbe {
                XCTAssertTrue(logText.isEmpty)
                initialProbe = false
                return [allowed, blocked]
            }
            if logText == "started\n", interruptedProbes < 2 {
                interruptedProbes += 1
                return [allowed, blocked]
            }
            observedTwoStarts = observedTwoStarts || logText == "started\nstarted\n"
            return [allowed]
        }, pollInterval: 0.01, configuration: {
            var config = Configuration()
            config.allowedApps = ["example.allowed"]
            return config
        })
        let script = #"printf 'started\n' >> "$1"; /bin/sleep 0.4; cat >> "$1""#
        let job = SpeechJob(arguments: ["-c", script, "sh", log.path], input: Data("phrase\n".utf8))
        XCTAssertEqual(try speaker.speak(job, until: Date().addingTimeInterval(5)), 0)
        XCTAssertTrue(observedTwoStarts)
        XCTAssertEqual(interruptedProbes, 2)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "started\nstarted\nphrase\n")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try privateDirectory(url)
        return url
    }
}
