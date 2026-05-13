import Foundation
import os.log

/// Centralised `os_log` loggers for the app. Subsystem is fixed so users can
/// filter Console.app / `log show` output with a single predicate:
///
///     log show --predicate 'subsystem == "com.apoorvgarg.ductor-companion"' --info --last 5m
///
/// Every helper takes an `agent` slug so the heartbeat/screenshot/bridge
/// traces stay greppable even when the user has multiple sub-agents
/// configured. When no agent is selected (e.g. wizard not finished yet)
/// `unknownAgent` is used.
enum Trace {
    static let subsystem = "com.apoorvgarg.ductor-companion"
    static let unknownAgent = "(no-agent)"

    static let heartbeat = OSLog(subsystem: subsystem, category: "heartbeat")
    static let screenshot = OSLog(subsystem: subsystem, category: "screenshot")
    static let bridge = OSLog(subsystem: subsystem, category: "bridge")
    static let bridgePy = OSLog(subsystem: subsystem, category: "bridge-py")
    static let hotkey = OSLog(subsystem: subsystem, category: "hotkey")

    static func log(_ log: OSLog,
                    _ type: OSLogType = .info,
                    agent: String,
                    _ message: String) {
        // os_log expects a static format string in Swift. Compose the agent
        // tag in the message itself; the format string remains constant.
        os_log("[%{public}@] %{public}@", log: log, type: type, agent, message)
    }
}
