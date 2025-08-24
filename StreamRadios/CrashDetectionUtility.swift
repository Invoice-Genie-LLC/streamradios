//
//  CrashDetectionUtility.swift
//  StreamRadios
//
//  Created by AI Assistant on 2025-01-30.
//

import Foundation
import UIKit
import AVFoundation
import CoreData

/// Utility class for detecting and logging potential crashes in specific app modules
class CrashDetectionUtility {
    static let shared = CrashDetectionUtility()
    
    private init() {
        setupModuleSpecificMonitoring()
    }
    
    // MARK: - Module-Specific Crash Detection
    
    private func setupModuleSpecificMonitoring() {
        // Monitor Core Data operations
        setupCoreDataCrashDetection()
        
        // Monitor audio playback operations
        setupAudioCrashDetection()
        
        // Monitor network operations
        setupNetworkCrashDetection()
        
        // Monitor CloudKit operations
        setupCloudKitCrashDetection()
    }
    
    // MARK: - Core Data Crash Detection
    
    private func setupCoreDataCrashDetection() {
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: nil,
            queue: nil
        ) { notification in
            Task { @MainActor in
                self.monitorCoreDataOperation(notification)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: nil
        ) { notification in
            DebugLogger.setUserAction("Core Data Save Operation")
        }
    }
    
    @MainActor private func monitorCoreDataOperation(_ notification: Notification) {
        guard let context = notification.object as? NSManagedObjectContext else { return }
        
        // Check for potential crash conditions
        if let insertedObjects = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>,
           insertedObjects.count > 100 {
            DebugLogger.logPotentialCrash(
                "Large Core Data batch insert detected (\(insertedObjects.count) objects) - potential memory crash",
                category: "CoreData"
            )
        }
        
        if let deletedObjects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>,
           deletedObjects.count > 50 {
            DebugLogger.logWarning(
                "Large Core Data batch delete detected (\(deletedObjects.count) objects)",
                category: "CoreData"
            )
        }
        
        // Monitor for invalid object states
        for case let managedObject as NSManagedObject in context.registeredObjects {
            if managedObject.isFault && managedObject.isDeleted {
                DebugLogger.logError(
                    "Core Data fault/deleted object inconsistency detected",
                    category: "CoreData"
                )
            }
        }
    }
    
    // MARK: - Audio Crash Detection
    
    private func setupAudioCrashDetection() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { notification in
            Task { @MainActor in
                self.monitorAudioInterruption(notification)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            Task { @MainActor in
                self.monitorAudioRouteChange(notification)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: nil
        ) { notification in
            Task { @MainActor in
                self.monitorAudioPlaybackFailure(notification)
            }
        }
    }
    
    @MainActor private func monitorAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            DebugLogger.logWarning("Audio interruption began", category: "Audio")
            DebugLogger.setUserAction("Audio Interruption Began")
            
        case .ended:
            DebugLogger.logInfo("Audio interruption ended", category: "Audio")
            DebugLogger.setUserAction("Audio Interruption Ended")
            
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if !options.contains(.shouldResume) {
                    DebugLogger.logWarning(
                        "Audio interruption ended but should NOT resume - potential playback issue",
                        category: "Audio"
                    )
                }
            }
            
