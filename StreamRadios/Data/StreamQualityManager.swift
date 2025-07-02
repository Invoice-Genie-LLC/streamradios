//
//  StreamQualityManager.swift
//  StreamRadios
//
//  Created by AI Assistant on 2024-12-19.
//

import Foundation
import AVFoundation
import Network
import Combine

/// Network quality levels for adaptive streaming
enum NetworkQuality: Int, CaseIterable {
    case low = 0      // Constrained cellular (64 kbps)
    case medium = 1   // Expensive cellular (96 kbps)
    case good = 2     // Normal cellular (128 kbps)
    case high = 3     // WiFi (256 kbps)
    case excellent = 4 // High-speed WiFi (320 kbps)
    
    var displayName: String {
        switch self {
        case .low: return "Playing at 64 kbps"
        case .medium: return "Playing at 96 kbps"
        case .good: return "Playing at 128 kbps"
        case .high: return "Playing at 256 kbps"
        case .excellent: return "Playing at 320 kbps"
        }
    }
    
    var bitrate: Double {
        switch self {
        case .low: return 64_000
        case .medium: return 96_000
        case .good: return 128_000
        case .high: return 256_000
        case .excellent: return 320_000
        }
    }
    
    var bufferDuration: TimeInterval {
        switch self {
        case .low: return 30.0      // Longer buffer for poor connections
        case .medium: return 20.0
        case .good: return 15.0
        case .high: return 10.0
        case .excellent: return 5.0  // Shorter buffer for fast connections
        }
    }
}

