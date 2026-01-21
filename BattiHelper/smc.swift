import Foundation
import IOKit
import Darwin

// AppleSMC access helpers.
//
// This file provides a small, synchronous wrapper around the AppleSMC user client
// (via IOKit) to:
// - Write specific SMC keys to force charging/discharging behavior.
// - Restore those keys back to system defaults.
// - Infer a coarse power status by reading those same keys back.
//
// Notes:
// - Every public API call opens and closes the SMC connection.
// - On machines/environments where AppleSMC is unavailable or access is denied,
//   writes return false and reads return `.unknown`.
// - "Atomic" writes in this file mean: if any step of a multi-key update fails,
//   we attempt to roll back already-written keys to the values observed right
//   before the update started. This is best-effort; hardware/SMC behavior is not
//   transactional, and rollbacks themselves can fail.

public enum PowerStatus: String {
    // SMC keys indicate a charging configuration.
    case charging
    // SMC keys indicate a discharging configuration.
    case discharging
    // SMC keys match the default (system-managed) configuration.
    case systemDefault
    // Status could not be determined.
    case unknown
}

private enum MagSafeLED: UInt8 {
    case system = 0x00
    case off = 0x01
    case green = 0x03
    case orange = 0x04
}

private enum BatterySMCKey {
    // Key controlling MagSafe LED behavior.
    static let magsafeLedKeyACLC = "ACLC"
    
    // Keys used by this project to control/observe charging behavior.
    // The exact hardware semantics are platform-dependent; within this codebase
    // we treat them as a 4-byte "mode/control" tuple.
    static let chargeModeKeyCH0I = "CH0I"
    static let chargeModeKeyCH0J = "CH0J"
    static let chargeControlKeyCH0B = "CH0B"
    static let chargeControlKeyCH0C = "CH0C"
}

private enum BatterySMCValue {
    // Value used by the daemon as "system-managed/default".
    static let systemDefault: UInt8 = 0x00
    
    // Values used by the daemon as "forced discharge" configuration.
    static let dischargeA: UInt8 = 0x01
    static let dischargeC: UInt8 = 0x02
}

private struct BatterySMCConfig {
    // Target values for the CH0* keys and LED to apply as a unit.
    var ch0i: UInt8
    var ch0j: UInt8
    var ch0b: UInt8
    var ch0c: UInt8
    var led: MagSafeLED
}

private let chargeConfig = BatterySMCConfig(
    ch0i: BatterySMCValue.systemDefault,
    ch0j: BatterySMCValue.systemDefault,
    ch0b: BatterySMCValue.systemDefault,
    ch0c: BatterySMCValue.systemDefault,
    led: .orange
)

private let dischargeConfig = BatterySMCConfig(
    ch0i: BatterySMCValue.dischargeA,
    ch0j: BatterySMCValue.dischargeA,
    ch0b: BatterySMCValue.dischargeC,
    ch0c: BatterySMCValue.dischargeC,
    led: .green
)

private let systemDefaultConfig = BatterySMCConfig(
    ch0i: BatterySMCValue.systemDefault,
    ch0j: BatterySMCValue.systemDefault,
    ch0b: BatterySMCValue.systemDefault,
    ch0c: BatterySMCValue.systemDefault,
    led: .system
)

private struct BatterySMCSnapshot {
    // Snapshot of the SMC bytes we touch, captured before an update, so we can
    // roll back if a later write fails.
    var ch0i: UInt8
    var ch0j: UInt8
    var ch0b: UInt8
    var ch0c: UInt8
    var magsafeLed: UInt8
}

private func hexBytes(_ bytes: [UInt8]) -> String {
    if bytes.isEmpty { return "" }
    return bytes.map { String(format: "%02X", $0) }.joined()
}

private func readSnapshot(using smc: SMC) -> BatterySMCSnapshot? {
    // Reads all relevant keys. If any read fails, we refuse to proceed with a
    // multi-step update because we cannot safely roll back.
    guard let ch0i = smc.readByte(key: BatterySMCKey.chargeModeKeyCH0I) else {
        Log.error("smc_snapshot_read_failed key=CH0I", scope: "smc")
        return nil
    }
    guard let ch0j = smc.readByte(key: BatterySMCKey.chargeModeKeyCH0J) else {
        Log.error("smc_snapshot_read_failed key=CH0J", scope: "smc")
        return nil
    }
    guard let ch0b = smc.readByte(key: BatterySMCKey.chargeControlKeyCH0B) else {
        Log.error("smc_snapshot_read_failed key=CH0B", scope: "smc")
        return nil
    }
    guard let ch0c = smc.readByte(key: BatterySMCKey.chargeControlKeyCH0C) else {
        Log.error("smc_snapshot_read_failed key=CH0C", scope: "smc")
        return nil
    }
    guard let magsafeLed = smc.readByte(key: BatterySMCKey.magsafeLedKeyACLC) else {
        Log.error("smc_snapshot_read_failed key=ACLC", scope: "smc")
        return nil
    }
    
    return BatterySMCSnapshot(
        ch0i: ch0i,
        ch0j: ch0j,
        ch0b: ch0b,
        ch0c: ch0c,
        magsafeLed: magsafeLed
    )
}

