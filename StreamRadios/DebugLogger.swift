//
//  DebugLogger.swift
//  StreamRadios
//
//  Created by AI Assistant on 2025-01-30.
//

import Foundation
import os.log
import UIKit

/// Comprehensive error logging system for capturing all user exceptions and errors
@MainActor
class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    // MARK: - Log Entry Structure
    struct LogEntry: Codable, Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let message: String
        let category: String
        let file: String
        let function: String
        let line: Int
        let stackTrace: [String]
        let jsonData: [String: Any]?
        let userAction: String?
        let errorDomain: String?
        let errorCode: Int?
        let crashInfo: CrashInfo?
        
        enum CodingKeys: String, CodingKey {
            case timestamp, level, message, category, file, function, line
            case stackTrace, userAction, errorDomain, errorCode, crashInfo
        }
        
        init(level: LogLevel, message: String, category: String, file: String, function: String, line: Int, stackTrace: [String] = [], jsonData: [String: Any]? = nil, userAction: String? = nil, errorDomain: String? = nil, errorCode: Int? = nil, crashInfo: CrashInfo? = nil) {
            self.timestamp = Date()
            self.level = level
            self.message = message
            self.category = category
            self.file = file
            self.function = function
            self.line = line
            self.stackTrace = stackTrace
            self.jsonData = jsonData
            self.userAction = userAction
            self.errorDomain = errorDomain
            self.errorCode = errorCode
            self.crashInfo = crashInfo
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(level, forKey: .level)
            try container.encode(message, forKey: .message)
            try container.encode(category, forKey: .category)
            try container.encode(file, forKey: .file)
            try container.encode(function, forKey: .function)
            try container.encode(line, forKey: .line)
            try container.encode(stackTrace, forKey: .stackTrace)
            try container.encode(userAction, forKey: .userAction)
            try container.encode(errorDomain, forKey: .errorDomain)
            try container.encode(errorCode, forKey: .errorCode)
            try container.encode(crashInfo, forKey: .crashInfo)
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            level = try container.decode(LogLevel.self, forKey: .level)
            message = try container.decode(String.self, forKey: .message)
            category = try container.decode(String.self, forKey: .category)
            file = try container.decode(String.self, forKey: .file)
            function = try container.decode(String.self, forKey: .function)
            line = try container.decode(Int.self, forKey: .line)
            stackTrace = try container.decode([String].self, forKey: .stackTrace)
            userAction = try container.decodeIfPresent(String.self, forKey: .userAction)
            errorDomain = try container.decodeIfPresent(String.self, forKey: .errorDomain)
            errorCode = try container.decodeIfPresent(Int.self, forKey: .errorCode)
            crashInfo = try container.decodeIfPresent(CrashInfo.self, forKey: .crashInfo)
            jsonData = nil // Don't persist JSON data to avoid encoding issues
        }
    }
    
    struct CrashInfo: Codable {
        let crashType: String
        let signal: String?
        let exceptionName: String?
        let exceptionReason: String?
        let memoryFootprint: Double
    }
    
    enum LogLevel: String, CaseIterable, Codable {
        case critical = "CRITICAL"
        case error = "ERROR"
        case warning = "WARNING"
        case info = "INFO"
        case debug = "DEBUG"
        
        var emoji: String {
            switch self {
            case .critical: return "💥"
            case .error: return "❌"
            case .warning: return "⚠️"
            case .info: return "ℹ️"
            case .debug: return "🔍"
            }
        }
        
        var priority: Int {
            switch self {
            case .critical: return 5
            case .error: return 4
            case .warning: return 3
            case .info: return 2
            case .debug: return 1
            }
        }
    }
    
    // MARK: - Properties
    @Published private(set) var logEntries: [LogEntry] = []
    private let logQueue = DispatchQueue(label: "com.streamradios.debuglogger", qos: .utility)
    private let maxLogEntries = 1000
    private var currentUserAction: String?
    
    // MARK: - File Management
    private static let logFileName = "streamradios_debug.log"
    private static var logFileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(logFileName)
    }
    
    // MARK: - Initialization
    private init() {
        setupCrashReporting()
        loadPersistedLogs()
    }
    
    // MARK: - Public Logging Methods
    static func logCritical(_ message: String, category: String = "General", error: Error? = nil, jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        shared.log(level: .critical, message: message, category: category, error: error, jsonData: jsonData, file: file, function: function, line: line)
    }
    
    static func logError(_ message: String, category: String = "General", error: Error? = nil, jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        shared.log(level: .error, message: message, category: category, error: error, jsonData: jsonData, file: file, function: function, line: line)
    }
    
    static func logWarning(_ message: String, category: String = "General", error: Error? = nil, jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        shared.log(level: .warning, message: message, category: category, error: error, jsonData: jsonData, file: file, function: function, line: line)
    }
    
    static func logInfo(_ message: String, category: String = "General", jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        shared.log(level: .info, message: message, category: category, jsonData: jsonData, file: file, function: function, line: line)
    }
    
    static func logDebug(_ message: String, category: String = "General", jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        shared.log(level: .debug, message: message, category: category, jsonData: jsonData, file: file, function: function, line: line)
    }
    
    // MARK: - User Action Tracking
    static func setUserAction(_ action: String) {
        shared.currentUserAction = action
    }
    
    static func clearUserAction() {
        shared.currentUserAction = nil
    }
    
    // MARK: - Core Logging Implementation
    private func log(level: LogLevel, message: String, category: String, error: Error? = nil, jsonData: [String: Any]? = nil, file: String, function: String, line: Int) {
        logQueue.async {
            // Capture stack trace
            let stackTrace = self.captureStackTrace()
            
            // Extract error information
            var errorDomain: String?
            var errorCode: Int?
            var enhancedMessage = message
            
            if let error = error {
                if let nsError = error as NSError? {
                    errorDomain = nsError.domain
                    errorCode = nsError.code
                    enhancedMessage += " | Error: \(error.localizedDescription)"
                } else {
                    enhancedMessage += " | Error: \(error.localizedDescription)"
                }
            }
            
            // Create log entry
            let logEntry = LogEntry(
                level: level,
                message: enhancedMessage,
                category: category,
                file: URL(fileURLWithPath: file).lastPathComponent,
                function: function,
                line: line,
                stackTrace: stackTrace,
                jsonData: jsonData,
                userAction: self.currentUserAction,
                errorDomain: errorDomain,
                errorCode: errorCode
            )
            
            DispatchQueue.main.async {
                self.addLogEntry(logEntry)
            }
            
            // Log to system console as well
            self.logToConsole(logEntry)
        }
    }
    
    private func addLogEntry(_ entry: LogEntry) {
        logEntries.append(entry)
        
        // Maintain max log entries
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
        
        // Persist to disk
        persistLogs()
    }
    
    private func captureStackTrace() -> [String] {
        let stackSymbols = Thread.callStackSymbols
        return Array(stackSymbols.dropFirst(3)) // Remove DebugLogger internal calls
    }
    
    private func logToConsole(_ entry: LogEntry) {
        let consoleMessage = "\(entry.level.emoji) [\(entry.category)] \(entry.message) | \(entry.file):\(entry.line) in \(entry.function)"
        print(consoleMessage)
        
        // Also log to OS unified logging system
        let logger = Logger(subsystem: "com.streamradios.app", category: entry.category)
        switch entry.level {
        case .critical:
            logger.critical("\(consoleMessage, privacy: .public)")
        case .error:
            logger.error("\(consoleMessage, privacy: .public)")
        case .warning:
            logger.warning("\(consoleMessage, privacy: .public)")
        case .info:
            logger.info("\(consoleMessage, privacy: .public)")
        case .debug:
            logger.debug("\(consoleMessage, privacy: .public)")
        }
    }
    
    // MARK: - Crash Reporting
    private func setupCrashReporting() {
        // Set up NSException handler
        NSSetUncaughtExceptionHandler { exception in
            let crashInfo = CrashInfo(
                crashType: "NSException",
                signal: nil,
                exceptionName: exception.name.rawValue,
                exceptionReason: exception.reason,
                memoryFootprint: DebugLogger.shared.getMemoryFootprint()
            )
            
            DebugLogger.shared.logCrash(
                message: "Uncaught exception: \(exception.name.rawValue)",
                crashInfo: crashInfo,
                stackTrace: exception.callStackSymbols
            )
        }
        
        // Set up signal handler for crashes
        signal(SIGABRT) { _ in DebugLogger.shared.handleSignal("SIGABRT") }
        signal(SIGILL) { _ in DebugLogger.shared.handleSignal("SIGILL") }
        signal(SIGSEGV) { _ in DebugLogger.shared.handleSignal("SIGSEGV") }
        signal(SIGFPE) { _ in DebugLogger.shared.handleSignal("SIGFPE") }
        signal(SIGBUS) { _ in DebugLogger.shared.handleSignal("SIGBUS") }
        signal(SIGPIPE) { _ in DebugLogger.shared.handleSignal("SIGPIPE") }
    }
    
    private func handleSignal(_ signal: String) {
        let crashInfo = CrashInfo(
            crashType: "Signal",
            signal: signal,
            exceptionName: nil,
            exceptionReason: "Application received signal \(signal)",
            memoryFootprint: getMemoryFootprint()
        )
        
        logCrash(
            message: "Application crashed with signal: \(signal)",
            crashInfo: crashInfo,
            stackTrace: Thread.callStackSymbols
        )
    }
    
    private func logCrash(message: String, crashInfo: CrashInfo, stackTrace: [String]) {
        let logEntry = LogEntry(
            level: .critical,
            message: message,
            category: "Crash",
            file: "Unknown",
            function: "Unknown",
            line: 0,
            stackTrace: stackTrace,
            jsonData: nil,
            userAction: currentUserAction,
            crashInfo: crashInfo
        )
        
        // Immediately persist crash to disk
        logEntries.append(logEntry)
        persistLogs()
    }
    
    // MARK: - Memory Management
    private func getMemoryFootprint() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        guard result == KERN_SUCCESS else { return 0.0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }
    
    // MARK: - Persistence
    private func persistLogs() {
        logQueue.async {
            do {
                let data = try JSONEncoder().encode(self.logEntries)
                try data.write(to: Self.logFileURL)
            } catch {
                print("Failed to persist logs: \(error)")
            }
        }
    }
    
    private func loadPersistedLogs() {
        logQueue.async {
            do {
                let data = try Data(contentsOf: Self.logFileURL)
                let loadedEntries = try JSONDecoder().decode([LogEntry].self, from: data)
                
                DispatchQueue.main.async {
                    self.logEntries = loadedEntries
                }
            } catch {
                // No existing logs or corrupted file
                print("No existing logs to load: \(error)")
            }
        }
    }
    
    // MARK: - Log Management
    static func clearAllLogs() {
        shared.logEntries.removeAll()
        shared.persistLogs()
    }
    
    static func getLogStatistics() -> [String: Int] {
        let entries = shared.logEntries
        var stats: [String: Int] = [:]
        
        for level in LogLevel.allCases {
            stats[level.rawValue] = entries.filter { $0.level == level }.count
        }
        
        return stats
    }
    
    static func getLogsForCategory(_ category: String) -> [LogEntry] {
        return shared.logEntries.filter { $0.category == category }
    }
    
    static func getLogsForLevel(_ level: LogLevel) -> [LogEntry] {
        return shared.logEntries.filter { $0.level == level }
    }
    
    // MARK: - Export Functionality
    static func getAllLogsForSharing() -> String {
        let entries = shared.logEntries.sorted { $0.timestamp > $1.timestamp }
        var output = """
        StreamRadios Debug Report
        Generated: \(Date().formatted(.dateTime))
        Total Entries: \(entries.count)
        
        System Information:
        Device: \(UIDevice.current.model)
        iOS Version: \(UIDevice.current.systemVersion)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Memory Usage: \(String(format: "%.2f MB", shared.getMemoryFootprint()))
        
        =====================================
        ERROR LOG ENTRIES
        =====================================
        
        """
        
        for entry in entries {
            output += """
            
            [\(entry.level.emoji) \(entry.level.rawValue)] \(entry.timestamp.formatted(.dateTime))
            Category: \(entry.category)
            Message: \(entry.message)
            Location: \(entry.file):\(entry.line) in \(entry.function)
            
            """
            
            if !entry.stackTrace.isEmpty {
                output += "Stack Trace:\n"
                for (index, frame) in entry.stackTrace.enumerated() {
                    output += "  \(index): \(frame)\n"
                }
                output += "\n"
            }
            
            if let userAction = entry.userAction {
                output += "User Action: \(userAction)\n"
            }
            
            if let errorDomain = entry.errorDomain, let errorCode = entry.errorCode {
                output += "Error Domain: \(errorDomain), Code: \(errorCode)\n"
            }
            
            if let crashInfo = entry.crashInfo {
                output += """
                Crash Info:
                  Type: \(crashInfo.crashType)
                  Signal: \(crashInfo.signal ?? "N/A")
                  Exception: \(crashInfo.exceptionName ?? "N/A")
                  Reason: \(crashInfo.exceptionReason ?? "N/A")
                  Memory: \(String(format: "%.2f MB", crashInfo.memoryFootprint))
                
                """
            }
            
            output += "-----------------------------------\n"
        }
        
        return output
    }
    
    static func exportLogsToFile() -> URL? {
        let content = getAllLogsForSharing()
        let fileName = "StreamRadios_Debug_\(Date().formatted(.dateTime.day().month().year().hour().minute())).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            logError("Failed to export logs to file", category: "DebugLogger", error: error)
            return nil
        }
    }
}

// MARK: - Error Extension
extension Error {
    func logError(category: String = "Error", jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        DebugLogger.logError(
            self.localizedDescription,
            category: category,
            error: self,
            jsonData: jsonData,
            file: file,
            function: function,
            line: line
        )
    }
}