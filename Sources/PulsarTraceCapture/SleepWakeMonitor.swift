import Foundation
import IOKit
import IOKit.pwr_mgt

/// Watches for system sleep and wake so `DeviceCaptureSource` can pause and
/// resume capture across a sleep, annotating the gap (R7).
///
/// Backed by `IORegisterForSystemPower` delivered onto a dispatch queue
/// (`IONotificationPortSetDispatchQueue`) — no run loop is required, so the
/// `pulsartrace-capture` daemon can monitor power events while it simply
/// `await`s a termination signal.
final class SleepWakeMonitor: @unchecked Sendable {

    // `IOMessage.h` defines these as the `iokit_common_msg(...)` macro, which
    // Swift cannot import. The numeric values are stable, documented IOKit
    // constants.
    private static let messageCanSystemSleep: UInt32 = 0xE000_0270
    private static let messageSystemWillSleep: UInt32 = 0xE000_0280
    private static let messageSystemHasPoweredOn: UInt32 = 0xE000_0300

    /// Called just before the system sleeps. The monitor acknowledges the
    /// sleep itself afterwards.
    var onSleep: (@Sendable () -> Void)?
    /// Called after the system wakes.
    var onWake: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.pulsartrace.capture.power")
    private var connection: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    /// Begin monitoring. A failure to register is non-fatal — capture simply
    /// will not pause/resume across sleep.
    func start() {
        var port: IONotificationPortRef?
        var object: io_object_t = 0
        let context = Unmanaged.passUnretained(self).toOpaque()

        let connection = IORegisterForSystemPower(
            context, &port,
            { context, _, messageType, messageArgument in
                guard let context else { return }
                let monitor = Unmanaged<SleepWakeMonitor>
                    .fromOpaque(context).takeUnretainedValue()
                monitor.handle(messageType: messageType, argument: messageArgument)
            },
            &object)

        guard connection != 0, let port else { return }
        self.connection = connection
        self.notificationPort = port
        self.notifier = object
        IONotificationPortSetDispatchQueue(port, queue)
    }

    /// Stop monitoring and release the IOKit resources.
    ///
    /// Detaches the notification port from its dispatch queue first so no new
    /// callback is scheduled, then drains any callback already in flight
    /// (`queue.sync`) before releasing the `connection` that a running
    /// `handle()` would touch via `IOAllowPowerChange`. Must not be called
    /// from `queue` itself.
    func stop() {
        if let port = notificationPort {
            IONotificationPortSetDispatchQueue(port, nil)
        }
        queue.sync {}
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.messageCanSystemSleep:
            // No objection to idle sleep — acknowledge so it proceeds.
            IOAllowPowerChange(connection, Int(bitPattern: argument))
        case Self.messageSystemWillSleep:
            onSleep?()
            // Must acknowledge or the system delays sleep until timeout.
            IOAllowPowerChange(connection, Int(bitPattern: argument))
        case Self.messageSystemHasPoweredOn:
            onWake?()
        default:
            break
        }
    }
}
