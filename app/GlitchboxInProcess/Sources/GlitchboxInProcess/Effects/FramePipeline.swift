import Foundation

// Overlaps a native step's stages (decode → effect → convert + encode) on three threads.
// Each stage still sees the frames one at a time and in order, so outputs are unchanged; only
// the stages' work for neighbouring frames runs at the same time. Frames travel in a fixed set
// of preallocated buffers that circulate between the stages, which bounds memory to that set.

/// A blocking FIFO between threads. `close()` ends it: `receive` drains what is queued, then
/// returns nil; `send` after close returns false (the other side is gone).
final class Channel<T>: @unchecked Sendable {
    private let lock = NSCondition()
    private var items: [T] = []
    private var head = 0
    private var closed = false

    init(_ initial: [T] = []) { items = initial }

    @discardableResult
    func send(_ item: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        items.append(item)
        lock.signal()
        return true
    }

    func receive() -> T? {
        lock.lock()
        defer { lock.unlock() }
        while head == items.count && !closed { lock.wait() }
        guard head < items.count else { return nil }
        let item = items[head]
        head += 1
        if head == items.count { items.removeAll(keepingCapacity: true); head = 0 }
        return item
    }

    func close() {
        lock.lock()
        closed = true
        lock.broadcast()
        lock.unlock()
    }
}

/// A frame-sized byte buffer allocated once and reused for every frame.
final class FrameBuffer: @unchecked Sendable {
    let bytes: UnsafeMutableRawBufferPointer
    /// Per-frame values the stages pass along with the pixels.
    var time: Int64? = nil
    var index: Int64 = 0
    var seconds: Double = 0

    init(byteCount: Int) {
        bytes = .allocate(byteCount: byteCount, alignment: 64)
        bytes.initializeMemory(as: UInt8.self, repeating: 0)
    }

    deinit { bytes.deallocate() }

    var base: UnsafeMutableRawPointer { bytes.baseAddress! }
}

/// A stage running on its own thread: it takes items from `input` and hands results on. The
/// first error it throws is kept for the caller (`join`), and it closes both of its channels on
/// the way out so the neighbouring stages stop too.
final class StageThread: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var error: (any Error)?

    init(name: String, closing channels: [() -> Void], _ body: @escaping () throws -> Void) {
        // The body owns its decoder or encoder outright; nothing else touches them meanwhile.
        nonisolated(unsafe) let body = body, channels = channels
        let thread = Thread { [self] in
            do { try body() } catch { self.error = error }
            channels.forEach { $0() }
            done.signal()
        }
        thread.stackSize = ToolCall.stackSize
        thread.name = "glitchbox.\(name)"
        thread.start()
    }

    /// Waits for the stage to end; rethrows its error.
    func join() throws {
        done.wait()
        if let error { throw error }
    }
}

enum FramePipeline {
    /// Thrown by `transform` or `finish` to end the run early as a success: no more input is
    /// read, and what was already emitted is still consumed.
    struct Stop: Error {}

    /// Runs `produce` (fills a buffer with the next frame; false at the end) on one thread,
    /// `transform` on the calling thread, and `consume` on a third thread, with `inDepth` and
    /// `outDepth` buffers circulating. `transform` may call `emit` any number of times per
    /// input (retiming); each call fills one out buffer and hands it to `consume`. It returns
    /// the in buffer it is done with (usually the one it got), or nil to keep it; a step that
    /// keeps k buffers needs `inDepth` ≥ k + 2 for decoding to overlap. `finish` runs after the
    /// last input.
    ///
    /// The first error from any stage stops all of them and is rethrown; errors from the
    /// calling thread take precedence, then the producer's, then the consumer's.
    static func run(inBytes: Int, outBytes: Int, inDepth: Int = 2, outDepth: Int = 2, name: String,
                    produce: @escaping (FrameBuffer) throws -> Bool,
                    transform: (FrameBuffer, _ emit: (_ fill: (FrameBuffer) throws -> Void) throws -> Void) throws -> FrameBuffer?,
                    finish: (_ emit: (_ fill: (FrameBuffer) throws -> Void) throws -> Void) throws -> Void = { _ in },
                    consume: @escaping (FrameBuffer) throws -> Void) throws {
        let freeIn = Channel((0..<inDepth).map { _ in FrameBuffer(byteCount: inBytes) })
        let fullIn = Channel<FrameBuffer>()
        let freeOut = Channel((0..<outDepth).map { _ in FrameBuffer(byteCount: outBytes) })
        let fullOut = Channel<FrameBuffer>()

        let producer = StageThread(name: "\(name).decode", closing: [fullIn.close, freeIn.close]) {
            while let b = freeIn.receive() {
                guard try produce(b) else { return }
                guard fullIn.send(b) else { return }
            }
        }
        let consumer = StageThread(name: "\(name).encode", closing: [fullOut.close, freeOut.close]) {
            while let b = fullOut.receive() {
                try consume(b)
                guard freeOut.send(b) else { return }
            }
        }

        /// Hands one filled out buffer to the consumer; throws if the consumer is gone.
        struct ConsumerGone: Error {}
        func emit(_ fill: (FrameBuffer) throws -> Void) throws {
            guard let out = freeOut.receive() else { throw ConsumerGone() }
            try fill(out)
            guard fullOut.send(out) else { throw ConsumerGone() }
        }

        var mainError: (any Error)?
        do {
            while let b = fullIn.receive() {
                if let done = try transform(b, emit), !freeIn.send(done) { break }
            }
            try finish(emit)
        } catch is ConsumerGone {
        } catch is Stop {
        } catch {
            mainError = error
        }
        // Stop the producer (if still running) and let the consumer drain what was queued.
        freeIn.close()
        fullIn.close()
        fullOut.close()
        var producerError: (any Error)?, consumerError: (any Error)?
        do { try producer.join() } catch { producerError = error }
        do { try consumer.join() } catch { consumerError = error }
        if let e = mainError ?? producerError ?? consumerError { throw e }
    }
}