/// Manages seamless stream quality transitions without interruptions
class StreamQualityManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published var currentQuality: NetworkQuality = .high
    @Published var qualityDisplayText: String = "Premium Quality"
    @Published var isAdapting: Bool = false
    @Published var bufferHealth: Double = 1.0 // 0.0 to 1.0
    
    // MARK: - Private Properties
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "StreamQualityMonitor", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    
    // Network analysis
    private var networkSamples: [NetworkSample] = []
    private var currentPath: NWPath?
    private var bandwidthEstimator = BandwidthEstimator()
    
    // Adaptation settings
    private let maxSamples = 10
    private let adaptationThreshold: TimeInterval = 3.0
    private var lastAdaptationTime: Date = .distantPast
    private var targetQuality: NetworkQuality?
    
    // Buffer monitoring
    private weak var playerItem: AVPlayerItem?
    private var bufferObserver: Timer?
    private var loadedTimeRangesObserver: NSKeyValueObservation?
    
    // Quality transition smoothing
    private var pendingQualityChange: NetworkQuality?
    private var qualityTransitionTimer: Timer?
    private let transitionSmoothingDelay: TimeInterval = 2.0
    
    // MARK: - Initialization
    
    init() {
        setupNetworkMonitoring()
        setupQualityUpdateBinding()
    }
    
    deinit {
        monitor.cancel()
        stopBufferMonitoring()
        qualityTransitionTimer?.invalidate()
    }
    
    // MARK: - Public Interface
    
    /// Configure the manager with a new player item for seamless streaming
    func configurePlayerItem(_ playerItem: AVPlayerItem) {
        stopBufferMonitoring()
        self.playerItem = playerItem
        
        // Configure for adaptive streaming without interruptions
        setupAdaptiveStreamingProperties(for: playerItem)
        startBufferMonitoring(for: playerItem)
        
        // Apply current quality settings smoothly
        applyQualitySettings(currentQuality, to: playerItem, force: true)
    }
    
    /// Manually adjust quality (user override)
    func setManualQuality(_ quality: NetworkQuality) {
        guard let playerItem = playerItem else { return }
        
        isAdapting = true
        
        // Smooth transition to new quality
        applyQualitySettings(quality, to: playerItem, animated: true) { [weak self] in
            self?.currentQuality = quality
            self?.qualityDisplayText = quality.displayName
            self?.isAdapting = false
        }
    }
    
    /// Get optimal quality for current network conditions
    func getOptimalQuality() -> NetworkQuality {
        return determineOptimalQuality()
    }
    
    // MARK: - Network Monitoring
    
    private func setupNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkPathUpdate(path)
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    private func handleNetworkPathUpdate(_ path: NWPath) {
        let sample = NetworkSample(
            timestamp: Date(),
            isWiFi: path.usesInterfaceType(.wifi),
            isCellular: path.usesInterfaceType(.cellular),
            isConstrained: path.isConstrained,
            isExpensive: path.isExpensive,
            isConnected: path.status == .satisfied
        )
        
        addNetworkSample(sample)
        currentPath = path
        
        // Estimate bandwidth and adapt quality
        bandwidthEstimator.updateWithPath(path)
        adaptQualityIfNeeded()
    }
    
    private func addNetworkSample(_ sample: NetworkSample) {
        networkSamples.append(sample)
        if networkSamples.count > maxSamples {
            networkSamples.removeFirst()
        }
    }
    
    // MARK: - Quality Adaptation
    
    private func adaptQualityIfNeeded() {
        guard Date().timeIntervalSince(lastAdaptationTime) > adaptationThreshold else { return }
        guard playerItem != nil else { return }
        
        let optimalQuality = determineOptimalQuality()
        
        // Only adapt if there's a significant change needed
        if shouldAdaptToQuality(optimalQuality) {
            scheduleQualityTransition(to: optimalQuality)
        }
    }
    
    private func determineOptimalQuality() -> NetworkQuality {
        guard let currentPath = currentPath, currentPath.status == .satisfied else {
            return .low // Fallback for poor connectivity
        }
        
        // WiFi connections
        if currentPath.usesInterfaceType(.wifi) {
            let estimatedBandwidth = bandwidthEstimator.currentBandwidth
            
            if estimatedBandwidth > 500_000 { // > 500 kbps
                return .excellent
            } else if estimatedBandwidth > 300_000 { // > 300 kbps
                return .high
            } else {
                return .good
            }
        }
        
        // Cellular connections
        if currentPath.usesInterfaceType(.cellular) {
            if currentPath.isConstrained {
                return .low
            } else if currentPath.isExpensive {
                return .medium
            } else {
                return .good
            }
        }
        
        // Unknown connection type - conservative approach
        return .medium
    }
    
    private func shouldAdaptToQuality(_ quality: NetworkQuality) -> Bool {
        // Don't adapt if already at target quality
        if currentQuality == quality { return false }
        
        // Consider buffer health for adaptation decisions
        let bufferHealthThreshold: Double = 0.3
        
        // If buffer is healthy, we can adapt more aggressively
        if bufferHealth > bufferHealthThreshold {
            return true
        }
        
        // If buffer is poor, only downgrade quality
        return quality.rawValue < currentQuality.rawValue
    }
    
    private func scheduleQualityTransition(to quality: NetworkQuality) {
        // Cancel any pending transition
        qualityTransitionTimer?.invalidate()
        pendingQualityChange = quality
        
        // Smooth transition with delay to avoid rapid changes
        qualityTransitionTimer = Timer.scheduledTimer(withTimeInterval: transitionSmoothingDelay, repeats: false) { [weak self] _ in
            self?.executeQualityTransition()
        }
    }
    
    private func executeQualityTransition() {
        guard let targetQuality = pendingQualityChange,
              let playerItem = playerItem else { return }
        
        isAdapting = true
        lastAdaptationTime = Date()
        
        // Apply new quality settings seamlessly
        applyQualitySettings(targetQuality, to: playerItem, animated: true) { [weak self] in
            self?.currentQuality = targetQuality
            self?.qualityDisplayText = targetQuality.displayName
            self?.isAdapting = false
            self?.pendingQualityChange = nil
        }
    }
    
    // MARK: - Player Configuration
    
    private func setupAdaptiveStreamingProperties(for playerItem: AVPlayerItem) {
        // Configure for streaming optimization (iOS 10.0+)
        if #available(iOS 10.0, *) {
            playerItem.preferredForwardBufferDuration = currentQuality.bufferDuration
        }
        
        // Configure for live streaming optimization
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        
        // Set initial buffer preferences
        setBufferPreferences(for: playerItem, quality: currentQuality)
    }
    
    private func applyQualitySettings(_ quality: NetworkQuality, to playerItem: AVPlayerItem, force: Bool = false, animated: Bool = false, completion: (() -> Void)? = nil) {
        
        // Apply settings gradually to avoid interruptions
        let settingsApplication = {
            // Set preferred peak bitrate (advisory, not forced)
            if force || abs(playerItem.preferredPeakBitRate - quality.bitrate) > 32_000 {
                playerItem.preferredPeakBitRate = quality.bitrate
            }
            
            // Adjust buffer preferences
            self.setBufferPreferences(for: playerItem, quality: quality)
            
            // Update display
            self.qualityDisplayText = quality.displayName
        }
        
        if animated {
            // Smooth transition over time
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                settingsApplication()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    completion?()
                }
            }
        } else {
            settingsApplication()
            completion?()
        }
    }
    
    private func setBufferPreferences(for playerItem: AVPlayerItem, quality: NetworkQuality) {
        // Adjust buffer duration based on quality and network conditions
        playerItem.preferredForwardBufferDuration = quality.bufferDuration
        
        // Configure maximum buffer size to prevent excessive memory usage  
        _ = min(quality.bufferDuration * 2, 60.0)
        playerItem.preferredMaximumResolution = CGSize(width: 1920, height: 1080) // Audio only, but good to set
    }
    
    // MARK: - Buffer Monitoring
    
    private func startBufferMonitoring(for playerItem: AVPlayerItem) {
        // Monitor loaded time ranges for buffer health
        loadedTimeRangesObserver = playerItem.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            self?.updateBufferHealth(for: item)
        }
        
        // Periodic buffer health updates using Timer
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateBufferHealth(for: playerItem)
        }
        bufferObserver = timer
    }
    
    private func stopBufferMonitoring() {
        loadedTimeRangesObserver?.invalidate()
        loadedTimeRangesObserver = nil
        
        bufferObserver?.invalidate()
        bufferObserver = nil
    }
    
    private func updateBufferHealth(for playerItem: AVPlayerItem) {
        guard playerItem.status == .readyToPlay else {
            bufferHealth = 0.0
            return
        }
        
        let currentTime = playerItem.currentTime()
        let loadedRanges = playerItem.loadedTimeRanges
        
        var loadedDuration: TimeInterval = 0
        
        for timeRangeValue in loadedRanges {
            let timeRange = timeRangeValue.timeRangeValue
            let rangeStart = CMTimeGetSeconds(timeRange.start)
            let rangeDuration = CMTimeGetSeconds(timeRange.duration)
            let rangeEnd = rangeStart + rangeDuration
            let currentSeconds = CMTimeGetSeconds(currentTime)
            
            if rangeStart <= currentSeconds && rangeEnd > currentSeconds {
                loadedDuration = max(loadedDuration, rangeEnd - currentSeconds)
            }
        }
        
        // Calculate buffer health as a percentage of desired buffer
        let desiredBuffer = currentQuality.bufferDuration
        bufferHealth = min(1.0, loadedDuration / desiredBuffer)
    }
    
    // MARK: - UI Binding
    
    private func setupQualityUpdateBinding() {
        // Publish quality changes with smooth animations
        $currentQuality
            .removeDuplicates()
            .sink { [weak self] quality in
                self?.qualityDisplayText = quality.displayName
            }
            .store(in: &cancellables)
    }
}

