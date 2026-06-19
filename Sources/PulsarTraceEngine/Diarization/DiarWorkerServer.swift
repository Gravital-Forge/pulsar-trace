import Foundation
import Logging

/// The diarizer worker's run loop (D43). Stateless: sends `hello` once, then
/// for each request frame runs the raw diarizer and replies with `result`.
/// A hung `diarizeRawWindow` simply blocks this loop forever — by design: the
/// engine supervisor enforces the deadline and `SIGKILL`s this process, which
/// is the only thing that frees a wedged ANE call.
public struct DiarWorkerServer: Sendable {
    private let connection: any DiarWorkerConnecting
    private let rawDiarizer: any RawWindowDiarizing
    private let logger: Logger

    public init(
        connection: any DiarWorkerConnecting,
        rawDiarizer: any RawWindowDiarizing,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.connection = connection
        self.rawDiarizer = rawDiarizer
        self.logger = logger
    }

    public func run() async {
        let revision = await rawDiarizer.modelRevision()
        do {
            try connection.send(try DiarWorkerProtocol.encodeMessage(.hello(modelRevision: revision)))
        } catch {
            logger.error("diar worker: failed to send hello: \(error)")
            return
        }
        for await body in connection.inboundBodies {
            let request: (requestId: UInt64, samples: [Float])
            do {
                request = try DiarWorkerProtocol.decodeRequest(body)
            } catch {
                logger.error("diar worker: bad request frame: \(error)")
                continue
            }
            let window = await rawDiarizer.diarizeRawWindow(samples: request.samples) ?? .empty
            do {
                try connection.send(try DiarWorkerProtocol.encodeMessage(
                    .result(requestId: request.requestId, window: window)))
            } catch {
                logger.error("diar worker: failed to send result: \(error)")
                return
            }
        }
    }
}
