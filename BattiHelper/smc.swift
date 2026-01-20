import Foundation
import IOKit

public enum PowerStatus: String {
    case charging
    case discharging
    case systemDefault
    case unknown
}

private enum MagSafeLED: UInt8 {
    case system = 0x00
    case off = 0x01
    case green = 0x03
    case orange = 0x04
}

private let MAGSAVE_LED_KEY = "ACLC"

public func charge() -> Bool {
    let smc = SMC()
    guard smc.open() else {
        return false
    }
    defer { smc.close() }
    
    let a1 = smc.writeByte(key: "CH0I", value: 0x00)
    let a2 = smc.writeByte(key: "CH0J", value: 0x00)
    
    let c1 = smc.writeByte(key: "CH0B", value: 0x00)
    let c2 = smc.writeByte(key: "CH0C", value: 0x00)
    
    let led = smc.writeByte(key: MAGSAVE_LED_KEY, value: MagSafeLED.orange.rawValue)
    
    return a1 && a2 && c1 && c2 && led
}

public func discharge() -> Bool {
    let smc = SMC()
    guard smc.open() else {
        return false
    }
    defer { smc.close() }
    
    let a1 = smc.writeByte(key: "CH0I", value: 0x01)
    let a2 = smc.writeByte(key: "CH0J", value: 0x01)
    
    let c1 = smc.writeByte(key: "CH0B", value: 0x02)
    let c2 = smc.writeByte(key: "CH0C", value: 0x02)
    
    let led = smc.writeByte(key: MAGSAVE_LED_KEY, value: MagSafeLED.green.rawValue)
    
    return a1 && a2 && c1 && c2 && led
}

public func resetDefault() -> Bool {
    let smc = SMC()
    guard smc.open() else {
        return false
    }
    defer { smc.close() }
    
    let a1 = smc.writeByte(key: "CH0I", value: 0x00)
    let a2 = smc.writeByte(key: "CH0J", value: 0x00)
    
    let c1 = smc.writeByte(key: "CH0B", value: 0x00)
    let c2 = smc.writeByte(key: "CH0C", value: 0x00)
    
    let led = smc.writeByte(key: MAGSAVE_LED_KEY, value: MagSafeLED.system.rawValue)
    
    return a1 && a2 && c1 && c2 && led
}

public func currentPowerStatus() -> PowerStatus {
    let smc = SMC()
    guard smc.open() else {
        return .unknown
    }
    defer { smc.close() }
    
    guard
        let ch0i = smc.readByte(key: "CH0I"),
        let ch0j = smc.readByte(key: "CH0J"),
        let ch0b = smc.readByte(key: "CH0B"),
        let ch0c = smc.readByte(key: "CH0C")
    else {
        return .unknown
    }
    
    if ch0i == 0x00 && ch0j == 0x00 && ch0b == 0x00 && ch0c == 0x00 {
        return .systemDefault
    }
    
    if (ch0i == 0x00 || ch0j == 0x00) && (ch0b == 0x00 || ch0c == 0x00) {
        return .charging
    }
    
    if ch0i == 0x01 && ch0j == 0x01 && ch0b == 0x02 && ch0c == 0x02 {
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
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        
        let service = IOServiceGetMatchingService(mainPort, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        return result == kIOReturnSuccess
    }
    
    func close() {
        if conn != 0 {
            IOServiceClose(conn)
            conn = 0
        }
    }
    
    func readByte(key: String) -> UInt8? {
        guard let keyCode = strToUInt32(key) else { return nil }
        
        var inputStruct = SMCParamStruct()
        inputStruct.key = keyCode
        inputStruct.data8 = SMC_CMD_READ_BYTES
        inputStruct.keyInfo.dataSize = 1
        
        var outputStruct = SMCParamStruct()
        
        let result = callSMC(input: &inputStruct, output: &outputStruct)
        guard result == kIOReturnSuccess, outputStruct.result == 0 else {
            return nil
        }
        
        return outputStruct.bytes.0
    }
    
    func writeByte(key: String, value: UInt8) -> Bool {
        guard let keyCode = strToUInt32(key) else { return false }
        
        var inputStruct = SMCParamStruct()
        inputStruct.key = keyCode
        inputStruct.data8 = SMC_CMD_WRITE_BYTES
        inputStruct.keyInfo.dataSize = 1
        inputStruct.bytes.0 = value
        
        var outputStruct = SMCParamStruct()
        
        let result = callSMC(input: &inputStruct, output: &outputStruct)
        return result == kIOReturnSuccess && outputStruct.result == 0
    }
    private func callSMC(input: inout SMCParamStruct, output: inout SMCParamStruct) -> kern_return_t {
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        
        return IOConnectCallStructMethod(
            conn,
            2,
            &input,
            inputSize,
            &output,
            &outputSize
        )
    }
    
    private func strToUInt32(_ str: String) -> UInt32? {
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

private struct SMCKeyDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
}

private struct SMCKeyDataPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimitData()
    var keyInfo = SMCKeyDataKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0
    )
}
