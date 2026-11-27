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
        }, pollInterval: 0.01, allowList: { ["example.allowed"] })
        let script = #"printf 'started\n' >> "$1"; /bin/sleep 0.4; cat >> "$1""#
        let job = SpeechJob(arguments: ["-c", script, "sh", log.path], input: Data("phrase\n".utf8))
        XCTAssertEqual(try speaker.speak(job), 0)
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
