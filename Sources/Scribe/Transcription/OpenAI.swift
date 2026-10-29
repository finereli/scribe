import Foundation

/// What can stand between a turn and its text. Shown as a banner.
enum TranscriptionProblem: Equatable {
    case noKey
    case rejected(String)
    case noCredit
    case offline
}

/// The user's own OpenAI key, kept in ~/.config/scribe/openai-key: a plain
/// file rather than the Keychain so the same setup works on Linux. Not read
/// from OPENAI_API_KEY, which a terminal launch would quietly inherit.
enum APIKey {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/scribe/openai-key")

    static var current: String? {
        let key = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static func save(_ key: String) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(key.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    /// "sk-…x7Qa", enough to tell keys apart without showing one.
    static func masked(_ key: String) -> String {
        "\(key.prefix(3))…\(key.suffix(4))"
    }
}

/// One call to OpenAI's transcription endpoint, with the answer sorted into
/// what the caller should do about it.
enum OpenAI {
    static let model = "gpt-transcribe"
    static let billingURL = URL(string: "https://platform.openai.com/settings/organization/billing")!
    static let keysURL = URL(string: "https://platform.openai.com/api-keys")!

    enum Outcome {
        case text(String)
        /// The key is wrong, revoked, or not allowed to transcribe.
        case rejected(String)
        /// The account has run out of credit. OpenAI says so with a 429,
        /// the same status as a rate limit, so it's told apart by its code.
        case noCredit
        /// Rate limited or a server error: try again shortly.
        case busy(String)
        /// Couldn't reach OpenAI at all.
        case offline(String)
        /// OpenAI refused this particular request; trying again won't help.
        case failed(String)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func transcribe(wav: Data, prompt: String, key: String) async -> Outcome {
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
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"turn.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .offline(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let (message, code) = errorDetails(data)
        switch status {
        case 200:
            return .text(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        case 401:
            return .rejected("OpenAI didn't accept this key. It may have been mistyped, deleted or revoked.")
        case 403:
            return .rejected("This key isn't allowed to transcribe audio. \(message)")
        case 429 where code == "insufficient_quota":
            return .noCredit
        case 429, 500...599:
            return .busy("\(status) \(message)")
        default:
            return .failed("\(status) \(message)")
        }
    }

    /// Checks a key by transcribing half a second of silence, which costs a
    /// tiny fraction of a cent. Listing models would be free, but a key
    /// restricted to audio can't list them and would look broken.
    static func check(_ key: String) async -> Outcome {
        await transcribe(wav: WAV.encode([Float](repeating: 0, count: 8_000)), prompt: "", key: key)
    }

    private static func errorDetails(_ data: Data) -> (message: String, code: String?) {
        struct Body: Decodable {
            struct E: Decodable { let message: String; let code: String? }
            let error: E
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            return (String(decoding: data.prefix(200), as: UTF8.self), nil)
        }
        return (body.error.message, body.error.code)
    }
}

enum WAV {
    static let sampleRate = 16_000.0

    /// 16 kHz mono 16-bit: 32 KB a second, so a 30-second turn is about 1 MB.
    static func encode(_ samples: [Float]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.reserveCapacity(44 + Int(bytes))
        data.append("RIFF"); put(36 + bytes); data.append("WAVE")
        data.append("fmt "); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append("data"); put(bytes)
        for s in samples { put(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}

extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
