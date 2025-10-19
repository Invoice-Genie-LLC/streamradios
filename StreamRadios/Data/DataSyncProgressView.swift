import SwiftUI
import Combine

/// Clean, modern data sync progress view for fresh install setup
struct DataSyncProgressView: View {
    @StateObject private var syncManager = DataSyncManager.shared
    @State private var isVisible = false
    @State private var animateIcon = false
    
    var body: some View {
        if shouldShowProgressView {
            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                
                // Main content card
                VStack(spacing: 20) {
                    headerSection
                    overallProgressSection
                    syncItemsSection
                    activeOperationSection
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 10)
                )
                .padding(.horizontal, 40)
                .scaleEffect(isVisible ? 1.0 : 0.9)
                .opacity(isVisible ? 1.0 : 0.0)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isVisible)
            .onAppear { 
                isVisible = true
                animateIcon = true
            }
            .onDisappear { 
                isVisible = false
                animateIcon = false
            }
        }
    }
}

// MARK: - View Components

extension DataSyncProgressView {
    
    /// Determines if the progress view should be shown
    private var shouldShowProgressView: Bool {
        syncManager.isSyncing && !syncManager.isFreshInstallUIReady
    }
    
    /// Header section with app icon and title
    private var headerSection: some View {
        VStack(spacing: 12) {
            // Animated sync icon
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.blue.gradient)
                .rotationEffect(.degrees(animateIcon ? 360 : 0))
                .animation(
                    .linear(duration: 2.0).repeatForever(autoreverses: false),
                    value: animateIcon
                )
            
            VStack(spacing: 4) {
                Text("Setting Up Your App")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("Syncing your data from iCloud...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    /// Overall progress section
    private var overallProgressSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Overall Progress")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(Int(syncManager.overallProgress * 100))%")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            
            ModernProgressBar(progress: syncManager.overallProgress)
                .frame(height: 6)
        }
    }
    
    /// All sync items section
    private var syncItemsSection: some View {
        VStack(spacing: 12) {
            // Core sync items
            SyncItem(
                title: "Radio Stations",
                icon: "radio",
                status: syncManager.radioStationsStatus,
                progress: syncManager.radioStationsProgress,
                operation: syncManager.radioStationsOperation,
                currentCount: syncManager.radioStationsCurrentCount,
                totalCount: syncManager.radioStationsTotalCount
            )
            
            SyncItem(
                title: "Podcast Feeds",
                icon: "podcast",
                status: syncManager.podcastFeedsStatus,
                progress: syncManager.podcastFeedsProgress,
                operation: syncManager.podcastFeedsOperation,
                currentCount: syncManager.podcastFeedsCurrentCount,
                totalCount: syncManager.podcastFeedsTotalCount
            )
            
            SyncItem(
                title: "Episode States",
                icon: "doc.text",
                status: syncManager.episodeStatesStatus,
                progress: syncManager.episodeStatesProgress,
                operation: syncManager.episodeStatesOperation,
                currentCount: syncManager.feedsWithSnapshots,
                totalCount: max(syncManager.totalFeedsRequiringSnapshots, syncManager.episodeStatesTotalCount)
            )
            
            SyncItem(
                title: "Station Snapshots",
                icon: "photo.stack",
                status: syncManager.stationSnapshotsReady ? .completed : .pending,
                progress: calculateSnapshotProgress(),
                operation: getSnapshotOperation(),
                currentCount: syncManager.countriesWithSnapshots,
                totalCount: syncManager.totalCountriesRequiringSnapshots
            )
            
            SyncItem(
                title: "Artwork Downloads",
                icon: "photo",
                status: syncManager.artworkDownloadsStatus,
                progress: syncManager.artworkDownloadsProgress,
                operation: syncManager.artworkDownloadsOperation,
                currentCount: syncManager.artworkDownloadsCurrentCount,
                totalCount: syncManager.artworkDownloadsTotalCount
            )
            
            SyncItem(
                title: "User Preferences",
                icon: "gear",
                status: syncManager.userPreferencesStatus,
                progress: syncManager.userPreferencesProgress,
                operation: syncManager.userPreferencesOperation
            )
            
            // Dynamic items
            if syncManager.isParsingFeeds {
                FeedParsingItem(
                    progress: syncManager.feedParsingProgress,
                    message: syncManager.feedParsingMessage
                )
            }
            
            if syncManager.isReceivingCrossDeviceProgress {
                CrossDeviceItem(feedProgress: Array(syncManager.crossDeviceFeedProgress.values).first)
            }
        }
    }
    