private func restoreSnapshot(_ snapshot: BatterySMCSnapshot, using smc: SMC) {
    Log.warn("smc_snapshot_restore_attempt", scope: "smc")
    // Best-effort rollback. We intentionally ignore individual write failures
    // here because the caller already treats the overall operation as failed.
    _ = smc.writeByte(key: BatterySMCKey.chargeModeKeyCH0I, value: snapshot.ch0i)
    _ = smc.writeByte(key: BatterySMCKey.chargeModeKeyCH0J, value: snapshot.ch0j)
    _ = smc.writeByte(key: BatterySMCKey.chargeControlKeyCH0B, value: snapshot.ch0b)
    _ = smc.writeByte(key: BatterySMCKey.chargeControlKeyCH0C, value: snapshot.ch0c)
    _ = smc.writeByte(key: BatterySMCKey.magsafeLedKeyACLC, value: snapshot.magsafeLed)
}

private func applyConfig(_ config: BatterySMCConfig, using smc: SMC) -> Bool {
    // Applies a configuration in multiple writes with rollback on failure.
    //
    // Atomicity model:
    // - If we fail before writing anything, we return false with no changes.
    // - If we fail after writing one or more keys, we attempt to restore all
    //   previously touched keys from the snapshot.
    // - On success, all targeted keys should match `config`.
    guard let snapshot = readSnapshot(using: smc) else {
        return false
    }

    if !smc.writeByte(key: BatterySMCKey.chargeModeKeyCH0I, value: config.ch0i) {
        return false
    }
    
    if !smc.writeByte(key: BatterySMCKey.chargeModeKeyCH0J, value: config.ch0j) {
        restoreSnapshot(snapshot, using: smc)
        return false
    }
    
    if !smc.writeByte(key: BatterySMCKey.chargeControlKeyCH0B, value: config.ch0b) {
        restoreSnapshot(snapshot, using: smc)
        return false
    }
    
    if !smc.writeByte(key: BatterySMCKey.chargeControlKeyCH0C, value: config.ch0c) {
        restoreSnapshot(snapshot, using: smc)
        return false
    }
    
    if !smc.writeByte(key: BatterySMCKey.magsafeLedKeyACLC, value: config.led.rawValue) {
        restoreSnapshot(snapshot, using: smc)
        return false
    }
    
    return true
}

public func charge() -> Bool {
    // Writes a set of SMC keys to request charging and set LED to orange.
    let smc = SMC()
    guard smc.open() else {
        return false
    }
    defer { smc.close() }
    return applyConfig(chargeConfig, using: smc)
}

public func discharge() -> Bool {
    // Writes a set of SMC keys to request discharging and set LED to green.
    let smc = SMC()
    guard smc.open() else {
        return false
    }
    defer { smc.close() }
    return applyConfig(dischargeConfig, using: smc)
}

public func resetDefault() -> Bool {
    // Writes a set of SMC keys to restore system-managed defaults and LED behavior.
    let smc = SMC()
    guard smc.open() else {
        return false
    }
    defer { smc.close() }
    return applyConfig(systemDefaultConfig, using: smc)
}

public func currentPowerStatus() -> PowerStatus {
    // Infers status by reading back the same control keys.
    let smc = SMC()
    guard smc.open() else {
        return .unknown
    }
    defer { smc.close() }
    
    guard
        let ch0i = smc.readByte(key: BatterySMCKey.chargeModeKeyCH0I),
        let ch0j = smc.readByte(key: BatterySMCKey.chargeModeKeyCH0J),
        let ch0b = smc.readByte(key: BatterySMCKey.chargeControlKeyCH0B),
        let ch0c = smc.readByte(key: BatterySMCKey.chargeControlKeyCH0C)
    else {
        return .unknown
    }
    
    if ch0i == BatterySMCValue.systemDefault
        && ch0j == BatterySMCValue.systemDefault
        && ch0b == BatterySMCValue.systemDefault
        && ch0c == BatterySMCValue.systemDefault
    {
        return .systemDefault
    }
    
    if (ch0i == BatterySMCValue.systemDefault || ch0j == BatterySMCValue.systemDefault)
        && (ch0b == BatterySMCValue.systemDefault || ch0c == BatterySMCValue.systemDefault)
    {
        return .charging
    }
    
    if ch0i == BatterySMCValue.dischargeA
        && ch0j == BatterySMCValue.dischargeA
        && ch0b == BatterySMCValue.dischargeC
        && ch0c == BatterySMCValue.dischargeC
    {
        return .discharging
    }
    
    return .unknown
}

