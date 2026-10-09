import Foundation
import AVFoundation

/// One side of the call: converts whatever the device delivers to 16 kHz
/// mono, writes it to an .m4a, meters it, and hands it to the recognizer.
///
/// 16 kHz mono is what speech models (Apple's and Whisper) want, and it keeps
/// a one-hour track around 15 MB.
final class SpeakerStream {
    let recognizer: TurnRecognizer
    /// Called on main with a 0...1 level.
    var onLevel: ((Float) -> Void)?

    private let queue: DispatchQueue
    private let fileURL: URL
    private let callStart: Date
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!

    // Capture-thread state.
    private var converter: AVAudioConverter?
    // Queue state.
    private var file: AVAudioFile?
    private var framesWritten: Int64 = 0
    private var lastLevelSent = Date.distantPast
    private(set) var startOffset: TimeInterval?

    /// When the device last delivered audio. Read by the watchdog on main.
    var lastBufferAt: Date {
        get { lock.lock(); defer { lock.unlock() }; return _lastBufferAt }
        set { lock.lock(); _lastBufferAt = newValue; lock.unlock() }
    }
    private var _lastBufferAt = Date()
    private let lock = NSLock()

    init(recognizer: TurnRecognizer, fileURL: URL, callStart: Date) {
        self.recognizer = recognizer
        self.fileURL = fileURL
        self.callStart = callStart
        self.queue = DispatchQueue(label: "com.finereli.scribe.\(recognizer.speaker.rawValue)",
                                   qos: .userInitiated)
    }

    /// Called on the capture thread. The buffer may not outlive this call,
    /// so conversion happens here and the rest goes to the queue.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }

        let arrived = Date()
        lastBufferAt = arrived
        queue.async { self.process(out, arrived: arrived) }
    }

    private func process(_ buffer: AVAudioPCMBuffer, arrived: Date) {
        if startOffset == nil {
            startOffset = max(0, arrived.timeIntervalSince(callStart)
                                 - Double(buffer.frameLength) / target.sampleRate)
            Log.write("\(recognizer.speaker.label): first audio at \(startOffset!)s")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: target.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            do {
                file = try AVAudioFile(forWriting: fileURL, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                NSLog("Scribe: couldn't open \(fileURL.lastPathComponent): \(error)")
            }
        }
        // If the device stopped and was restarted, fill the hole with silence
        // so a second in the file stays a second of the call.
        let bufferDuration = Double(buffer.frameLength) / target.sampleRate
        let expected = arrived.timeIntervalSince(callStart) - bufferDuration
        let gap = expected - ((startOffset ?? 0) + Double(framesWritten) / target.sampleRate)
        if gap > 0.5 {
            Log.write("\(recognizer.speaker.label): filling a \(String(format: "%.1f", gap))s gap")
            writeSilence(seconds: gap)
        }

        try? file?.write(from: buffer)

        let t = (startOffset ?? 0) + Double(framesWritten) / target.sampleRate
        framesWritten += Int64(buffer.frameLength)

        let db = Self.decibels(buffer)
        recognizer.feed(buffer, at: t, db: db)

        // Meter ~20 times a second.
        if arrived.timeIntervalSince(lastLevelSent) > 0.05 {
            lastLevelSent = arrived
            let level = max(0, min(1, (db + 60) / 60))
            DispatchQueue.main.async { self.onLevel?(level) }
        }
    }

    private func writeSilence(seconds: TimeInterval) {
        var remaining = AVAudioFrameCount(seconds * target.sampleRate)
        let chunk: AVAudioFrameCount = 16_000
        guard let zeros = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk) else { return }
        while remaining > 0 {
            let n = min(chunk, remaining)
            zeros.frameLength = n
            memset(zeros.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
            try? file?.write(from: zeros)
            framesWritten += Int64(n)
            remaining -= n
        }
        recognizer.finishTurn()
    }

    /// Close the file and the turn in progress. Calls back on main once the
    /// last buffer has been written.
    func finish(completion: @escaping () -> Void) {
        queue.async {
            self.recognizer.finishTurn()
            self.file = nil   // finalizes the .m4a
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        return 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
    }
}
