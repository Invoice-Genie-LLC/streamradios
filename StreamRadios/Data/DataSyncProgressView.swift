import SwiftUI
import Combine

struct DataSyncProgressView: View {
    @StateObject private var syncManager = DataSyncManager.shared
    @State private var isVisible = false
    @State private var animateProgress = false
    
    var body: some View {
        if syncManager.isSyncing {
            ZStack {
                // Background overlay
                Color.black.opacity(0.4)
                    .ignoresSafeArea(.all)
                
                // Main progress container
                VStack(spacing: 24) {
                    // App icon or logo
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.blue)
                        .rotationEffect(.degrees(animateProgress ? 360 : 0))
                        .animation(
                            Animation.linear(duration: 2.0)
                                .repeatForever(autoreverses: false),
                            value: animateProgress
                        )
                    
                    VStack(spacing: 16) {
                        // Title
                        Text("Setting Up Your App")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("Syncing your data from iCloud...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    // Overall progress bar
                    VStack(spacing: 8) {
                        HStack {
                            Text("Overall Progress")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(syncManager.overallProgress * 100))%")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                        
                        ProgressView(value: syncManager.overallProgress)
                            .progressViewStyle(CustomProgressViewStyle())
                            .frame(height: 12)
                    }
                    
                    // Individual sync status items with detailed progress
                    VStack(spacing: 12) {
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
                            title: "Episode States",
                            status: syncManager.episodeStatesStatus,
                            progress: syncManager.episodeStatesProgress,
                            operation: syncManager.episodeStatesOperation,
                            currentCount: syncManager.episodeStatesCurrentCount,
                            totalCount: syncManager.episodeStatesTotalCount
                        )
                        
                        SyncStatusItem(
                            title: "User Preferences",
                            status: syncManager.userPreferencesStatus,
                            progress: syncManager.userPreferencesProgress
                        )
                        
                        // Show feed parsing progress if active
                        if syncManager.isParsingFeeds {
                            FeedParsingProgressItem(
                                progress: syncManager.feedParsingProgress,
                                message: syncManager.feedParsingMessage
                            )
                        }
                        
                        // Show cross-device progress for feeds being synced on other devices
                        if syncManager.isReceivingCrossDeviceProgress {
                            ForEach(Array(syncManager.crossDeviceFeedProgress.values), id: \.feedId) { feedProgress in
                                CrossDeviceFeedProgressItem(feedProgress: feedProgress)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    
                    // Overall sync status - show most active operation
                    if syncManager.isSyncing {
                        let activeOperation = getActiveOperation()
                        if !activeOperation.isEmpty {
                            Text(activeOperation)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(32)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.regularMaterial)
                        .shadow(radius: 10)
                )
                .padding(.horizontal, 24)
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
            
            // Progress bar for in-progress items
            if status == .inProgress {
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .frame(height: 4)
            }
            
            // Operation description
            if !operation.isEmpty {
                HStack {
                    Text(operation)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
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