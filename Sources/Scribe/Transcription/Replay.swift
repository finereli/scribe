import Foundation
import AVFoundation

/// `Scribe --replay <call folder> [speed]` runs a recorded call's two tracks
/// back through turn cutting and recognition, as if live, and writes the
/// turns to replay.json in that folder. For checking recognition changes
/// against real calls; the saved session is left alone.
enum Replay {
    static func run(folder: URL, speed: Double) -> Never {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try? decoder.decode(
            Session.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        let language = session?.languageCode ?? "en-US"
        let recognition = RecognitionQueue(languageCode: language)
        var turns: [UUID: Turn] = [:]
        var lastUpdate = Date()
        recognition.onUpdate = { turns[$0.id] = $0; lastUpdate = Date() }

        let sides: [(Speaker, String, TimeInterval)] = [
            (.me, Session.micFile, session?.micOffset ?? 0),
            (.them, Session.systemFile, session?.systemOffset ?? 0),
        ]
        let tracks = sides.compactMap { speaker, name, offset -> (TurnRecognizer, AVAudioFile, TimeInterval)? in
            guard let file = try? AVAudioFile(forReading: folder.appendingPathComponent(name)) else { return nil }
            return (TurnRecognizer(speaker: speaker, recognition: recognition), file, offset)
        }
        print("replaying \(folder.lastPathComponent) (\(language)) at \(speed)x")

        var fed = false
        DispatchQueue.global().async {
            let chunk: AVAudioFrameCount = 1_600   // 0.1 s
            var t: TimeInterval = 0
            while tracks.contains(where: { $0.1.framePosition < $0.1.length }) {
                for (recognizer, file, offset) in tracks where file.framePosition < file.length {
                    let at = offset + Double(file.framePosition) / file.processingFormat.sampleRate
                    guard at <= t + 0.1,
                          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                          (try? file.read(into: buffer, frameCount: chunk)) != nil else { continue }
                    recognizer.feed(buffer, at: at, db: decibels(buffer))
                }
                t += 0.1
                Thread.sleep(forTimeInterval: 0.1 / speed)
            }
            tracks.forEach { $0.0.finishTurn() }
            fed = true
        }

        // Done once the audio is in and nothing has changed for a while.
        while !(fed && Date().timeIntervalSince(lastUpdate) > 20) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        let sorted = turns.values.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
        let out = folder.appendingPathComponent("replay.json")
        try? JSONEncoder().encode(sorted).write(to: out)
        for speaker in [Speaker.me, .them] {
            let words = sorted.filter { $0.speaker == speaker }.reduce(0) { $0 + $1.text.split(separator: " ").count }
            print("\(speaker.label): \(words) words")
        }
        print("wrote \(out.path)")
        exit(0)
    }

    private static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        return 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
    }
}
