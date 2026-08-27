//  SRRadioListView.swift
//  StreamRadios
//
//  Redesigned radio list. Ships behind SRFeature.newRadioList.

import CoreData
import FlagKit
import StreamRadiosKit
import SwiftUI

/// Drop-in replacement for `RadioStationListView` with the same external surface.
///
/// The list is driven straight off Core Data instead of filtering/sorting `viewModel.stations`
/// in the view body, so filtering happens in SQLite against the indexed `searchText` column and
/// only the visible batch of rows is ever materialised.
struct SRRadioListView: View {
    @Binding var isEditing: Bool
    @Binding var selectedStationForEdit: RadioStation?
    @Binding var selectedTab: Tab
    @Binding var selectedSubTab: RadioSubTab
    @Binding var activeSheet: ActiveSheet?
    @Binding var isPlayerSheetPresented: Bool
    @Binding var searchText: String
    @Binding var isScrolling: Bool
    @Binding var isFooterMenuHidden: Bool
    @Binding var isSearchPresented: Bool

    var body: some View {
        SRRadioListContent(
            isEditing: $isEditing,
            selectedStationForEdit: $selectedStationForEdit,
            selectedTab: $selectedTab,
            selectedSubTab: $selectedSubTab,
            activeSheet: $activeSheet,
            isPlayerSheetPresented: $isPlayerSheetPresented,
            searchText: $searchText,
            isScrolling: $isScrolling,
            isFooterMenuHidden: $isFooterMenuHidden,
            isSearchPresented: $isSearchPresented
        )
        // @FetchRequest resolves its context from the environment.
        .environment(\.managedObjectContext, CoreDataStack.shared.context)
    }
}

private struct SRRadioListContent: View {
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var radioPlayer: RadioPlayer

    @Binding var isEditing: Bool
    @Binding var selectedStationForEdit: RadioStation?
    @Binding var selectedTab: Tab
    @Binding var selectedSubTab: RadioSubTab
    @Binding var activeSheet: ActiveSheet?
    @Binding var isPlayerSheetPresented: Bool
    @Binding var searchText: String
    @Binding var isScrolling: Bool
    @Binding var isFooterMenuHidden: Bool
    @Binding var isSearchPresented: Bool

    // Driven by an immutable snapshot rather than `@FetchRequest`. SwiftUI walks the whole
    // collection on every body pass, and touching a `CDStation` faults in all of its columns —
    // including the base64 favicon — so a live fetch re-materialises every station's artwork
    // blob dozens of times per second while scrolling.
    @State private var rows: [SRStationRowModel] = []
    @State private var rowsVersion = 0
    @State private var hasLoaded = false
    @State private var reloadTask: Task<Void, Never>?

    @StateObject private var alertManager = AlertManager()
    @AppStorage("hiddenCountries") private var hiddenCountriesData: Data = Data()
    @State private var hiddenCountries: Set<String> = []

    @State private var showDeleteAlert = false
    @State private var stationToDelete: RadioStation?
    @State private var showEditPlayingAlert = false
    @State private var showDeletePlayingAlert = false
    @State private var showFavoriteError = false
    @State private var showingCountryPicker = false
    @State private var isOffline = false
    @State private var scrollTargetId: String?

    private var nowPlaying: SRNowPlaying? { NowPlayingCenter.shared.current }
    private var trimmedQuery: String { SRSearchNormalizer.query(searchText) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }

