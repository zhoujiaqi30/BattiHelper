import Foundation
import Dispatch
import Darwin

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

enum Log {
    static let filePath = "/tmp/batti/helper/battihelper.log"
    
    private static let queue = DispatchQueue(label: "battihelper.log")
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static var fileHandle: FileHandle?
    
    static func debug(_ message: String, scope: String) {
        write(level: .debug, scope: scope, message: message)
    }
    
    static func info(_ message: String, scope: String) {
        write(level: .info, scope: scope, message: message)
    }
    
    static func warn(_ message: String, scope: String) {
        write(level: .warn, scope: scope, message: message)
    }
    
    static func error(_ message: String, scope: String) {
        write(level: .error, scope: scope, message: message)
    }
    
    static func write(level: LogLevel, scope: String, message: String) {
        queue.sync {
            let ts = dateFormatter.string(from: Date())
            let cleanMessage = message.replacingOccurrences(of: "\n", with: "\\n")
            let line = "ts=\(ts) level=\(level.rawValue) scope=\(scope) msg=\(cleanMessage)\n"
            
            _ = line.withCString { fputs($0, stderr) }
            appendToFile(line)
        }
    }
    
    private static func appendToFile(_ line: String) {
        if fileHandle == nil {
            let url = URL(fileURLWithPath: filePath)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: url)
            try? fileHandle?.seekToEnd()
        }
        
        guard let data = line.data(using: .utf8) else { return }
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            fileHandle = nil
        }
    }
}
