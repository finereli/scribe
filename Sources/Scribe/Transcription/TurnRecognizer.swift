import Foundation
import AVFoundation

/// Cuts one speaker's audio into turns and hands them to the shared
/// recognition queue.
///
/// A turn opens when this speaker starts talking and closes after a pause.
/// That keeps every request well under Apple's one-minute server limit
/// (Hebrew and Russian aren't on-device), gives each turn a real start time
/// for interleaving the two speakers, and keeps the recognizer idle during
/// silence.
final class TurnRecognizer {
    let speaker: Speaker
    private let recognition: RecognitionQueue
    private static let sampleRate: Double = 16_000

    // Touched only on the owning stream's queue.
    private var turn: UUID?
    private var turnStart: TimeInterval = 0
    private var lastVoice: TimeInterval = 0
    private var preroll: [(buffer: AVAudioPCMBuffer, at: TimeInterval)] = []
    private var floorDB: Float = -60

    // Pause that ends a turn, and the limits that force one to end.
    private let pauseToEnd: TimeInterval = 1.0
    private let softLimit: TimeInterval = 40
    private let hardLimit: TimeInterval = 55
    private let prerollLength: TimeInterval = 0.4

    init(speaker: Speaker, recognition: RecognitionQueue) {
        self.speaker = speaker
        self.recognition = recognition
    }

    /// Feed one 16 kHz mono buffer that starts `at` seconds into the call.
    func feed(_ buffer: AVAudioPCMBuffer, at t: TimeInterval, db: Float) {
        let length = Double(buffer.frameLength) / Self.sampleRate
        let end = t + length

        // Track the noise floor: drop to quiet instantly, rise slowly, so a
        // noisy room doesn't count as speech and a quiet one stays sensitive.
        floorDB = db < floorDB ? db : min(floorDB + Float(length) * 0.5, -30)
        let voiced = db > max(floorDB + 10, -55)

        guard let turn else {
            preroll.append((buffer, t))
            while let first = preroll.first, end - first.at > prerollLength { preroll.removeFirst() }
            guard voiced else { return }
            turnStart = preroll.first?.at ?? t
            let id = recognition.begin(speaker: speaker, at: turnStart)
            preroll.forEach { recognition.append($0.buffer, to: id) }
            preroll = []
            self.turn = id
            lastVoice = end
            return
        }

        recognition.append(buffer, to: turn)
        if voiced { lastVoice = end }
        let silence = end - lastVoice
        let elapsed = end - turnStart
        if silence > pauseToEnd || (elapsed > softLimit && silence > 0.3) || elapsed > hardLimit {
            finishTurn()
        }
    }

    /// Close the turn in progress; its final result still arrives.
    func finishTurn() {
        guard let turn else { return }
        recognition.end(turn)
        self.turn = nil
    }
}