    var body: some View {
        ZStack {
            Group {
                if viewModel.isLoading {
                    StylishLoaderView(
                        title: "Loading Stations",
                        phase: viewModel.loadingPhase,
                        progress: viewModel.loadingProgress,
                        current: viewModel.loadingStationsCount,
                        total: viewModel.totalStationsToLoad
                    )
                } else if !rows.isEmpty {
                    listBody
                } else if hasLoaded {
                    emptyState
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.adaptiveBackground)
            // An inset rather than an overlay, so the list keeps the first row reachable.
            .safeAreaInset(edge: .top, spacing: 0) {
                if isEditing && selectedSubTab == .favorites {
                    reorderHeader
                }
            }

            if alertManager.showCustomAlert {
                CustomAlertContainer()
                    .environmentObject(alertManager)
            }
        }
        .onAppear {
            loadHiddenCountries()
            isOffline = !ReachabilityCheck.isConnectedToNetwork()
            scheduleReload()
        }
        .onChange(of: selectedSubTab) { _, newValue in
            if isEditing && newValue != .favorites { isEditing = false }
            scheduleReload()
        }
        .onChange(of: searchText) { _, _ in scheduleReload(debounceMilliseconds: 220) }
        .onChange(of: viewModel.selectedCountry) { _, _ in scheduleReload() }
        .onChange(of: viewModel.isAscendingSort) { _, _ in scheduleReload() }
        // Stations arrive asynchronously (country fetch, import, CloudKit sync); the snapshot
        // isn't live, so it has to be rebuilt when the backing set changes size.
        .onChange(of: viewModel.stations.count) { _, _ in scheduleReload() }
        .onChange(of: hiddenCountriesData) { _, _ in
            loadHiddenCountries()
            scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiddenCountriesChanged)) { _ in
            loadHiddenCountries()
            scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stationDetailsUpdated)) { _ in
            scheduleReload()
        }
        .alert("Delete Station", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { stationToDelete = nil }
            Button("Delete", role: .destructive) {
                if let station = stationToDelete { deleteStation(station) }
                stationToDelete = nil
            }
        } message: {
            if let stationToDelete {
                Text("Are you sure you want to delete \"\(stationToDelete.name)\"? This action cannot be undone.")
            }
        }
        .alert("Cannot Edit Playing Station", isPresented: $showEditPlayingAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The station is currently playing. Please stop or switch to another station before editing.")
        }
        .alert("Cannot Delete Playing Station", isPresented: $showDeletePlayingAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The station is currently playing. Please stop or switch to another station before deleting.")
        }
        .sheet(isPresented: $showingCountryPicker) {
            CountryPicker(
                selectedCountry: $viewModel.selectedCountry,
                countries: viewModel.countries,
                stationCount: { country in
                    viewModel.stations.filter { $0.country == country }.count
                },
                onSelect: { _ in
                    Task {
                        UIDevice.playHapticFeedback()
                        await viewModel.fetchStationsForSelectedCountry(forceRefresh: false)
                        await MainActor.run { viewModel.syncStationsWithCloudKit() }
                    }
                }
            )
        }
    }

    // MARK: - List

    private var listBody: some View {
        ScrollViewReader { proxy in
            SRStationListBody(
                rows: rows,
                version: rowsVersion,
                nowPlaying: nowPlaying,
                isEditing: isEditing,
                canReorder: canReorder,
                canEnterReorder: canEnterReorder,
                favoriteErrorId: showFavoriteError ? radioPlayer.currentlyPlayingStation?.id : nil,
                onMove: moveStations,
                onTap: handleTap,
                onToggleFavorite: handleFavoriteTap,
                onEdit: editStation,
                onDelete: requestDelete,
                onLongPress: enterReorder,
                flag: flagImage
            )
            .equatable()
            .simultaneousGesture(scrollTrackingGesture)
            .onChange(of: scrollTargetId) { _, newValue in
                guard let newValue, !isEditing else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(newValue, anchor: .center) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scrollTargetId = nil }
            }
            .onChange(of: selectedSubTab) { _, _ in scrollToCurrent(proxy) }
            .onChange(of: selectedTab) { _, newTab in
                if newTab == .radio { scrollToCurrent(proxy) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                scrollToCurrent(proxy)
            }
        }
    }

    // MARK: - Fetch configuration

    private var canReorder: Bool {
        selectedTab == .radio && isEditing && selectedSubTab == .favorites && !isSearching
    }

    private var canEnterReorder: Bool {
        selectedTab == .radio && !isEditing && selectedSubTab == .favorites && !isSearching
    }

    /// Rebuilds the snapshot instead of re-filtering in the body: the predicate runs in SQLite
    /// against the indexed `searchText` column, and the fetch happens off the main thread.
    private func scheduleReload(debounceMilliseconds: Int = 0) {
        reloadTask?.cancel()

        let predicate = self.predicate
        let sortDescriptors = self.sortDescriptors
        let showsCountry = selectedSubTab != .all || isSearching

        reloadTask = Task { @MainActor in
            if debounceMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounceMilliseconds) * 1_000_000)
                guard !Task.isCancelled else { return }
            }

            let loaded = await SRStationSnapshots.shared.rows(
                predicate: predicate,
                sortDescriptors: sortDescriptors,
                showsCountry: showsCountry
            )
            guard !Task.isCancelled else { return }

            rows = loaded
            rowsVersion &+= 1
            hasLoaded = true
        }
    }

    private var predicate: NSPredicate? {
        guard selectedTab == .radio else { return NSPredicate(value: false) }

        if isSearching {
            var parts: [NSPredicate] = [
                NSPredicate(format: "searchText CONTAINS %@", trimmedQuery),
                NSPredicate(format: "country != nil AND country != %@ AND country != %@",
                            "Unknown Region", "Select Country")
            ]
            if !hiddenCountries.isEmpty {
                parts.append(NSPredicate(format: "NOT (country IN %@)", hiddenCountries))
            }
            return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        }

        switch selectedSubTab {
        case .all:
            guard viewModel.selectedCountry != "Select Country" else { return NSPredicate(value: false) }
            return NSPredicate(format: "country == %@", viewModel.selectedCountry)
        case .recent:
            return NSPredicate(format: "lastPlayed != nil")
        case .favorites:
            return NSPredicate(format: "isFavorite == YES")
        }
    }

    private var sortDescriptors: [NSSortDescriptor] {
        // `searchText` is pre-folded and indexed, so sorting on it is both correct for
        // case/diacritic-insensitive ordering and far cheaper than a selector-based comparison.
        let byName = NSSortDescriptor(key: "searchText", ascending: viewModel.isAscendingSort)
        let byNameAscending = NSSortDescriptor(key: "searchText", ascending: true)
        let byRecency = NSSortDescriptor(key: "lastPlayed", ascending: false)

        if isSearching {
            switch selectedSubTab {
            case .recent:
                return [byRecency, byNameAscending]
            case .favorites:
                return [
                    NSSortDescriptor(key: "isFavorite", ascending: false),
                    NSSortDescriptor(key: "favoriteOrder", ascending: true),
                    byNameAscending
                ]
            case .all:
                return [byName]
            }
        }

        switch selectedSubTab {
        case .all:
            return [byName]
        case .recent:
            return [byRecency]
        case .favorites:
            return [
                NSSortDescriptor(key: "favoriteOrder", ascending: true),
                NSSortDescriptor(key: "favoritedAt", ascending: false),
                byNameAscending
            ]
        }
    }

    // MARK: - Actions

    /// The list renders a Core Data snapshot, but playback, favourites, edit and delete all index
    /// into `viewModel.stations`. Anything written to the store since the last load — a CloudKit
    /// sync, an import, a country fetch — is in the snapshot and not in that array, so resolve the
    /// miss by reloading rather than silently doing nothing.
    private func station(_ id: String) -> RadioStation? {
        if let match = viewModel.stations.first(where: { $0.id == id }) { return match }

        print("⚠️ SR RADIO LIST: '\(id)' is in the list snapshot but not in viewModel.stations - reloading")
        viewModel.loadStationsFromCoreData()
        return viewModel.stations.first { $0.id == id }
    }

    /// `currentlyPlayingStation` is restored from the last session at launch, so identity alone is
    /// not proof of playback — the engine has to actually be running.
    private func isPlaying(_ id: String) -> Bool {
        radioPlayer.currentlyPlayingStation?.id == id && radioPlayer.isPlaying
    }

    private func handleTap(_ id: String) {
        guard !isEditing else { return }
        guard let station = station(id),
              let index = viewModel.stations.firstIndex(where: { $0.id == id }) else {
            print("⚠️ SR RADIO LIST: Tapped '\(id)' could not be resolved to a station - ignoring tap")
            return
        }

        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        UIDevice.playHapticFeedback()

        if isPlaying(id) {
            isPlayerSheetPresented = true
            return
        }

        radioPlayer.playStation(at: index, from: viewModel.stations)
        viewModel.updateLastPlayed(for: station)
        viewModel.reportStationClick(for: station)
        scrollTargetId = id
    }

    private func handleFavoriteTap(_ id: String) {
        guard let station = station(id) else { return }
        viewModel.toggleFavorite(for: station)

        // The snapshot is rebuilt from Core Data, but the write lands asynchronously — reloading
        // here would hand back the pre-toggle value. Mirror the new state into `rows` instead.
        guard let isFavorite = self.station(id)?.isFavorite else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            if selectedSubTab == .favorites && !isFavorite {
                rows.removeAll { $0.id == id }
            } else if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index].isFavorite = isFavorite
            }
            rowsVersion &+= 1
        }
    }

    private func editStation(_ id: String) {
        guard let station = station(id) else { return }
        if isPlaying(id) {
            showEditPlayingAlert = true
            return
        }
        selectedStationForEdit = station
    }

    private func requestDelete(_ id: String) {
        guard let station = station(id) else { return }
        if isPlaying(id) {
            showDeletePlayingAlert = true
            return
        }
        stationToDelete = station
        showDeleteAlert = true
    }

    private func deleteStation(_ station: RadioStation) {
        guard let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) else { return }

        DataStore.shared.deleteStationFromCloudKit(station: station) { success in
            DispatchQueue.main.async {
                guard success else { return }
                viewModel.stations.remove(at: index)
                viewModel.deleteStationFromCoreData(station)
                viewModel.forceCloudKitCheckOnNextLaunch()
                PodcastCloudKitManager.shared.syncRadioStationRemovedInstantly(
                    stationId: station.id,
                    stationName: station.name
                )
                adjustPlayerIndexAfterDeletion(at: index)
                scheduleReload()
            }
        }
    }

    private func adjustPlayerIndexAfterDeletion(at index: Int) {
        if RadioPlayer.shared.currentStationIndex == index {
            RadioPlayer.shared.stop()
            RadioPlayer.shared.currentStationIndex = nil
        } else if let current = RadioPlayer.shared.currentStationIndex, current > index {
            RadioPlayer.shared.currentStationIndex = current - 1
        }
    }

    private func moveStations(from source: IndexSet, to destination: Int) {
        rows.move(fromOffsets: source, toOffset: destination)
        rowsVersion &+= 1
        viewModel.moveFavoriteStation(from: source, to: destination)
    }

    // MARK: - Gestures

    private func enterReorder() {
        guard !isEditing, selectedTab == .radio, selectedSubTab == .favorites, !isSearching else { return }
        if radioPlayer.isPlaying { radioPlayer.pause() }
        if PodcastPlayer.shared.isPlaying { PodcastPlayer.shared.pause() }
        isEditing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private var scrollTrackingGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { _ in
                if !isScrolling { isScrolling = true }
            }
            .onEnded { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isScrolling = false }
            }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard !isEditing else { return }
        let target = radioPlayer.currentlyPlayingStation?.id ?? rows.first?.id
        guard let target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(target, anchor: radioPlayer.currentlyPlayingStation == nil ? .top : .center)
            }
        }
    }

    // MARK: - Chrome

    private var reorderHeader: some View {
        HStack {
            Text("Drag to Reorder Stations")
                .font(SRFont.rowSubtitle)
                .foregroundStyle(SRColor.secondaryText)
            Spacer()
            Button("Done") { isEditing = false }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, SRSpacing.lg)
        .padding(.vertical, SRSpacing.md)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            SREmptyState(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "No stations match \"\(searchText)\"."
            )
        } else if viewModel.stations.isEmpty {
            SREmptyState(
                systemImage: "globe",
                title: "No stations configured",
                message: "Pick a country to start browsing radio stations."
            ) {
                countryPickerButton(title: isOffline ? "Offline" : "Select Country")
            }
        } else if viewModel.selectedCountry == "Select Country" {
            SREmptyState(
                systemImage: "globe",
                title: "Select a Country",
                message: "Select any country to explore its radio stations."
            ) {
                countryPickerButton(title: isOffline ? "Offline" : "Browse Countries")
            }
        } else if selectedSubTab == .recent {
            SREmptyState(
                systemImage: "clock",
                title: "Nothing played yet",
                message: "Stations you play will appear here."
            )
        } else if selectedSubTab == .favorites {
            SREmptyState(
                systemImage: "heart",
                title: "No favourites yet",
                message: "Tap the heart on any station to keep it here."
            )
        } else {
            SREmptyState(
                systemImage: "radio",
                title: "No stations available",
                message: "No radio stations found for \(viewModel.selectedCountry)."
            ) {
                VStack(spacing: SRSpacing.md) {
                    Button {
                        Task { await viewModel.fetchStationsForSelectedCountry(forceRefresh: true) }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)

                    countryPickerButton(title: isOffline ? "Offline - Country Browser Disabled" : "Choose Different Country")
                }
            }
        }
    }

    private func countryPickerButton(title: String) -> some View {
        Button {
            alertManager.dismissAlert()
            showingCountryPicker = true
        } label: {
            Label(title, systemImage: isOffline ? "wifi.slash" : "globe")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .disabled(isOffline)
    }

    // MARK: - Helpers

    private func loadHiddenCountries() {
        hiddenCountries = (try? JSONDecoder().decode(Set<String>.self, from: hiddenCountriesData)) ?? []
    }

    private func flagImage(for country: String?) -> Image? {
        guard let country, let flag = Flag(countryCode: country) else { return nil }
        return Image(uiImage: flag.originalImage)
    }
}