        @unknown default:
            DebugLogger.logError("Unknown audio interruption type: \(typeValue)", category: "Audio")
        }
    }
    
    @MainActor private func monitorAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            DebugLogger.logInfo("New audio device available", category: "Audio")
            
        case .oldDeviceUnavailable:
            DebugLogger.logWarning("Audio device became unavailable", category: "Audio")
            DebugLogger.setUserAction("Audio Device Disconnected")
            
        case .categoryChange:
            DebugLogger.logWarning("Audio category changed - potential crash risk", category: "Audio")
            
        case .override:
            DebugLogger.logWarning("Audio route override - potential conflict", category: "Audio")
            
        case .wakeFromSleep:
            DebugLogger.logInfo("Audio route change due to wake from sleep", category: "Audio")
            
        case .noSuitableRouteForCategory:
            DebugLogger.logPotentialCrash(
                "No suitable audio route for category - potential crash",
                category: "Audio"
            )
            
        case .routeConfigurationChange:
            DebugLogger.logInfo("Audio route configuration changed", category: "Audio")
            
        @unknown default:
            DebugLogger.logWarning("Unknown audio route change reason: \(reasonValue)", category: "Audio")
        }
    }
    
    @MainActor private func monitorAudioPlaybackFailure(_ notification: Notification) {
        if let playerItem = notification.object as? AVPlayerItem,
           let error = playerItem.error {
            DebugLogger.logError(
                "Audio playback failed: \(error.localizedDescription)",
                category: "Audio",
                error: error
            )
            DebugLogger.setUserAction("Audio Playback Failed")
        }
    }
    
    // MARK: - Network Crash Detection
    
    private func setupNetworkCrashDetection() {
        // Monitor for network-related crashes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSURLSessionTaskDidCompleteWithError"),
            object: nil,
            queue: nil
        ) { notification in
            Task { @MainActor in
                self.monitorNetworkCompletion(notification)
            }
        }
    }
    
    @MainActor private func monitorNetworkCompletion(_ notification: Notification) {
        if let task = notification.object as? URLSessionTask,
           let error = task.error {
            
            let nsError = error as NSError
            
            // Check for critical network errors that might cause crashes
            if nsError.code == NSURLErrorTimedOut {
                DebugLogger.logWarning("Network timeout for URL: \(task.originalRequest?.url?.absoluteString ?? "Unknown")", category: "Network")
            } else if nsError.code == NSURLErrorNetworkConnectionLost {
                DebugLogger.logError("Network connection lost during request", category: "Network", error: error)
            } else if nsError.code == NSURLErrorCannotConnectToHost {
                DebugLogger.logError("Cannot connect to host", category: "Network", error: error)
            } else if nsError.code == NSURLErrorResourceUnavailable {
                DebugLogger.logPotentialCrash("Resource unavailable - potential data corruption crash", category: "Network", error: error)
            }
        }
    }
    
    // MARK: - CloudKit Crash Detection
    
    private func setupCloudKitCrashDetection() {
        // CloudKit specific crash monitoring
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CloudKitOperationFailed"),
            object: nil,
            queue: nil
        ) { notification in
            if let error = notification.userInfo?["error"] as? Error {
                DebugLogger.logError("CloudKit operation failed", category: "CloudKit", error: error)
            }
        }
    }
    
    // MARK: - Memory Monitoring
    
    /// Monitor memory usage and detect potential memory-related crashes
    @MainActor static func monitorMemoryUsage() {
        let memoryUsage = getMemoryUsage()
        
        if memoryUsage > 200 { // 200MB threshold
            DebugLogger.logWarning("High memory usage detected: \(String(format: "%.1f MB", memoryUsage))", category: "Memory")
        }
        
        if memoryUsage > 300 { // 300MB critical threshold
            DebugLogger.logPotentialCrash("Critical memory usage: \(String(format: "%.1f MB", memoryUsage)) - potential crash", category: "Memory")
        }
    }
    
    private static func getMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
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
    
    // MARK: - Specific App Module Monitoring
    
    /// Monitor podcast-specific operations for potential crashes
    @MainActor static func monitorPodcastOperation(_ operation: String, episodeId: String? = nil) {
        DebugLogger.setUserAction("Podcast: \(operation)")
        
        if let episodeId = episodeId {
            DebugLogger.logDebug("Podcast operation: \(operation) for episode: \(episodeId)", category: "Podcast")
        } else {
            DebugLogger.logDebug("Podcast operation: \(operation)", category: "Podcast")
        }
        
        // Check memory usage during podcast operations
        monitorMemoryUsage()
    }
    
    /// Monitor radio-specific operations for potential crashes
    @MainActor static func monitorRadioOperation(_ operation: String, stationId: String? = nil) {
        DebugLogger.setUserAction("Radio: \(operation)")
        
        if let stationId = stationId {
            DebugLogger.logDebug("Radio operation: \(operation) for station: \(stationId)", category: "Radio")
        } else {
            DebugLogger.logDebug("Radio operation: \(operation)", category: "Radio")
        }
    }
    
    /// Monitor CarPlay operations for potential crashes
    @MainActor static func monitorCarPlayOperation(_ operation: String) {
        DebugLogger.setUserAction("CarPlay: \(operation)")
        DebugLogger.logDebug("CarPlay operation: \(operation)", category: "CarPlay")
    }
    
    /// Monitor CloudKit operations for potential crashes
    @MainActor static func monitorCloudKitOperation(_ operation: String, recordType: String? = nil) {
        DebugLogger.setUserAction("CloudKit: \(operation)")
        
        if let recordType = recordType {
            DebugLogger.logDebug("CloudKit operation: \(operation) for record type: \(recordType)", category: "CloudKit")
        } else {
            DebugLogger.logDebug("CloudKit operation: \(operation)", category: "CloudKit")
        }
    }
}

// MARK: - Extensions for Easy Integration

extension PodcastPlayer {
    @MainActor func logOperation(_ operation: String) {
        CrashDetectionUtility.monitorPodcastOperation(operation, episodeId: currentEpisode?.id)
    }
}

extension RadioPlayer {
    @MainActor func logOperation(_ operation: String) {
        CrashDetectionUtility.monitorRadioOperation(operation, stationId: currentlyPlayingStation?.id)
    }
}
