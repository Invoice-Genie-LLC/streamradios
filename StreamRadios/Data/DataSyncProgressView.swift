import SwiftUI
import Combine

struct DataSyncProgressView: View {
    @StateObject private var syncManager = DataSyncManager.shared
    @State private var isVisible = false
    @State private var animateProgress = false
    
    var body: some View {
        // Debug logging for sync states
        let _ = print("🎭 DataSyncProgressView: isSyncing=\(syncManager.isSyncing), isFreshInstallUIReady=\(syncManager.isFreshInstallUIReady)")
        
        if syncManager.isSyncing && !syncManager.isFreshInstallUIReady {
            ZStack {
                // Background overlay
                Color.black.opacity(0.4)
                    .ignoresSafeArea(.all)
                
                // Main progress container with reduced height
                VStack(spacing: 16) {
                    // App icon or logo (smaller)
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.title)
                        .foregroundColor(.blue)
                        .rotationEffect(.degrees(animateProgress ? 360 : 0))
                        .animation(
                            Animation.linear(duration: 2.0)
                                .repeatForever(autoreverses: false),
                            value: animateProgress
                        )
                    
                    VStack(spacing: 8) {
                        // Title (smaller)
                        Text("Setting Up Your App")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("Syncing your data from iCloud...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    // User guidance section
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.blue)
                            
                            Text("Please Wait")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Keep the app open during sync")
                            Text("• Don't close or switch apps")
                            Text("• Sync time depends on your feed count")
                            Text("• Large collections may take several minutes")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                    )
                    
                    // Overall progress bar (more compact)
                    VStack(spacing: 4) {
                        HStack {
                            Text("Overall Progress")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(syncManager.overallProgress * 100))%")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                        
                        ProgressView(value: syncManager.overallProgress)
                            .progressViewStyle(CustomProgressViewStyle())
                            .frame(height: 8)
                    }
                    
                    // Individual sync status items with detailed progress - FIXED HEIGHT CONTAINER (more compact)
                    VStack(spacing: 8) {
                        DetailedSyncStatusItem(
                            title: "Radio Stations",
                            status: syncManager.radioStationsStatus,
                            progress: syncManager.radioStationsProgress,
                            operation: syncManager.radioStationsOperation,
                            currentCount: syncManager.radioStationsCurrentCount,
                            totalCount: syncManager.radioStationsTotalCount
                        )
                        
                        DetailedSyncStatusItem(
                            title: "Podcast Feeds",
                            status: syncManager.podcastFeedsStatus,
                            progress: syncManager.podcastFeedsProgress,
                            operation: syncManager.podcastFeedsOperation,
                            currentCount: syncManager.podcastFeedsCurrentCount,
                            totalCount: syncManager.podcastFeedsTotalCount
                        )
                        
                        DetailedSyncStatusItem(
                            title: "Artwork Downloads",
                            status: syncManager.artworkDownloadsStatus,
                            progress: syncManager.artworkDownloadsProgress,
                            operation: syncManager.artworkDownloadsOperation,
                            currentCount: syncManager.artworkDownloadsCurrentCount,
                            totalCount: syncManager.artworkDownloadsTotalCount
                        )
                        
                        DetailedSyncStatusItem(
                            title: "Episode Progress Sync",
                            status: syncManager.episodeStatesStatus,
                            progress: syncManager.episodeStatesProgress,
                            operation: syncManager.episodeStatesOperation,
                            currentCount: syncManager.feedsLoadedFromCoreData,
                            totalCount: syncManager.totalFeedsInCoreData > 0 ? syncManager.totalFeedsInCoreData : syncManager.episodeStatesTotalCount
                        )
                        
                        DetailedSyncStatusItem(
                            title: "Radio Stations Sync",
                            status: syncManager.stationSnapshotsReady ? .completed : .pending,
                            progress: syncManager.totalCountriesRequiringSnapshots > 0 ? Double(syncManager.countriesWithSnapshots) / Double(syncManager.totalCountriesRequiringSnapshots) : 0.0,
                            operation: syncManager.totalCountriesRequiringSnapshots > 0 ? "Syncing stations for \(syncManager.totalCountriesRequiringSnapshots) countries..." : "Preparing station syncing...",
                            currentCount: syncManager.countriesWithSnapshots,
                            totalCount: syncManager.totalCountriesRequiringSnapshots
                        )
                        
                        SyncStatusItem(
                            title: "User Preferences",
                            status: syncManager.userPreferencesStatus,
                            progress: syncManager.userPreferencesProgress
                        )
                        
                        // FIXED HEIGHT: Compact feed parsing progress (reduced height)
                        Group {
                            if syncManager.isParsingFeeds {
                                FeedParsingProgressItem(
                                    progress: syncManager.feedParsingProgress,
                                    message: syncManager.feedParsingMessage
                                )
                                .scaleEffect(0.85)
                            } else {
                                // Invisible placeholder with minimal height
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(height: 1)
                                    .opacity(0)
                            }
                        }
                        .frame(height: 32) // Reduced height for feed parsing section
                        
                        // FIXED HEIGHT: Compact cross-device progress (reduced to 1 item max)
                        Group {
                            if syncManager.isReceivingCrossDeviceProgress {
                                let feedProgressItems = Array(syncManager.crossDeviceFeedProgress.values)
                                if !feedProgressItems.isEmpty {
                                    CrossDeviceFeedProgressItem(feedProgress: feedProgressItems[0])
                                        .scaleEffect(0.85)
                                } else {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .frame(height: 1)
                                        .opacity(0)
                                }
                            } else {
                                // Minimal invisible placeholder
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(height: 1)
                                    .opacity(0)
                            }
                        }
                        .frame(height: 40) // Reduced height for cross-device section (1 item max)
                    }
                    .padding(.vertical, 4)
                    
                    // FIXED HEIGHT: Compact active operation text
                    Group {
                        if syncManager.isSyncing {
                            let activeOperation = getActiveOperation()
                            if !activeOperation.isEmpty {
                                Text(activeOperation)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 12)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else {
                                // Minimal invisible placeholder
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(height: 1)
                                    .opacity(0)
                            }
                        } else {
                            // Minimal invisible placeholder
                            Rectangle()
                                .fill(Color.clear)
                                .frame(height: 1)
                                .opacity(0)
                        }
                    }
                    .frame(minHeight: 16, maxHeight: 32) // Allow text expansion for longer messages
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.regularMaterial)
                        .shadow(radius: 8)
                )
                .padding(.horizontal, 32)
                .scaleEffect(isVisible ? 1.0 : 0.8)
                .opacity(isVisible ? 1.0 : 0.0)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: isVisible)
            }
            .onAppear {
                isVisible = true
                animateProgress = true
            }
            .onDisappear {
                isVisible = false
                animateProgress = false
            }
        }
    }
    
    private func getActiveOperation() -> String {
        // Return the most relevant active operation message
        if syncManager.radioStationsStatus == .inProgress && !syncManager.radioStationsOperation.isEmpty {
            return syncManager.radioStationsOperation
        } else if syncManager.podcastFeedsStatus == .inProgress && !syncManager.podcastFeedsOperation.isEmpty {
            return syncManager.podcastFeedsOperation
        } else if syncManager.episodeStatesStatus == .inProgress && !syncManager.episodeStatesOperation.isEmpty {
            return syncManager.episodeStatesOperation
        } else if syncManager.artworkDownloadsStatus == .inProgress && !syncManager.artworkDownloadsOperation.isEmpty {
            return syncManager.artworkDownloadsOperation
        } else if syncManager.userPreferencesStatus == .inProgress && !syncManager.userPreferencesOperation.isEmpty {
            return syncManager.userPreferencesOperation
        }
        return ""
    }
}

