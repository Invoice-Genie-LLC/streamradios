//
//  DebugLogger.swift
//  StreamRadios
//
//  Created by AI Assistant on 2025-01-30.
//

import Foundation
import os.log
import UIKit
import Darwin
import MachO

/// Comprehensive error logging system for capturing all user exceptions and errors
class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    // Flag to prevent circular dependencies during initialization
    private static var isInitializing = false
    
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
    /// Main thread only. Background work (persistence, crash and hang handlers) must read
    /// `entriesSnapshot` instead: reading this array while the main thread appends to it races
    /// on its storage and aborts with "deallocated with non-zero retain count".
    @Published private(set) var logEntries: [LogEntry] = [] {
        didSet {
            snapshotLock.lock()
            snapshotStorage = logEntries
            snapshotLock.unlock()
        }
    }
    private let snapshotLock = NSLock()
    private var snapshotStorage: [LogEntry] = []
    /// Thread-safe copy of `logEntries`.
    private var entriesSnapshot: [LogEntry] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotStorage
    }
    private let logQueue = DispatchQueue(label: "com.streamradios.debuglogger", qos: .utility)
    private let maxLogEntries = 1000
    private var currentUserAction: String?
    private var crashReportingInitialized = false
    private var previousExceptionHandler: NSUncaughtExceptionHandler?
    private var previousTerminateHandler: (@convention(c) () -> Void)?
    private static var appStartTime = Date()
    private var launchTime: Date
    
    // MARK: - File Management
    private static let logFileName = "streamradios_debug.log"
    private static var logFileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(logFileName)
    }
    
    // MARK: - Initialization
    private init() {
        DebugLogger.isInitializing = true
        launchTime = Date()
        setupComprehensiveCrashReporting()
        loadPersistedLogs()
        DebugLogger.isInitializing = false
    }
    
    // MARK: - Public Logging Methods
    static func logCritical(_ message: String, category: String = "General", error: Error? = nil, jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        guard !isInitializing else { 
            print("🔧 [CRITICAL] \(message) (category: \(category))")
            return 
        }
        shared.log(level: .critical, message: message, category: category, error: error, jsonData: jsonData, file: file, function: function, line: line)
    }
    
    static func logError(_ message: String, category: String = "General", error: Error? = nil, jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        guard !isInitializing else { 
            print("🔧 [ERROR] \(message) (category: \(category))")
            return 
        }
        shared.log(level: .error, message: message, category: category, error: error, jsonData: jsonData, file: file, function: function, line: line)
    }
    
    static func logWarning(_ message: String, category: String = "General", error: Error? = nil, jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        guard !isInitializing else { 
            print("🔧 [WARNING] \(message) (category: \(category))")
            return 
        }
        shared.log(level: .warning, message: message, category: category, error: error, jsonData: jsonData, file: file, function: function, line: line)
    }
    
    static func logInfo(_ message: String, category: String = "General", jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        guard !isInitializing else { 
            print("🔧 [INFO] \(message) (category: \(category))")
            return 
        }
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
    
    // MARK: - Comprehensive Crash Reporting
    private func setupComprehensiveCrashReporting() {
        guard !crashReportingInitialized else {
            print("⚠️ Crash reporting already initialized")
            return
        }
        
        // Store previous handlers to allow chaining
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        
        // Set up comprehensive NSException handler
        NSSetUncaughtExceptionHandler { exception in
            DebugLogger.shared.handleNSException(exception)
            // Call previous handler if it existed
            if let previousHandler = DebugLogger.shared.previousExceptionHandler {
                previousHandler(exception)
            }
        }
        
        // Set up comprehensive signal handlers for all crash types
        setupSignalHandlers()
        
        // Set up memory pressure monitoring
        setupMemoryPressureMonitoring()
        
        // Set up app lifecycle monitoring for crash context
        setupAppLifecycleMonitoring()
        
        // Set up watchdog timer for hanging detection
        setupWatchdogTimer()
        
        crashReportingInitialized = true
    }
    
    private func setupSignalHandlers() {
        let crashSignals = [
            SIGABRT,  // Abort signal
            SIGILL,   // Illegal instruction
            SIGSEGV,  // Segmentation fault
            SIGFPE,   // Floating point exception
            SIGBUS,   // Bus error
            SIGPIPE,  // Broken pipe
            SIGTRAP,  // Trace/breakpoint trap
            SIGXCPU,  // CPU time limit exceeded
            SIGXFSZ,  // File size limit exceeded
            SIGVTALRM, // Virtual timer expired
            SIGPROF,  // Profiling timer expired
            SIGSYS    // Bad system call
        ]
        
        for signalType in crashSignals {
            signal(signalType) { signalNumber in
                DebugLogger.shared.handleSignalCrash(signalNumber)
            }
        }
    }
    
    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: logQueue)
        source.setEventHandler {
            let memoryUsage = self.getMemoryFootprint()
            let pressureLevel = source.data
            
            var level = "Unknown"
            if pressureLevel.contains(.normal) { level = "Normal" }
            if pressureLevel.contains(.warning) { level = "Warning" }
            if pressureLevel.contains(.critical) { level = "Critical" }
            
            DebugLogger.logWarning("Memory pressure detected: \(level), Usage: \(String(format: "%.1f MB", memoryUsage))", category: "MemoryPressure")
            
            if pressureLevel.contains(.critical) {
                DebugLogger.logCritical("Critical memory pressure - potential crash imminent", category: "MemoryPressure")
                self.persistLogsImmediately()
            }
        }
        source.resume()
    }
    
    private func setupAppLifecycleMonitoring() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            DebugLogger.logCritical("App will terminate - saving final crash logs", category: "AppLifecycle")
            self.persistLogsImmediately()
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            let memoryUsage = self.getMemoryFootprint()
            DebugLogger.logWarning("Memory warning received - Usage: \(String(format: "%.1f MB", memoryUsage))", category: "MemoryWarning")
        }
    }
    
    private func setupWatchdogTimer() {
        let watchdogQueue = DispatchQueue(label: "com.streamradios.watchdog", qos: .utility)
        let heartbeatLock = NSLock()
        var lastHeartbeat = Date()
        
        DispatchQueue.main.async {
            // .common mode: a default-mode timer stops firing during scroll tracking, which the
            // watchdog cannot tell apart from a hang.
            let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
                heartbeatLock.lock()
                lastHeartbeat = Date()
                heartbeatLock.unlock()
            }
            RunLoop.main.add(timer, forMode: .common)
            
            // Timers are frozen while the app is suspended, so the wall-clock gap measured on the
            // first tick after resume is not a hang.
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                heartbeatLock.lock()
                lastHeartbeat = Date()
                heartbeatLock.unlock()
            }
        }
        DebugLogger.startAppStateTracking()
        
        watchdogQueue.async {
            var reportedCurrentHang = false
            while true {
                Thread.sleep(forTimeInterval: 5.0)
                heartbeatLock.lock()
                let timeSinceHeartbeat = Date().timeIntervalSince(lastHeartbeat)
                heartbeatLock.unlock()
                
                guard timeSinceHeartbeat > 8.0, DebugLogger.appIsActive else {
                    reportedCurrentHang = false
                    continue
                }
                // Report each hang once - re-logging every 5s buries the real event and the
                // immediate persist adds file I/O while the main thread is already stuck.
                guard !reportedCurrentHang else { continue }
                reportedCurrentHang = true
                DebugLogger.logCritical("App hang detected - no heartbeat for \(String(format: "%.1f", timeSinceHeartbeat)) seconds", category: "Watchdog")
                self.persistLogsImmediately()
            }
        }
    }
    
    private func handleNSException(_ exception: NSException) {
        let memoryUsage = getMemoryFootprint()
        let appRuntime = Date().timeIntervalSince(launchTime)
        
        let crashInfo = CrashInfo(
            crashType: "NSException",
            signal: nil,
            exceptionName: exception.name.rawValue,
            exceptionReason: exception.reason,
            memoryFootprint: memoryUsage
        )
        
        let enhancedMessage = """
        💥 FATAL NSException Crash Detected!
        Exception: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "Unknown")
        Memory: \(String(format: "%.1f MB", memoryUsage))
        Runtime: \(String(format: "%.1f seconds", appRuntime))
        User Action: \(currentUserAction ?? "None")
        """
        
        logCrash(
            message: enhancedMessage,
            crashInfo: crashInfo,
            stackTrace: exception.callStackSymbols
        )
    }
    
    private func handleSignalCrash(_ signalNumber: Int32) {
        let signalName = getSignalName(signalNumber)
        let memoryUsage = getMemoryFootprint()
        let appRuntime = Date().timeIntervalSince(launchTime)
        
        let crashInfo = CrashInfo(
            crashType: "Signal",
            signal: signalName,
            exceptionName: nil,
            exceptionReason: "Application received fatal signal \(signalName) (\(signalNumber))",
            memoryFootprint: memoryUsage
        )
        
        let enhancedMessage = """
        💥 FATAL Signal Crash Detected!
        Signal: \(signalName) (\(signalNumber))
        Description: \(getSignalDescription(signalNumber))
        Memory: \(String(format: "%.1f MB", memoryUsage))
        Runtime: \(String(format: "%.1f seconds", appRuntime))
        User Action: \(currentUserAction ?? "None")
        """
        
        logCrash(
            message: enhancedMessage,
            crashInfo: crashInfo,
            stackTrace: Thread.callStackSymbols
        )
    }
    
    private func getSignalName(_ signalNumber: Int32) -> String {
        switch signalNumber {
        case SIGABRT: return "SIGABRT"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGFPE: return "SIGFPE"
        case SIGBUS: return "SIGBUS"
        case SIGPIPE: return "SIGPIPE"
        case SIGTRAP: return "SIGTRAP"
        case SIGXCPU: return "SIGXCPU"
        case SIGXFSZ: return "SIGXFSZ"
        case SIGVTALRM: return "SIGVTALRM"
        case SIGPROF: return "SIGPROF"
        case SIGSYS: return "SIGSYS"
        default: return "UNKNOWN_SIGNAL"
        }
    }
    
    private func getSignalDescription(_ signalNumber: Int32) -> String {
        switch signalNumber {
        case SIGABRT: return "Abort - Program terminated abnormally"
        case SIGILL: return "Illegal Instruction - Invalid machine instruction"
        case SIGSEGV: return "Segmentation Fault - Invalid memory access"
        case SIGFPE: return "Floating Point Exception - Math error"
        case SIGBUS: return "Bus Error - Invalid memory alignment"
        case SIGPIPE: return "Broken Pipe - Write to closed pipe"
        case SIGTRAP: return "Trace/Breakpoint - Debugger trap"
        case SIGXCPU: return "CPU Limit - CPU time exceeded"
        case SIGXFSZ: return "File Size Limit - File too large"
        case SIGVTALRM: return "Virtual Timer - Virtual alarm expired"
        case SIGPROF: return "Profiling Timer - Profiling alarm expired"
        case SIGSYS: return "Bad System Call - Invalid system call"
        default: return "Unknown signal type"
        }
    }
    
    private func logCrash(message: String, crashInfo: CrashInfo, stackTrace: [String]) {
        let enhancedStackTrace = enhanceStackTrace(stackTrace)
        let systemInfo = gatherSystemInfo()
        
        let logEntry = LogEntry(
            level: .critical,
            message: message,
            category: "Crash",
            file: "CrashHandler",
            function: "handleCrash",
            line: 0,
            stackTrace: enhancedStackTrace,
            jsonData: systemInfo,
            userAction: currentUserAction,
            crashInfo: crashInfo
        )
        
        // Immediately persist crash to disk using synchronous write. Crash handlers can run on
        // any thread, so the entry is written alongside the snapshot rather than appended to
        // the main-thread `logEntries`.
        persistLogsImmediately(including: logEntry)
        
        // Also write to system console for additional visibility
        print("💥💥💥 CRASH DETECTED 💥💥💥")
        print("Message: \(message)")
        print("Stack: \(enhancedStackTrace.joined(separator: "\n"))")
        
        // Log to OS unified logging for crash reports
        let logger = Logger(subsystem: "com.streamradios.crash", category: "Fatal")
        logger.fault("💥 CRASH: \(message, privacy: .public)")
    }
    
    private func enhanceStackTrace(_ stackTrace: [String]) -> [String] {
        var enhanced: [String] = []
        
        enhanced.append("=== CRASH STACK TRACE ===")
        enhanced.append("Timestamp: \(Date().formatted(.iso8601))")
        enhanced.append("App Runtime: \(String(format: "%.1f seconds", Date().timeIntervalSince(launchTime)))")
        enhanced.append("Memory Usage: \(String(format: "%.1f MB", getMemoryFootprint()))")
        enhanced.append("Device: \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)")
        enhanced.append("=========================")
        enhanced.append("")
        
        for (index, frame) in stackTrace.enumerated() {
            enhanced.append("\(String(format: "%2d", index)): \(frame)")
        }
        
        return enhanced
    }
    
    private func gatherSystemInfo() -> [String: Any] {
        return [
            "device_model": UIDevice.current.model,
            "ios_version": UIDevice.current.systemVersion,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "Unknown",
            "build_version": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "Unknown",
            "bundle_id": Bundle.main.bundleIdentifier ?? "Unknown",
            "memory_usage_mb": getMemoryFootprint(),
            "app_runtime_seconds": Date().timeIntervalSince(launchTime),
            "crash_timestamp": Date().timeIntervalSince1970,
            "user_action": currentUserAction ?? "None",
            "total_log_entries": entriesSnapshot.count
        ]
    }
    
    private func persistLogsImmediately(including extraEntry: LogEntry? = nil) {
        var entries = entriesSnapshot
        if let extraEntry {
            entries.append(extraEntry)
        }
        
        // Synchronous write to ensure crash data is saved
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: Self.logFileURL, options: .atomic)
            
            // Also create a specific crash file
            let crashFileName = "streamradios_crash_\(Date().timeIntervalSince1970).log"
            let crashFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(crashFileName)
            
            if let lastEntry = entries.last, lastEntry.level == .critical {
                let crashData = try JSONEncoder().encode([lastEntry])
                try crashData.write(to: crashFileURL, options: .atomic)
            }
            
        } catch {
            // If JSON encoding fails, write raw text
            let textLog = DebugLogger.getAllLogsForSharing()
            try? textLog.write(to: Self.logFileURL, atomically: true, encoding: String.Encoding.utf8)
        }
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
        let entries = entriesSnapshot
        logQueue.async {
            do {
                let data = try JSONEncoder().encode(entries)
                try data.write(to: Self.logFileURL)
            } catch {
                print("Failed to persist logs: \(error)")
                // Fallback to text format if JSON fails
                let textLog = DebugLogger.getAllLogsForSharing()
                try? textLog.write(to: Self.logFileURL, atomically: true, encoding: String.Encoding.utf8)
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
    
    // MARK: - Enhanced Crash Detection Methods
    
    /// Log a potential crash before it happens (e.g., unrecoverable error)
    static func logPotentialCrash(_ message: String, category: String = "PreCrash", error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        shared.currentUserAction = "Potential crash detected"
        logCritical("🚨 POTENTIAL CRASH: \(message)", category: category, error: error, file: file, function: function, line: line)
        shared.persistLogsImmediately()
    }
    
    /// Log when app becomes unresponsive
    static func logAppHang(_ message: String, duration: TimeInterval) {
        let hangMessage = "🔒 APP HANG: \(message) - Duration: \(String(format: "%.1f seconds", duration))"
        shared.log(level: .critical, message: hangMessage, category: "AppHang", file: "HangDetector", function: "detectHang", line: 0)
        shared.persistLogsImmediately()
    }
    
    /// Monitor for main thread blocks
    static func startMainThreadMonitoring() {
        let monitorQueue = DispatchQueue(label: "com.streamradios.mainthread.monitor", qos: .utility)
        let activityLock = NSLock()
        var lastMainThreadActivity = Date()
        
        // Update activity on main thread
        let heartbeat = Timer(timeInterval: 0.1, repeats: true) { _ in
            activityLock.lock()
            lastMainThreadActivity = Date()
            activityLock.unlock()
        }
        // Default mode stops firing during scroll tracking, which reads as a permanent hang.
        RunLoop.main.add(heartbeat, forMode: .common)
        
        // Timers are frozen while the app is suspended, so the wall-clock gap measured on the
        // first tick after resume is not a hang.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            activityLock.lock()
            lastMainThreadActivity = Date()
            activityLock.unlock()
        }
        startAppStateTracking()
        
        // Monitor from background
        monitorQueue.async {
            var reportedCurrentHang = false
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                activityLock.lock()
                let timeSinceActivity = Date().timeIntervalSince(lastMainThreadActivity)
                activityLock.unlock()
                
                if timeSinceActivity > 5.0 && appIsActive {
                    // Report each hang once - re-logging every second buries the real event and
                    // the immediate log persist adds I/O while the main thread is already stuck.
                    if !reportedCurrentHang {
                        reportedCurrentHang = true
                        logAppHang("Main thread blocked", duration: timeSinceActivity)
                    }
                } else {
                    reportedCurrentHang = false
                }
            }
        }
    }
    
    // MARK: - App Activity State
    
    private static let appStateLock = NSLock()
    private static var appIsActiveStorage = true
    private static var appStateObserversInstalled = false
    
    /// Hang detection is only meaningful while the app is foreground-active: a suspended app
    /// simply stops ticking, and that gap is indistinguishable from a blocked main thread.
    static var appIsActive: Bool {
        appStateLock.lock()
        defer { appStateLock.unlock() }
        return appIsActiveStorage
    }
    
    static func startAppStateTracking() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { startAppStateTracking() }
            return
        }
        guard !appStateObserversInstalled else { return }
        appStateObserversInstalled = true
        
        appStateLock.lock()
        appIsActiveStorage = UIApplication.shared.applicationState == .active
        appStateLock.unlock()
        
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            appStateLock.lock()
            appIsActiveStorage = true
            appStateLock.unlock()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            appStateLock.lock()
            appIsActiveStorage = false
            appStateLock.unlock()
        }
    }
    
    // MARK: - Log Management
    static func clearAllLogs() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { clearAllLogs() }
            return
        }
        shared.logEntries.removeAll()
        shared.persistLogs()
    }
    
    static func getLogStatistics() -> [String: Int] {
        let entries = shared.entriesSnapshot
        var stats: [String: Int] = [:]
        
        for level in LogLevel.allCases {
            stats[level.rawValue] = entries.filter { $0.level == level }.count
        }
        
        return stats
    }
    
    static func getLogsForCategory(_ category: String) -> [LogEntry] {
        return shared.entriesSnapshot.filter { $0.category == category }
    }
    
    static func getLogsForLevel(_ level: LogLevel) -> [LogEntry] {
        return shared.entriesSnapshot.filter { $0.level == level }
    }
    
    // MARK: - Export Functionality
    static func getAllLogsForSharing() -> String {
        let entries = shared.entriesSnapshot.sorted { $0.timestamp > $1.timestamp }
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
    @MainActor func logError(category: String = "Error", jsonData: [String: Any]? = nil, file: String = #file, function: String = #function, line: Int = #line) {
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