// MARK: - Supporting Classes

/// Network sample for bandwidth estimation
private struct NetworkSample {
    let timestamp: Date
    let isWiFi: Bool
    let isCellular: Bool
    let isConstrained: Bool
    let isExpensive: Bool
    let isConnected: Bool
}

/// Estimates bandwidth based on network conditions and historical data
private class BandwidthEstimator {
    private var samples: [BandwidthSample] = []
    private let maxSamples = 20
    
    var currentBandwidth: Double {
        guard !samples.isEmpty else { return 128_000 } // Default
        
        // Weighted average with more recent samples having higher weight
        let weightedSum = samples.enumerated().reduce(0.0) { sum, item in
            let weight = Double(item.offset + 1) / Double(samples.count)
            return sum + item.element.bandwidth * weight
        }
        
        let totalWeight = samples.enumerated().reduce(0.0) { sum, item in
            return sum + Double(item.offset + 1) / Double(samples.count)
        }
        
        return weightedSum / totalWeight
    }
    
    func updateWithPath(_ path: NWPath) {
        let estimatedBandwidth = estimateBandwidthFromPath(path)
        
        let sample = BandwidthSample(
            timestamp: Date(),
            bandwidth: estimatedBandwidth
        )
        
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst()
        }
    }
    
    private func estimateBandwidthFromPath(_ path: NWPath) -> Double {
        if path.usesInterfaceType(.wifi) {
            return path.isConstrained ? 200_000 : 500_000
        } else if path.usesInterfaceType(.cellular) {
            if path.isConstrained {
                return 50_000
            } else if path.isExpensive {
                return 100_000
            } else {
                return 150_000
            }
        }
        return 100_000 // Default
    }
}

/// Bandwidth measurement sample
private struct BandwidthSample {
    let timestamp: Date
    let bandwidth: Double
} 