// MARK: - Feed Parsing Progress Item

struct FeedParsingProgressItem: View {
    let progress: Double
    let message: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(.blue)
                    .font(.subheadline)
                    .frame(width: 20)
                
                Text("Feed Parsing")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            
            // Progress bar
            ProgressView(value: progress)
                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                .frame(height: 4)
            
            // Parsing message
            if !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.1))
        )
    }
}

struct DetailedSyncStatusItem: View {
    let title: String
    let status: DataSyncStatus
    let progress: Double
    let operation: String
    let currentCount: Int
    let totalCount: Int
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Status icon
                statusIcon
                    .font(.body)
                    .frame(width: 20)
                
                // Title
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Count indicator
                if totalCount > 0 {
                    Text("\(currentCount)/\(totalCount)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
                
                // Progress indicator
                Group {
                    switch status {
                    case .none:
                        Text("Ready")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .pending:
                        Text("Pending")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .inProgress:
                        HStack(spacing: 4) {
                            Text("\(Int(progress * 100))%")
                                .font(.caption)
                                .fontWeight(.medium)
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                    case .completed:
                        Text("Done")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                    case .failed:
                        Text("Error")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                    }
                }
            }
            
            // FIXED HEIGHT: Progress bar (always reserve space)
            Group {
                if status == .inProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        .frame(height: 4)
                } else {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 4)
                        .opacity(0)
                }
            }
            