private class SMC {
    private var conn: io_connect_t = 0
    
    init() {}
    
    deinit {
        close()
    }
    
    func open() -> Bool {
        // Open a connection to the AppleSMC service.
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        
        let service = IOServiceGetMatchingService(mainPort, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            Log.error("smc_service_not_found", scope: "smc")
            return false
        }
        
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        if result != kIOReturnSuccess {
            Log.error("smc_open_failed result=\(result)", scope: "smc")
        }
        if result != kIOReturnSuccess {
            return false
        }
        let openResult = IOConnectCallMethod(conn, 0, nil, 0, nil, 0, nil, nil, nil, nil)
        if openResult != kIOReturnSuccess {
            Log.error("smc_client_open_failed result=\(openResult)", scope: "smc")
            close()
            return false
        }
        return true
    }
    
    func close() {
        // Close the user client connection if present.
        if conn != 0 {
            _ = IOConnectCallMethod(conn, 1, nil, 0, nil, 0, nil, nil, nil, nil)
            IOServiceClose(conn)
            conn = 0
        }
    }

    private func storeUInt32(_ value: UInt32, into bytes: inout [UInt8], offset: Int) {
        let v = value
        withUnsafeBytes(of: v) { raw in
            bytes.replaceSubrange(offset..<(offset + 4), with: raw)
        }
    }

    private func callSMC(
        key: UInt32,
        command: UInt8,
        dataSize: UInt32,
        writeBytes: [UInt8]?
    ) -> (kern_return_t, UInt8, UInt8, [UInt8]) {
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)

        storeUInt32(key, into: &input, offset: 0)
        storeUInt32(dataSize, into: &input, offset: 28)
        input[42] = command

        if let writeBytes, !writeBytes.isEmpty {
            let count = min(Int(dataSize), min(writeBytes.count, 32))
            input.replaceSubrange(48..<(48 + count), with: writeBytes.prefix(count))
        }

        var outputSize = 80
        let kr: kern_return_t = input.withUnsafeBytes { inRaw in
            output.withUnsafeMutableBytes { outRaw in
                IOConnectCallStructMethod(
                    conn,
                    2,
                    inRaw.baseAddress,
                    input.count,
                    outRaw.baseAddress,
                    &outputSize
                )
            }
        }

        let resultByte: UInt8 = output.indices.contains(20) ? output[20] : 0xFF
        let statusByte: UInt8 = output.indices.contains(21) ? output[21] : 0xFF
        return (kr, resultByte, statusByte, output)
    }
    
    func readByte(key: String) -> UInt8? {
        // Read 1 byte from an SMC key.
        guard let keyCode = strToUInt32(key) else { return nil }
        let (kr, result, status, output) = callSMC(
            key: keyCode,
            command: SMC_CMD_READ_BYTES,
            dataSize: 1,
            writeBytes: nil
        )
        guard kr == kIOReturnSuccess, result == 0 else {
            Log.error("smc_read_failed key=\(key) kr=\(kr) out=\(result) status=\(status)", scope: "smc")
            return nil
        }
        let bytes = Array(output[48..<49])
        Log.info("smc_read_ok key=\(key) value=\(hexBytes(bytes))", scope: "smc")
        return bytes.first
    }
    
    func writeByte(key: String, value: UInt8) -> Bool {
        // Write 1 byte to an SMC key.
        guard let keyCode = strToUInt32(key) else { return false }
        let (kr, result, status, _) = callSMC(
            key: keyCode,
            command: SMC_CMD_WRITE_BYTES,
            dataSize: 1,
            writeBytes: [value]
        )
        if kr != kIOReturnSuccess || result != 0 {
            Log.error("smc_write_failed key=\(key) value=\(String(format: "%02X", value)) kr=\(kr) out=\(result) status=\(status)", scope: "smc")
            return false
        }
        Log.info("smc_write_ok key=\(key) value=\(String(format: "%02X", value))", scope: "smc")
        return true
    }
    
    private func strToUInt32(_ str: String) -> UInt32? {
        // Converts a 4-character SMC key string (e.g. "ACLC") into a UInt32 code.
        guard str.count == 4 else { return nil }
        var result: UInt32 = 0
        for char in str.utf8 {
            result = (result << 8) | UInt32(char)
        }
        return result
    }
}

private let SMC_CMD_READ_BYTES: UInt8 = 5
private let SMC_CMD_WRITE_BYTES: UInt8 = 6
