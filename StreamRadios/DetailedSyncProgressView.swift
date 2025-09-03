// DetailedSyncProgressView.swift
// StreamRadios
//
// Created by AI Assistant
//

import SwiftUI

struct DetailedSyncProgressView: View {
    @ObservedObject var syncManager = DataSyncManager.shared
    @Binding var isShowing: Bool
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    headerSection
                    
                    // Radio Stations Sync
                    if syncManager.radioStationsStatus != .none {
                        radioStationsSyncSection
                    }
                    
                    // Performance Metrics
                    if let syncState = SyncStateManager.shared.getRadioStationSyncState(),
                       let metadata = SyncStateManager.shared.getSyncMetadata() {
                        performanceSection(syncState: syncState, metadata: metadata)
                    }
                    
                    // Debug Information
                    debugSection
                }
                .padding()
            }
            .navigationTitle("Sync Progress")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                isShowing = false
            })
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 50))
                .foregroundColor(.blue)
            
            Text("CloudKit Synchronization")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Keeping your radio stations synced across all devices")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top)
    }
    
    private var radioStationsSyncSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "radio")
                    .foregroundColor(.blue)
                Text("Radio Stations")
                    .font(.headline)
                Spacer()
                syncStatusBadge(syncManager.radioStationsStatus)
            }
            
            // Progress Bar
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(syncManager.radioStationsOperation)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(Int(syncManager.radioStationsProgress * 100))%")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                }
                
                ProgressView(value: syncManager.radioStationsProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .scaleEffect(x: 1, y: 2, anchor: .center)
                
                HStack {
                    Text("\(syncManager.radioStationsCurrentCount) of \(syncManager.radioStationsTotalCount) stations")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if syncManager.radioStationsRemainingCount > 0 {
                        Text("\(syncManager.radioStationsRemainingCount) remaining")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Time Estimates
            if syncManager.radioStationsEstimatedTimeRemaining > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time Remaining")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatTimeInterval(syncManager.radioStationsEstimatedTimeRemaining))
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Average Speed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f stations/sec", 1.0 / syncManager.radioStationsAverageTimePerStation))
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private func performanceSection(syncState: SyncStateManager.RadioStationSyncState, metadata: SyncStateManager.SyncMetadata) -> some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "speedometer")
                    .foregroundColor(.green)
                Text("Performance Metrics")
                    .font(.headline)
                Spacer()
            }
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                metricCard(
                    title: "Sync Speed",
                    value: String(format: "%.2f/sec", metadata.syncSpeed),
                    icon: "bolt.fill",
                    color: .orange
                )
                
                metricCard(
                    title: "Avg per Station",
                    value: String(format: "%.2fs", metadata.averageTimePerStation),
                    icon: "timer",
                    color: .blue
                )
                
                metricCard(
                    title: "Success Rate",
                    value: String(format: "%.1f%%", (Double(syncState.processedStations.count) / Double(max(1, syncState.processedStations.count + syncState.failedStations.count))) * 100),
                    icon: "checkmark.circle.fill",
                    color: .green
                )
                
                metricCard(
                    title: "Failed",
                    value: "\(syncState.failedStations.count)",
                    icon: "xmark.circle.fill",
                    color: .red
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private var debugSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.gray)
                Text("Debug Information")
                    .font(.headline)
                Spacer()
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyncStateManager.shared.getDebugInfo())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    // MARK: - Helper Views
    
    private func syncStatusBadge(_ status: DataSyncStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon(for: status))
                .font(.caption)
            Text(statusText(for: status))
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor(for: status).opacity(0.2))
        .foregroundColor(statusColor(for: status))
        .cornerRadius(12)
    }
    
    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
    
    // MARK: - Helper Functions
    
    private func statusIcon(for status: DataSyncStatus) -> String {
        switch status {
        case .none:
            return "circle"
        case .pending:
            return "clock"
        case .inProgress:
            return "arrow.clockwise"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }
    
    private func statusText(for status: DataSyncStatus) -> String {
        switch status {
        case .none:
            return "Idle"
        case .pending:
            return "Pending"
        case .inProgress:
            return "Syncing"
        case .completed:
            return "Complete"
        case .failed:
            return "Failed"
        }
    }
    
    private func statusColor(for status: DataSyncStatus) -> Color {
        switch status {
        case .none:
            return .gray
        case .pending:
            return .orange
        case .inProgress:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
    
    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.0fs", interval)
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        } else {
            let hours = Int(interval / 3600)
            let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}

struct DetailedSyncProgressView_Previews: PreviewProvider {
    static var previews: some View {
        DetailedSyncProgressView(isShowing: .constant(true))
    }
}