            // FIXED HEIGHT: Operation description (always reserve space)
            Group {
                if !operation.isEmpty {
                    Text(operation)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 16)
                        .opacity(0)
                }
            }
            .frame(minHeight: 16, maxHeight: 32)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .none:
            Image(systemName: "checkmark.circle")
                .foregroundColor(.green)
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .inProgress:
            Image(systemName: "arrow.2.circlepath")
                .foregroundColor(.blue)
                .rotationEffect(.degrees(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 2) * 180))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: status)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }
}

struct SyncStatusItem: View {
    let title: String
    let status: DataSyncStatus
    let progress: Double
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .font(.body)
                .frame(width: 20)
            
            // Title
            Text(title)
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Spacer()
            
            // Progress indicator
            Group {
                                switch status {
                    case .none:
                        Text("Ready")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .pending:
                    Text("Pending")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .inProgress:
                    HStack(spacing: 4) {
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .fontWeight(.medium)
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                case .completed:
                    Text("Done")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                case .failed:
                    Text("Error")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.horizontal, 4)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .none:
            Image(systemName: "checkmark.circle")
                .foregroundColor(.green)
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .inProgress:
            Image(systemName: "arrow.2.circlepath")
                .foregroundColor(.blue)
                .rotationEffect(.degrees(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 2) * 180))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: status)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }
}

struct CustomProgressViewStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
                
                // Progress fill
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                    .animation(.easeInOut(duration: 0.3), value: configuration.fractionCompleted)
            }
        }
    }
}

enum DataSyncStatus {
    case none
    case pending
    case inProgress
    case completed
    case failed
}

// MARK: - Cross-Device Progress Item

struct CrossDeviceFeedProgressItem: View {
    let feedProgress: CrossDeviceFeedProgress
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundColor(.purple)
                    .font(.subheadline)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("📡 Cross-Device Sync")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text(feedProgress.feedTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text("\(Int(feedProgress.progress * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            
            ProgressView(value: feedProgress.progress)
                .progressViewStyle(LinearProgressViewStyle(tint: .purple))
                .frame(height: 6)
                .cornerRadius(3)
            
            Text(feedProgress.message)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.purple.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.purple.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Preview
struct DataSyncProgressView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Light mode preview
            DataSyncProgressView()
                .preferredColorScheme(.light)
                .previewDisplayName("Light Mode")
            
            // Dark mode preview
            DataSyncProgressView()
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark Mode")
        }
    }
} 