    /// Active operation section
    private var activeOperationSection: some View {
        Group {
            if let activeOp = getActiveOperation(), !activeOp.isEmpty {
                Text(activeOp)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            }
        }
    }
}

// MARK: - Helper Methods

extension DataSyncProgressView {
    
    private func calculateSnapshotProgress() -> Double {
        guard syncManager.totalCountriesRequiringSnapshots > 0 else { return 0.0 }
        return Double(syncManager.countriesWithSnapshots) / Double(syncManager.totalCountriesRequiringSnapshots)
    }
    
    private func getSnapshotOperation() -> String {
        if syncManager.totalCountriesRequiringSnapshots > 0 {
            return "Creating snapshots for \(syncManager.totalCountriesRequiringSnapshots) countries..."
        }
        return "Preparing station snapshots..."
    }
    
    private func getActiveOperation() -> String? {
        let operations = [
            (syncManager.radioStationsStatus, syncManager.radioStationsOperation),
            (syncManager.podcastFeedsStatus, syncManager.podcastFeedsOperation),
            (syncManager.episodeStatesStatus, syncManager.episodeStatesOperation),
            (syncManager.artworkDownloadsStatus, syncManager.artworkDownloadsOperation),
            (syncManager.userPreferencesStatus, syncManager.userPreferencesOperation)
        ]
        
        return operations
            .first { $0.0 == .inProgress && !$0.1.isEmpty }?
            .1
    }
}

// MARK: - Supporting Views

/// Modern progress bar with gradient fill
struct ModernProgressBar: View {
    let progress: Double
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                
                // Progress fill with gradient
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * max(0, min(1, progress)))
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
    }
}

/// Individual sync item component
struct SyncItem: View {
    let title: String
    let icon: String
    let status: DataSyncStatus
    let progress: Double
    let operation: String
    let currentCount: Int?
    let totalCount: Int?
    
    init(title: String, icon: String, status: DataSyncStatus, progress: Double, operation: String = "", currentCount: Int? = nil, totalCount: Int? = nil) {
        self.title = title
        self.icon = icon
        self.status = status
        self.progress = progress
        self.operation = operation
        self.currentCount = currentCount
        self.totalCount = totalCount
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Header row
            HStack(spacing: 12) {
                // Icon
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 20)
                
                // Title
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Count badge
                if let current = currentCount, let total = totalCount, total > 0 {
                    Text("\(current)/\(total)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                
                // Status indicator
                statusIndicator
            }
            
            // Progress bar (only show when in progress)
            if status == .inProgress {
                ModernProgressBar(progress: progress)
                    .frame(height: 3)
            }
            
            // Operation text (only show when not empty)
            if !operation.isEmpty {
                Text(operation)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var iconColor: Color {
        switch status {
        case .completed: return .green
        case .inProgress: return .blue
        case .failed: return .red
        default: return .secondary
        }
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .none, .pending:
            Text("Pending")
                .font(.caption2)
                .foregroundColor(.secondary)
                
        case .inProgress:
            HStack(spacing: 4) {
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .fontWeight(.medium)
                
                ProgressView()
                    .scaleEffect(0.7)
            }
            
        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
                
                Text("Done")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.green)
            }
            
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundColor(.red)
                
                Text("Error")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.red)
            }
        }
    }
}

/// Feed parsing progress item
struct FeedParsingItem: View {
    let progress: Double
    let message: String
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.orange)
                    .frame(width: 20)
                
                Text("Feed Parsing")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            
            ModernProgressBar(progress: progress)
                .frame(height: 3)
            
            if !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Cross-device sync progress item
struct CrossDeviceItem: View {
    let feedProgress: CrossDeviceFeedProgress?
    
    var body: some View {
        if let progress = feedProgress {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.purple)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cross-Device Sync")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text(progress.feedTitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    Text("\(Int(progress.progress * 100))%")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }
                
                ModernProgressBar(progress: progress.progress)
                    .frame(height: 3)
                
                Text(progress.message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Data Types

enum DataSyncStatus {
    case none
    case pending
    case inProgress
    case completed
    case failed
}

// MARK: - Preview

struct DataSyncProgressView_Previews: PreviewProvider {
    static var previews: some View {
        DataSyncProgressView()
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode")
        
        DataSyncProgressView()
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")
    }
} 