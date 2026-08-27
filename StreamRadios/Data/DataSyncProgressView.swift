import SwiftUI
import Combine

// MARK: - Sync Status

enum DataSyncStatus {
    case none
    case pending
    case inProgress
    case completed
    case failed
}

// MARK: - Stage model

private struct SyncStage: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let status: DataSyncStatus
    let progress: Double
    let current: Int
    let total: Int

    var isActive: Bool { status == .inProgress }

    /// Only the active stage shows numbers, so the eye has one moving target instead of six.
    var detail: String {
        switch status {
        case .inProgress:
            if total > 0 {
                return "\(current.formatted(.number)) of \(total.formatted(.number))"
            }
            return "\(Int(progress * 100))%"
        case .failed:
            return "Failed"
        default:
            return ""
        }
    }
}

// MARK: - Progress overlay

struct DataSyncProgressView: View {
    @StateObject private var syncManager = DataSyncManager.shared
    @State private var appeared = false
    @State private var sweep = false
    @State private var detailLine = ""

    /// The manager republishes many times a second; sampling keeps the caption from strobing.
    private let detailTick = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        if syncManager.isSyncing && !syncManager.isFreshInstallUIReady {
            ZStack {
                backdrop

                VStack(spacing: 26) {
                    progressRing

                    VStack(spacing: 6) {
                        Text("Setting Up Your App")
                            .font(.title2.weight(.semibold))

                        Text(headline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.25), value: headline)
                    }
                    .multilineTextAlignment(.center)

                    stageList

                    captionLine

                    Text("Keep StreamRadios open until this finishes.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 30)
                .frame(maxWidth: 420)
                .glassEffect(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .padding(.horizontal, 20)
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
            }
            .onAppear {
                sweep = true
                detailLine = liveDetail
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
            }
            .onDisappear {
                appeared = false
                sweep = false
            }
            .onReceive(detailTick) { _ in
                let next = liveDetail
                guard next != detailLine else { return }
                withAnimation(.easeInOut(duration: 0.25)) { detailLine = next }
            }
        }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [.blue.opacity(0.25), .clear, .purple.opacity(0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Ring

    private var percent: Int { Int((syncManager.overallProgress * 100).rounded()) }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 12)

            Circle()
                .trim(from: 0, to: max(0.001, min(1, syncManager.overallProgress)))
                .stroke(
                    AngularGradient(colors: [.blue, .purple, .pink, .blue], center: .center),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.6), value: syncManager.overallProgress)

            // Slow sweep so the ring still reads as "working" while a stage sits at a fixed percentage.
            Circle()
                .trim(from: 0, to: 0.08)
                .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(sweep ? 270 : -90))
                .blur(radius: 6)
                .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: sweep)

            Text("\(percent)%")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(percent)))
                .animation(.snappy, value: percent)
        }
        .frame(width: 148, height: 148)
    }

    // MARK: Stage list

    private var stageList: some View {
        VStack(spacing: 2) {
            ForEach(stages) { stage in
                SyncStageRow(stage: stage)
            }
        }
    }

    private var captionLine: some View {
        Text(detailLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 18)
            .transition(.opacity)
    }

    // MARK: Derived state

    private var stages: [SyncStage] {
        let snapshotTotal = syncManager.totalCountriesRequiringSnapshots
        return [
            SyncStage(
                id: "stations",
                title: "Radio Stations",
                icon: "antenna.radiowaves.left.and.right",
                status: syncManager.radioStationsStatus,
                progress: syncManager.radioStationsProgress,
                current: syncManager.radioStationsCurrentCount,
                total: syncManager.radioStationsTotalCount
            ),
            SyncStage(
                id: "feeds",
                title: "Podcast Feeds",
                icon: "mic.circle",
                status: syncManager.podcastFeedsStatus,
                progress: syncManager.podcastFeedsProgress,
                current: syncManager.podcastFeedsCurrentCount,
                total: syncManager.podcastFeedsTotalCount
            ),
            SyncStage(
                id: "artwork",
                title: "Artwork",
                icon: "photo.on.rectangle.angled",
                status: syncManager.artworkDownloadsStatus,
                progress: syncManager.artworkDownloadsProgress,
                current: syncManager.artworkDownloadsCurrentCount,
                total: syncManager.artworkDownloadsTotalCount
            ),
            SyncStage(
                id: "episodes",
                title: "Episode Progress",
                icon: "clock.arrow.circlepath",
                status: syncManager.episodeStatesStatus,
                progress: syncManager.episodeStatesProgress,
                current: syncManager.feedsLoadedFromCoreData,
                total: syncManager.totalFeedsInCoreData > 0 ? syncManager.totalFeedsInCoreData : syncManager.episodeStatesTotalCount
            ),
            SyncStage(
                id: "countries",
                title: "Station Library",
                icon: "globe",
                status: syncManager.stationSnapshotsReady ? .completed : (snapshotTotal > 0 ? .inProgress : .pending),
                progress: snapshotTotal > 0 ? Double(syncManager.countriesWithSnapshots) / Double(snapshotTotal) : 0,
                current: syncManager.countriesWithSnapshots,
                total: snapshotTotal
            ),
            SyncStage(
                id: "preferences",
                title: "Preferences",
                icon: "slider.horizontal.3",
                status: syncManager.userPreferencesStatus,
                progress: syncManager.userPreferencesProgress,
                current: 0,
                total: 0
            )
        ]
    }

    private var headline: String {
        if let active = stages.first(where: { $0.isActive }) {
            return "Syncing \(active.title.lowercased())…"
        }
        if stages.contains(where: { $0.status == .failed }) {
            return "Some items couldn't be synced"
        }
        return "Almost done…"
    }

    /// Raw per-item chatter, surfaced one line at a time rather than under every row.
    private var liveDetail: String {
        if syncManager.isParsingFeeds, !syncManager.feedParsingMessage.isEmpty {
            return syncManager.feedParsingMessage
        }
        if syncManager.isReceivingCrossDeviceProgress,
           let feed = syncManager.crossDeviceFeedProgress.values.first {
            return feed.message.isEmpty ? feed.feedTitle : feed.message
        }
        let operations: [(DataSyncStatus, String)] = [
            (syncManager.radioStationsStatus, syncManager.radioStationsOperation),
            (syncManager.podcastFeedsStatus, syncManager.podcastFeedsOperation),
            (syncManager.artworkDownloadsStatus, syncManager.artworkDownloadsOperation),
            (syncManager.episodeStatesStatus, syncManager.episodeStatesOperation),
            (syncManager.userPreferencesStatus, syncManager.userPreferencesOperation)
        ]
        return operations.first { $0.0 == .inProgress && !$0.1.isEmpty }?.1 ?? ""
    }
}

// MARK: - Stage row

private struct SyncStageRow: View {
    let stage: SyncStage

    var body: some View {
        HStack(spacing: 12) {
            glyph
                .frame(width: 22, height: 22)

            Text(stage.title)
                .font(.subheadline.weight(stage.isActive ? .semibold : .regular))
                .foregroundStyle(stage.isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(stage.detail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(fillTrack)
        .opacity(stage.status == .pending ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.3), value: stage.status)
    }

    /// The row itself is the progress bar — no separate bar per stage.
    @ViewBuilder
    private var fillTrack: some View {
        if stage.isActive {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(
                            LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.45)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width * max(0, min(1, stage.progress)))
                        .animation(.smooth(duration: 0.5), value: stage.progress)
                }
            }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch stage.status {
        case .completed, .none:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .pending:
            Image(systemName: stage.icon)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Preview

#Preview {
    DataSyncProgressView()
        .preferredColorScheme(.dark)
}