/// The list, isolated behind an O(1) equality check.
///
/// ContentView owns `isScrolling` and the footer-menu state and rewrites them — inside a spring
/// animation — while a scroll is in flight. That invalidates this whole subtree several times a
/// second, and without `Equatable` SwiftUI answers each invalidation by diffing every row model in
/// the list. At ~5k stations that is the difference between a smooth scroll and a one-second hang,
/// and because the radio tab stays alive behind the tab bar it stalls the podcast list too.
private struct SRStationListBody: View, Equatable {
    let rows: [SRStationRowModel]
    let version: Int
    let nowPlaying: SRNowPlaying?
    let isEditing: Bool
    let canReorder: Bool
    let canEnterReorder: Bool
    let favoriteErrorId: String?
    let onMove: (IndexSet, Int) -> Void
    let onTap: (String) -> Void
    let onToggleFavorite: (String) -> Void
    let onEdit: (String) -> Void
    let onDelete: (String) -> Void
    let onLongPress: () -> Void
    let flag: (String?) -> Image?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version
            && lhs.nowPlaying == rhs.nowPlaying
            && lhs.isEditing == rhs.isEditing
            && lhs.canReorder == rhs.canReorder
            && lhs.canEnterReorder == rhs.canEnterReorder
            && lhs.favoriteErrorId == rhs.favoriteErrorId
    }

    var body: some View {
        List {
            ForEach(rows) { model in
                row(for: model)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: SRSpacing.lg, bottom: 0, trailing: SRSpacing.lg))
            }
            .onMove(perform: canReorder ? onMove : nil)

            // Clearance for the global player overlay.
            Color.clear
                .frame(height: 120)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // iOS 26 draws an opaque backdrop over the rows behind the tab bar; without this the last
        // rows are hidden rather than showing through it.
        .scrollEdgeEffectHidden(true, for: .bottom)
        // Rows scroll through the home-indicator strip instead of stopping short of it, so the
        // list uses the full screen height whether or not the tab bar is showing.
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
    }

    @ViewBuilder
    private func row(for model: SRStationRowModel) -> some View {
        let id = model.id

        VStack(spacing: 0) {
            if favoriteErrorId == id {
                favoriteErrorBanner
            }

            SRStationRow(
                model: resolvedModel(model),
                nowPlaying: nowPlaying,
                flag: flag(model.country),
                onTap: { onTap(id) },
                onToggleFavorite: { onToggleFavorite(id) }
            )
        }
        // Only attached where it does something: a recogniser on every row of a 5k-station list
        // costs gesture arbitration on every touch.
        .simultaneousGesture(canEnterReorder
            ? LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() }
            : nil)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isEditing {
                // Icon-only: a title would widen the button and iOS draws it as an ellipse.
                Button { onEdit(id) } label: {
                    Label("Edit", systemImage: "pencil").labelStyle(.iconOnly)
                }
                .tint(SRColor.accent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isEditing {
                Button(role: .destructive) { onDelete(id) } label: {
                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                }
            }
        }
    }

    /// The playing row shows the live Shazam / iTunes art; anything else — including a stopped
    /// station — keeps its own lazily-loaded icon.
    private func resolvedModel(_ model: SRStationRowModel) -> SRStationRowModel {
        guard let nowPlaying, nowPlaying.id == model.id,
              case .image = nowPlaying.artwork else {
            return model
        }
        var resolved = model
        resolved.artwork = nowPlaying.artwork
        return resolved
    }

    private var favoriteErrorBanner: some View {
        HStack(spacing: SRSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Stop playback before changing favourites.")
                .font(SRFont.rowDetail)
                .foregroundStyle(SRColor.secondaryText)
            Spacer()
        }
        .padding(.vertical, SRSpacing.xs)
    }
}

