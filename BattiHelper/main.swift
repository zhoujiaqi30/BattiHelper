import Darwin

// BattiHelper daemon entry point.
//
// Responsibilities:
// - Run a safety precheck against SMC state before starting the socket server.
// - Start the Unix domain socket server and route requests to SMC operations.
// - Best-effort restore system defaults when the process exits.
//
// Transport:
// - The daemon listens on a Unix domain socket at `socketPath`.
// - Each request/response is a single JSON object terminated by '\n'.

private let socketPath = "/tmp/batti/helper/battihelper.sock"

private func runPrecheckOrExit() {
    // Safety precheck:
    // - Reset SMC-related keys to system defaults.
    // - Verify the current power status matches system defaults.
    //
    // If this fails, we do not continue to run the server, because the last run
    // may have left the machine in a non-default state.
    Log.info("smc_precheck_start", scope: "main")
    let resetOk = resetDefault()
    Log.info("smc_precheck_reset_ok=\(resetOk ? "1" : "0")", scope: "main")
    let statusAfterReset = currentPowerStatus()
    Log.info("smc_precheck_status_after_reset=\(statusAfterReset.rawValue)", scope: "main")
    if !resetOk || statusAfterReset != .systemDefault {
        Log.error("smc_precheck_failed", scope: "main")
        exit(1)
    }
    Log.info("smc_precheck_ok", scope: "main")
}

runPrecheckOrExit()

// Always attempt to restore system defaults when the process exits.
defer {
    _ = resetDefault()
}

do {
    try DaemonService.run(socketPath: socketPath) { req in
        switch req.event {
        case .ping:
            return DaemonResponse(id: req.id, ok: true, event: req.event, result: ["pong": "1"], error: nil)
        case .charge:
            // Force charging behavior via SMC writes.
            let ok = charge()
            return DaemonResponse(id: req.id, ok: ok, event: req.event, result: nil, error: ok ? nil : "smc_write_failed")
        case .discharge:
            // Force discharging behavior via SMC writes.
            let ok = discharge()
            return DaemonResponse(id: req.id, ok: ok, event: req.event, result: nil, error: ok ? nil : "smc_write_failed")
        case .resetDefault:
            // Restore system default behavior via SMC writes.
            let ok = resetDefault()
            return DaemonResponse(id: req.id, ok: ok, event: req.event, result: nil, error: ok ? nil : "smc_write_failed")
        case .status:
            // Read current SMC-derived power status.
            let status = currentPowerStatus()
            return DaemonResponse(id: req.id, ok: true, event: req.event, result: ["status": status.rawValue], error: nil)
        case .stop:
            // Request the daemon to stop. The server will exit its run loop
            // after sending this response.
            return DaemonResponse(id: req.id, ok: true, event: req.event, result: ["stopping": "1"], error: nil)
        }
    }
} catch {
    // Keep stdout clean for IPC; use stderr for daemon lifecycle errors.
    Log.error("failed_to_start", scope: "main")
    exit(1)
}
