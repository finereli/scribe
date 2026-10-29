import Foundation
import AVFoundation

/// Transcribes turns with OpenAI's gpt-transcribe, one upload per turn.
///
/// A turn's audio is collected while the person talks. When the turn ends it
/// goes up as a small WAV and its text comes back a second or two later.
/// Turns upload in parallel and land in any order; each carries its own start
/// time, so the transcript sorts itself. The Mac does nothing but record.
final class RecognitionQueue {
    /// Called on the main queue for every partial and final result.
    var onUpdate: ((Turn) -> Void)?
    /// Called on the main queue for errors worth showing.
    var onError: ((String) -> Void)?

    static let model = "gpt-transcribe"
    private static let sampleRate = 16_000.0

    private final class Job {
        let id = UUID()
        let speaker: Speaker
        let start: TimeInterval
        var language = ""
        var samples: [Float] = []

        init(speaker: Speaker, start: TimeInterval) {
            self.speaker = speaker
            self.start = start
        }
    }

    // Touched only on `queue`.
    private let queue = DispatchQueue(label: "com.finereli.scribe.recognition")
    private var jobs: [UUID: Job] = [:]
    private var language: String
    /// The last few words transcribed, passed as the prompt so a turn that
    /// starts mid-thought has context.
    private var context = ""
    private var cancelled = false
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    init(languageCode: String) {
        language = Self.isoCode(languageCode)
    }

    // MARK: - Turns (any thread)

    func begin(speaker: Speaker, at start: TimeInterval) -> UUID {
        let job = Job(speaker: speaker, start: start)
        queue.async {
            job.language = self.language
            self.jobs[job.id] = job
            // Show that this speaker is talking until the text arrives.
            self.emit(Turn(id: job.id, speaker: speaker, start: start, end: start, text: "…", isFinal: false))
        }
        return job.id
    }

    func append(_ buffer: AVAudioPCMBuffer, to id: UUID) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        queue.async { self.jobs[id]?.samples += samples }
    }

    func end(_ id: UUID) {
        queue.async {
            guard let job = self.jobs.removeValue(forKey: id) else { return }
            self.upload(job, prompt: self.context)
        }
    }

    /// Turns already running finish in the old language; turns that start
    /// after this use the new one.
    func setLanguage(_ languageCode: String) {
        queue.async {
            self.language = Self.isoCode(languageCode)
            Log.write("recognizer: switched to \(languageCode)")
        }
    }

    func cancelAll() {
        queue.async {
            self.cancelled = true
            self.jobs = [:]
        }
    }

    // MARK: - Uploading

    private func upload(_ job: Job, prompt: String, attempt: Int = 1) {
        let duration = Double(job.samples.count) / Self.sampleRate
        var turn = Turn(id: job.id, speaker: job.speaker, start: job.start,
                        end: job.start + duration, text: "", isFinal: true)
        guard let key = APIKey.openAI else {
            DispatchQueue.main.async { self.onError?(APIKey.missingMessage) }
            emit(turn)
            return
        }
        let request = Self.request(wav: Self.wav(job.samples), language: job.language,
                                   prompt: prompt, key: key)
        let sent = Date()
        session.dataTask(with: request) { data, response, error in
            self.queue.async {
                guard !self.cancelled else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil, status == 200, let data {
                    turn.text = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !turn.text.isEmpty {
                        self.context = String((self.context + " " + turn.text).suffix(200))
                    }
                    Log.write(String(format: "recognizer %@: %.1fs of audio in %.1fs",
                                     job.speaker.label, duration, Date().timeIntervalSince(sent)))
                    self.emit(turn)
                    return
                }
                let reason = error?.localizedDescription
                    ?? data.map { Self.errorMessage($0) } ?? "HTTP \(status)"
                Log.write("recognizer \(job.speaker.label): attempt \(attempt) failed: \(reason)")
                // Network trouble, rate limits and server errors are worth
                // another try; a bad key or request isn't.
                let retryable = error != nil || status == 429 || status >= 500
                if retryable && attempt < 4 {
                    self.queue.asyncAfter(deadline: .now() + Double(attempt * attempt)) {
                        self.upload(job, prompt: prompt, attempt: attempt + 1)
                    }
                } else {
                    DispatchQueue.main.async { self.onError?("\(job.speaker.label): couldn't transcribe (\(reason))") }
                    self.emit(turn)
                }
            }
        }.resume()
    }

    private static func request(wav: Data, language: String, prompt: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        let boundary = "scribe-\(UUID().uuidString)"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model)
        field("response_format", "text")
        if !language.isEmpty { field("language", language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"turn.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    /// 16 kHz mono 16-bit WAV: 32 KB a second, so a 30-second turn is about 1 MB.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append("RIFF"); put(36 + bytes); data.append("WAVE")
        data.append("fmt "); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append("data"); put(bytes)
        data.reserveCapacity(data.count + Int(bytes))
        for s in samples { put(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }

    private static func errorMessage(_ data: Data) -> String {
        struct Body: Decodable { struct E: Decodable { let message: String }; let error: E }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error.message
            ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    /// "he-IL" to "he", the form the API takes.
    private static func isoCode(_ languageCode: String) -> String {
        String(languageCode.prefix { $0 != "-" && $0 != "_" })
    }

    private func emit(_ turn: Turn) {
        DispatchQueue.main.async { self.onUpdate?(turn) }
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}

/// The OpenAI key, from OPENAI_API_KEY or ~/.config/scribe/openai-key.
/// A plain file rather than the Keychain so the same setup works on Linux.
enum APIKey {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/scribe/openai-key")

    static var openAI: String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
        let key = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static let missingMessage = "No OpenAI API key. Put it in ~/.config/scribe/openai-key."
}
