import Foundation
import Logging

/// Wires up the cross-cutting infrastructure a PulsarTrace process needs and
/// emits the `app_started` / `app_stopped` event pair (§8.13).
///
/// Both `pulsartrace-engine` and `pulsartrace` use this so the lifecycle event
/// pair and logging setup are identical regardless of entry point. `start()`
/// bootstraps logging + the events writer and emits `app_started`; `stop()`
/// emits `app_stopped` and flushes both logs.
public final class AppLifecycle: @unchecked Sendable {
    /// The shared events writer for the process; subsystems emit through it.
    public let events: EventWriter
    private let rotator: LogRotator
    private let logger: Logger

    private init(events: EventWriter, rotator: LogRotator) {
        self.events = events
        self.rotator = rotator
        self.logger = Logger(label: LogSubsystem.app)
    }

    /// Bootstrap logging + events, prune expired files, emit `app_started`.
    public static func start(paths: AppPaths = .standard) async -> AppLifecycle {
        let rotator = await LogSystem.bootstrap(paths: paths)
        let events = EventWriter(directory: paths.eventsDirectory)
        await events.bootstrap()

        let lifecycle = AppLifecycle(events: events, rotator: rotator)
        lifecycle.logger.notice(
            "PulsarTrace started; version=\(HostInfo.appVersion), macos=\(HostInfo.macosVersion)")
        _ = try? await events.append(
            AppStartedEvent(version: HostInfo.appVersion, macosVersion: HostInfo.macosVersion))
        return lifecycle
    }

    /// Emit `app_stopped`, flush the events log and the operational log.
    public func stop() async {
        logger.notice("PulsarTrace stopping")
        _ = try? await events.append(
            AppStoppedEvent(version: HostInfo.appVersion, macosVersion: HostInfo.macosVersion))
        await events.flush()
        await LogSystem.shutdown()
    }
}
