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
                        .font(.system(size: 60))
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
                    
                    // Individual sync status items
                    VStack(spacing: 12) {
                        SyncStatusItem(
                            title: "Radio Stations",
                            status: syncManager.radioStationsStatus,
                            progress: syncManager.radioStationsProgress
                        )
                        
                        SyncStatusItem(
                            title: "Podcast Feeds",
                            status: syncManager.podcastFeedsStatus,
                            progress: syncManager.podcastFeedsProgress
                        )
                        
                        SyncStatusItem(
                            title: "Artwork Downloads",
                            status: syncManager.artworkDownloadsStatus,
                            progress: syncManager.artworkDownloadsProgress
                        )
                        
                        SyncStatusItem(
                            title: "Episode States",
                            status: syncManager.episodeStatesStatus,
                            progress: syncManager.episodeStatesProgress
                        )
                        
                        SyncStatusItem(
                            title: "User Preferences",
                            status: syncManager.userPreferencesStatus,
                            progress: syncManager.userPreferencesProgress
                        )
                    }
                    .padding(.vertical, 8)
                    
                    // Current operation status
                    if !syncManager.currentOperation.isEmpty {
                        Text(syncManager.currentOperation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
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
}

struct SyncStatusItem: View {
    let title: String
    let status: DataSyncStatus
    let progress: Double
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .font(.system(size: 16))
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