/// Builds the radio list's row snapshots away from the main thread.
///
/// Fetches dictionaries rather than managed objects: the list needs a handful of small columns,
/// and a managed-object fetch drags `CDStation.iconData` — a base64 favicon — along with them for
/// every row it touches. Artwork is resolved separately, per visible row, on a cache miss.
final class SRStationSnapshots: @unchecked Sendable {
    static let shared = SRStationSnapshots()

    private let rowContext: NSManagedObjectContext
    private let artworkContext: NSManagedObjectContext
    /// Artwork identity has to change when a station's icon does, otherwise the row keeps serving
    /// the bitmap already cached under the old key.
    private var iconRevisions: [String: Int] = [:]
    private let revisionLock = NSLock()

    func bumpIconRevision(for id: String) {
        revisionLock.lock()
        iconRevisions[id, default: 0] += 1
        revisionLock.unlock()
    }

    private func iconRevision(for id: String) -> Int {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        return iconRevisions[id] ?? 0
    }

    private init() {
        rowContext = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        rowContext.automaticallyMergesChangesFromParent = true
        artworkContext = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        artworkContext.automaticallyMergesChangesFromParent = true
    }

    func rows(
        predicate: NSPredicate?,
        sortDescriptors: [NSSortDescriptor],
        showsCountry: Bool
    ) async -> [SRStationRowModel] {
        let context = rowContext
        return await withCheckedContinuation { continuation in
            context.perform {
                let request = NSFetchRequest<NSDictionary>(entityName: "CDStation")
                request.resultType = .dictionaryResultType
                // Sort keys are included so ORDER BY never has to reach outside the projection.
                request.propertiesToFetch = [
                    "id", "name", "country", "isFavorite",
                    "searchText", "lastPlayed", "favoriteOrder", "favoritedAt"
                ]
                request.predicate = predicate
                request.sortDescriptors = sortDescriptors

                let results = (try? context.fetch(request)) ?? []
                let models: [SRStationRowModel] = results.compactMap { dictionary in
                    guard let id = dictionary["id"] as? String else { return nil }
                    let revision = SRStationSnapshots.shared.iconRevision(for: id)
                    return SRStationRowModel(
                        id: id,
                        name: dictionary["name"] as? String ?? "Unknown Station",
                        country: dictionary["country"] as? String ?? "",
                        artwork: .lazyEncoded(cacheKey: "station.icon.\(id).\(revision)") {
                            await SRStationSnapshots.shared.iconData(for: id)
                        },
                        isFavorite: dictionary["isFavorite"] as? Bool ?? false,
                        showsCountry: showsCountry
                    )
                }
                continuation.resume(returning: models)
            }
        }
    }

    func iconData(for id: String) async -> String? {
        let context = artworkContext
        return await withCheckedContinuation { continuation in
            context.perform {
                let request = NSFetchRequest<NSDictionary>(entityName: "CDStation")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["iconData"]
                request.predicate = NSPredicate(format: "id == %@", id)
                request.fetchLimit = 1

                let encoded = (try? context.fetch(request))?.first?["iconData"] as? String
                continuation.resume(returning: encoded?.isEmpty == false ? encoded : nil)
            }
        }
    }
}
