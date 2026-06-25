import Foundation

/// The `control.sock` JSON-line control protocol (§17).
///
/// `control.sock` carries control messages between the menubar app / CLI and
/// `pulsartrace-engine`: start, stop, status, progress. It is line-oriented —
/// one JSON object per line, UTF-8, newline-terminated — so it can be driven
/// from a shell or read incrementally without a length framing layer.
///
/// This file defines the message definitions and codec only; the engine does
/// not yet listen on a real control socket (that lands with streaming / the
/// menubar app). Defining the contract here keeps later changes additive.
public enum ControlProtocol {

    /// A message sent *to* the engine (app/CLI → engine).
    public enum Command: Codable, Equatable, Sendable {
        /// Begin a recording session.
        case start(StartRequest)
        /// Stop the current session.
        case stop
        /// Request a one-shot status snapshot.
        case status

        private enum Kind: String, Codable {
            case start, stop, status
        }
        private enum CodingKeys: String, CodingKey {
            case command, payload
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Kind.self, forKey: .command) {
            case .start: self = .start(try c.decode(StartRequest.self, forKey: .payload))
            case .stop: self = .stop
            case .status: self = .status
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .start(let req):
                try c.encode(Kind.start, forKey: .command)
                try c.encode(req, forKey: .payload)
            case .stop:
                try c.encode(Kind.stop, forKey: .command)
            case .status:
                try c.encode(Kind.status, forKey: .command)
            }
        }
    }

    /// Payload for `start`.
    public struct StartRequest: Codable, Equatable, Sendable {
        /// Output directory basename (never a full path — privacy, PT-R84).
        public let outputDirBasename: String
        /// Whether to capture system audio.
        public let systemAudioEnabled: Bool
        /// Live-pass model name.
        public let modelLive: String

        public init(outputDirBasename: String, systemAudioEnabled: Bool, modelLive: String) {
            self.outputDirBasename = outputDirBasename
            self.systemAudioEnabled = systemAudioEnabled
            self.modelLive = modelLive
        }

        private enum CodingKeys: String, CodingKey {
            case outputDirBasename = "output_dir_basename"
            case systemAudioEnabled = "system_audio_enabled"
            case modelLive = "model_live"
        }
    }

    /// A message sent *from* the engine (engine → app/CLI).
    public enum Event: Codable, Equatable, Sendable {
        /// Acknowledgement of a command.
        case ack(command: String)
        /// Periodic progress update (long-running operations, §17 conventions).
        case progress(Progress)
        /// Engine status snapshot (reply to `status`).
        case status(Status)
        /// An error condition.
        case error(message: String)

        private enum Kind: String, Codable {
            case ack, progress, status, error
        }
        private enum CodingKeys: String, CodingKey {
            case event, command, payload, message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Kind.self, forKey: .event) {
            case .ack:
                self = .ack(command: try c.decode(String.self, forKey: .command))
            case .progress:
                self = .progress(try c.decode(Progress.self, forKey: .payload))
            case .status:
                self = .status(try c.decode(Status.self, forKey: .payload))
            case .error:
                self = .error(message: try c.decode(String.self, forKey: .message))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .ack(let command):
                try c.encode(Kind.ack, forKey: .event)
                try c.encode(command, forKey: .command)
            case .progress(let p):
                try c.encode(Kind.progress, forKey: .event)
                try c.encode(p, forKey: .payload)
            case .status(let s):
                try c.encode(Kind.status, forKey: .event)
                try c.encode(s, forKey: .payload)
            case .error(let message):
                try c.encode(Kind.error, forKey: .event)
                try c.encode(message, forKey: .message)
            }
        }
    }

    /// Progress payload — a fraction in [0, 1] plus a stage label.
    public struct Progress: Codable, Equatable, Sendable {
        public let stage: String
        public let fraction: Double

        public init(stage: String, fraction: Double) {
            self.stage = stage
            self.fraction = fraction
        }
    }

    /// Status payload — a one-shot snapshot of engine state.
    public struct Status: Codable, Equatable, Sendable {
        public let state: String
        public let framesProcessed: Int

        public init(state: String, framesProcessed: Int) {
            self.state = state
            self.framesProcessed = framesProcessed
        }

        private enum CodingKeys: String, CodingKey {
            case state
            case framesProcessed = "frames_processed"
        }
    }

    // MARK: - Codec

    /// Encode a `Command` as a single newline-terminated JSON line.
    public static func encode(_ command: Command) throws -> String {
        try line(from: command)
    }

    /// Encode an `Event` as a single newline-terminated JSON line.
    public static func encode(_ event: Event) throws -> String {
        try line(from: event)
    }

    /// Decode a single JSON line into a `Command`.
    public static func decodeCommand(_ line: String) throws -> Command {
        try JSONDecoder().decode(Command.self, from: Data(line.utf8))
    }

    /// Decode a single JSON line into an `Event`.
    public static func decodeEvent(_ line: String) throws -> Event {
        try JSONDecoder().decode(Event.self, from: Data(line.utf8))
    }

    private static func line<T: Encodable>(from value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
