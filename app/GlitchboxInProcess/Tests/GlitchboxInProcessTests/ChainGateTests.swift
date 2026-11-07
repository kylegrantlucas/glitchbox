import Foundation
import Synchronization
import Testing
@testable import GlitchboxInProcess

extension InProcessTests {
    /// ffgac | ffedit | ffmpeg over `input`, as MoshChain builds it.
    static func moshStages(input: URL, output: URL, log: URL) -> [PipeChain.Stage] {
        let script = Fixture.repo.appending(path: "scripts/mosh.js").path
        return [
            PipeChain.Stage(tool: .ffgac, argv: { _, out in
                ["ffgac", "-hide_banner", "-nostdin", "-loglevel", "error", "-i", input.path, "-an",
                 "-mpv_flags", "+nopimb+forcemv", "-qscale:v", "4", "-g", "max", "-bf", "0", "-sc_threshold", "max",
                 "-vcodec", "mpeg2video", "-f", "rawvideo", out!]
            }, log: log),
            PipeChain.Stage(tool: .ffedit, argv: { inp, out in
                ["ffedit", "-i", inp!, "-f", "mv", "-s", script,
                 "-sp", #"{"tail":4,"h_scale":1,"v_scale":1,"pan_x":0,"pan_y":0}"#, "-o", out!]
            }, log: log),
            PipeChain.Stage(tool: .ffmpeg, argv: { inp, _ in
                ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "mpegvideo", "-i", inp!,
                 "-c:v", "ffvhuff", "-y", output.path]
            }, log: log),
        ]
    }

    /// Two pipe chains started at the same instant used to deadlock on the libraries' per-tool
    /// locks; both must finish, every time.
    @Test func simultaneousChainsFinish() async throws {
        let f = try await Fixture.get()
        let dir = f.dir.appending(path: "chains", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clip = dir.appending(path: "clip.mp4")
        let code = try await PipeChain.run([PipeChain.Stage(tool: .ffmpeg, argv: { _, _ in
            ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "lavfi",
             "-i", "testsrc2=size=1280x720:rate=30:duration=3", "-c:v", "libx264", "-preset", "ultrafast",
             "-pix_fmt", "yuv420p", "-y", clip.path]
        }, log: dir.appending(path: "clip.log"))], log: dir.appending(path: "clip.log"))
        try #require(code == 0)

        let rounds = 12
        let done = Mutex(0)
        let work = Task {
            for round in 0..<rounds {
                let log = dir.appending(path: "round\(round).log")
                async let a = PipeChain.run(Self.moshStages(input: clip, output: dir.appending(path: "a.mkv"), log: log), log: log)
                async let b = PipeChain.run(Self.moshStages(input: clip, output: dir.appending(path: "b.mkv"), log: log), log: log)
                let (ca, cb) = try await (a, b)
                #expect(ca == 0 && cb == 0, "round \(round): \(Fixture.log(log))")
                done.withLock { $0 += 1 }
            }
        }
        let deadline = ContinuousClock.now + .seconds(240)
        while done.withLock({ $0 }) < rounds && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let finished = done.withLock { $0 }
        #expect(finished == rounds, "chains hung: only \(finished)/\(rounds) rounds finished")
        if finished == rounds { try await work.value }
    }

    /// A chain cancelled while queued behind another returns promptly without running.
    @Test func queuedChainCancelsPromptly() async throws {
        let started = Mutex(false), ran = Mutex(false)
        let holder = Task {
            try await ChainGate.shared.run {
                started.withLock { $0 = true }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        let waiter = Task { try await ChainGate.shared.run { ran.withLock { $0 = true } } }
        try await Task.sleep(for: .milliseconds(100))
        let t0 = ContinuousClock.now
        waiter.cancel()
        let result = await waiter.result
        #expect(ContinuousClock.now - t0 < .milliseconds(500))
        #expect(throws: CancellationError.self) { try result.get() }
        try await holder.value
        #expect(!ran.withLock { $0 })
    }
}
