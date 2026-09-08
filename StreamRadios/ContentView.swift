// ContentView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/8/24.

import SwiftUI
import Combine
import FlagKit
import Darwin
import StreamRadiosKit

// MARK: - CPU Monitor
class CPUMonitor {
    static let shared = CPUMonitor()
    
    private init() {}
    
    /// Get current CPU usage as a percentage
    func getCPUUsage() -> Double {
        var totalUsageOfCPU: Double = 0.0
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        let threadsResult = withUnsafeMutablePointer(to: &threadsList) {
            return $0.withMemoryRebound(to: thread_act_array_t?.self, capacity: 1) {
                task_threads(mach_task_self_, $0, &threadsCount)
            }
        }
        
        if threadsResult == KERN_SUCCESS, let threadsList = threadsList {
            for index in 0..<threadsCount {
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
                let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                        thread_info(threadsList[Int(index)], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                    }
                }
                
                guard infoResult == KERN_SUCCESS else {
                    break
                }
                
                let threadBasicInfo = threadInfo as thread_basic_info
                if threadBasicInfo.flags & TH_FLAGS_IDLE == 0 {
                    totalUsageOfCPU = (totalUsageOfCPU + (Double(threadBasicInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0))
                }
            }
            
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)), vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))
        }
        
        return totalUsageOfCPU
    }
    
    /// Log CPU usage with a custom label
    func logCPUUsage(label: String, includeTimestamp: Bool = true) {
        let cpuUsage = getCPUUsage()
        let timestamp = includeTimestamp ? "[\(Date().timeIntervalSince1970)]" : ""
        print("🔥 CPU \(timestamp) \(label): \(String(format: "%.1f", cpuUsage))%")
    }
    
    /// Get CPU usage with detailed thread information
    func getDetailedCPUInfo() -> (total: Double, threadCount: Int) {
        var totalUsageOfCPU: Double = 0.0
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        let threadsResult = withUnsafeMutablePointer(to: &threadsList) {
            return $0.withMemoryRebound(to: thread_act_array_t?.self, capacity: 1) {
                task_threads(mach_task_self_, $0, &threadsCount)
            }
        }
        
        if threadsResult == KERN_SUCCESS, let threadsList = threadsList {
            for index in 0..<threadsCount {
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
                let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                        thread_info(threadsList[Int(index)], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                    }
                }
                
                guard infoResult == KERN_SUCCESS else {
                    break
                }
                
                let threadBasicInfo = threadInfo as thread_basic_info
                if threadBasicInfo.flags & TH_FLAGS_IDLE == 0 {
                    totalUsageOfCPU = (totalUsageOfCPU + (Double(threadBasicInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0))
                }
            }
            
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)), vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))
        }
        
        return (totalUsageOfCPU, Int(threadsCount))
    }
    
    /// Log detailed CPU usage with thread count
    func logDetailedCPUUsage(label: String) {
        let info = getDetailedCPUInfo()
        print("🔥 CPU [DETAILED] \(label): \(String(format: "%.1f", info.total))% (Threads: \(info.threadCount))")
    }
}

struct ContentView: View {
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var podcastPlayer: PodcastPlayer
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var permissionManager: PermissionManager
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var alertManager = AlertManager()
    
    @State private var selectedStationForEdit: RadioStation?
    @FocusState private var isSearchFieldFocused: Bool

    @State private var isEditingMode: Bool
    @State private var isPlayerSheetPresented = false
    @State private var bitrateMessage: String
    @State private var showAlertForCountryBeforeAddingStation: Bool
    @State private var activeSheet: ActiveSheet?
    @State private var selectedTab: Tab
    @EnvironmentObject var podcastViewModel: PodcastViewModel
    @StateObject private var dataSyncManager = DataSyncManager.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var showPodcastListView: Bool
    @State private var seekPosition: Double
    @State private var showingSubscriptionView = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var showAllEpisodes = false
    @State private var scrollToEpisodeID: String?

    @State private var searchText = ""
    @State private var isSearchPresented = false
    
    // Add state to force UI refresh when sync completes
    @State private var syncCompletionRefreshID = UUID()
    
    // State for home button and footer menu visibility
    @State private var isFooterMenuHidden = false // Start with menu visible
    @State private var isScrolling = false
    /// Clears `isScrolling` if the matching stop notification never arrives.
    @State private var scrollingWatchdog: DispatchWorkItem?
    @State private var homeButtonExplicitlyShowingTabView = false // Track when home button forces TabView visible
    @State private var keyboardOffset: CGFloat = 0
    
    // Network status for disabling country picker when offline
    @State private var isOffline = false

    init() {
        // Always start on radio tab - player loading is independent of tab selection
        // The GlobalPlayerView will show the correct player based on last active player
        let savedTab: Tab = .radio
        
        self._isEditingMode = State(initialValue: false)
        self._selectedStationForEdit = State(initialValue: nil)
        self._bitrateMessage = State(initialValue: "Loading bitrate information...")
        self._showAlertForCountryBeforeAddingStation = State(initialValue: false)
        self._activeSheet = State(initialValue: nil)
        self._selectedTab = State(initialValue: savedTab)
        self._selectedPodcast = State(initialValue: nil)
        self._showPodcastListView = State(initialValue: false)
        self._seekPosition = State(initialValue: 0)
        
        // Configure tab bar for consistent appearance on all devices
        setupTabBarAppearance()
    }
    
    private func setupTabBarAppearance() {
        // Force tab bar to always show as bottom tab bar on all devices
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemBackground
        
        // Configure normal state
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor.secondaryLabel
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor.secondaryLabel,
            .font: UIFont.preferredFont(forTextStyle: .caption2)
        ]
        
        // Configure selected state
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor.label
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.preferredFont(forTextStyle: .caption2)
        ]
        
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        
        // Force bottom tab bar style on all devices including iPad
        UITabBar.appearance().isHidden = false
        
        // Ensure TabView displays as traditional tab bar on iPad
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Force traditional tab bar behavior on iPad
            UITabBar.appearance().barStyle = .default
        }
    }
    
    @Environment(\.horizontalSizeClass) var sizeClass
    @StateObject private var tabBarClearance = TabBarClearance.shared
    
    // MARK: - Device Detection
    
    private var deviceType: DeviceType {
        let height = UIScreen.main.nativeBounds.height
        switch height {
        case 1136: return .iPhoneSE
        case 1334: return .iPhoneSE2
        case 1792: return .iPhone11
        case 2532: return .iPhone13
        case 2556: return .iPhone14Pro
        case 2778: return .iPhone14Plus
        case 2796: return .iPhone15ProMax
        case 2340: return .iPhone15Pro
        case 2622: return .iPhone16Pro
        case 2266: return .iPadMini
        case 2388: return .iPadAir
        case 2732: return .iPadPro
        default: return .other
    }
    }
    
    // MARK: - Layout Properties
    
    private var topPadding: CGFloat {
        switch deviceType {
        case .iPhone15ProMax, .iPhone14Plus: return 10
        case .iPhone16Pro: return 10
        case .iPhone14Pro, .iPhone13: return 10
        case .iPadMini, .iPadAir, .iPadPro: return 10
        default: return 20
        }
    }
    
    private var menuButtonWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2: return 25
        case .iPhone11, .iPhone13, .iPhone14Pro, .iPhone14Plus, .iPhone15ProMax, .iPhone15Pro, .iPhone16Pro: return 30
        case .iPadMini, .iPadAir, .iPadPro: return 40
        default: return 30
        }
    }
    
    private var countryPickerWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2: return 220
        case .iPhone11: return 230
        case .iPhone13, .iPhone14Pro: return 250
        case .iPhone16Pro: return 250
        case .iPhone14Plus, .iPhone15ProMax: return 270
        case .iPhone15Pro: return 260
        case .iPadMini: return 300
        case .iPadAir, .iPadPro: return 400
        default: return 250
        }
    }
    
    private var editButtonWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2, .iPhone11, .iPhone13, .iPhone14Pro, .iPhone14Plus, .iPhone15ProMax, .iPhone15Pro, .iPhone16Pro: return 50
        case .iPadMini: return 100
        case .iPadAir, .iPadPro: return 150
        default: return 50
        }
    }
    
    private var addButtonWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2, .iPhone11: return 40
        case .iPhone16Pro: return 30
        case .iPhone13, .iPhone14Pro, .iPhone14Plus, .iPhone15ProMax, .iPhone15Pro, .iPadMini, .iPadAir, .iPadPro: return 50
        default: return 45
        }
    }
    
    private var playerViewWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2: return 320
        case .iPhone11, .iPhone13, .iPhone14Pro: return 340
        case .iPhone14Plus, .iPhone15ProMax, .iPhone15Pro: return 350
        case .iPhone16Pro: return 350
        case .iPadMini, .iPadAir: return 500
        case .iPadPro: return 565
        default: return 350
        }
    }
    
    // MARK: - Helper Functions
    
    private func flagImage(for country: String) -> UIImage? {
        return Flag(countryCode: country)?.originalImage
    }
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            // Main app content - only show when sync is complete
            if !dataSyncManager.isSyncing || dataSyncManager.isFreshInstallUIReady {
                // Always show TabView to preserve NavigationView stacks
                // Use UIKit integration to hide/show tab bar dynamically
                TabView(selection: $selectedTab) {
            // Radio Tab - Contains the original full interface
            radioTabContent
            .tabItem {
                Image(systemName: Tab.radio.icon)
                Text(Tab.radio.title)
            }
            .tag(Tab.radio)
            
            // Podcast Tab
            PodcastListView(selectedPodcast: $selectedPodcast, isScrolling: $isScrolling, isFooterMenuHidden: $isFooterMenuHidden)
            .id("podcast-\(syncCompletionRefreshID)") // Force PodcastListView to recreate when sync completes
            .environmentObject(podcastPlayer)
            .environmentObject(podcastViewModel)
            .tabItem {
                Image(systemName: Tab.podcast.icon)
                Text(Tab.podcast.title)
            }
            .tag(Tab.podcast)
            

            // Settings Tab
            SettingsView(isScrolling: $isScrolling, isFooterMenuHidden: $isFooterMenuHidden)
            .environmentObject(radioPlayer)
            .environmentObject(viewModel)
            .environmentObject(podcastPlayer)
            .environmentObject(podcastViewModel)
            .tabItem {
                Image(systemName: Tab.settings.icon)
                Text(Tab.settings.title)
            }
            .tag(Tab.settings)
        }
        .id(syncCompletionRefreshID) // Force TabView refresh when sync completes
        .environment(\.horizontalSizeClass, .compact)
        .onChange(of: selectedTab) { newTab in
            // Tab switching should NOT stop playback - players should continue playing
            // State clearing only happens when user actually starts playing a different service
            print("📱 Tab Switch: Switched to \(newTab) - players continue playing")
            
            // CRITICAL FIX: Reset footer menu and scrolling state when switching tabs
            // This prevents spacing issues caused by carrying over scroll state from previous tab
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isFooterMenuHidden = false
                isScrolling = false
            }
        }
        .onAppear {
            // Configure initial tab bar visibility
            updateTabBarVisibility()
            setupTabView()
            checkAndStartDataSync()
            checkSubscriptionStatus()
            
            // Check network status for country picker
            isOffline = !ReachabilityCheck.isConnectedToNetwork()
            
            // SAFETY: Ensure TabView is visible on app appear
            ensureTabViewIsVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userIsScrolling)) { _ in
            // CRITICAL: Hide TabView when user starts scrolling
            guard PlaybackManager.shared.hasEverPlayedContent() else {
                print("🏠 SCROLL: Ignoring scroll - user hasn't played content yet (fresh install protection)")
                return
            }
            
            print("🏠 SCROLL: User started scrolling - hiding TabView")
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isScrolling = true
            }
            
            // A cancelled drag never posts .userStoppedScrolling, which would otherwise leave the
            // global player hit-testing disabled forever.
            scrollingWatchdog?.cancel()
            let watchdog = DispatchWorkItem {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isScrolling = false
                }
            }
            scrollingWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: watchdog)
        }
        .onReceive(NotificationCenter.default.publisher(for: .userStoppedScrolling)) { _ in
            print("🏠 SCROLL: User stopped scrolling - showing TabView")
            scrollingWatchdog?.cancel()
            scrollingWatchdog = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isScrolling = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ForceTabViewVisible"))) { _ in
            print("🏠 CONTENT VIEW: Received ForceTabViewVisible notification")
            
            // CRITICAL: Set flag to prevent shouldHideFooterMenu from overriding
            homeButtonExplicitlyShowingTabView = true
            
            // CRITICAL: Force TabView to be visible regardless of current state
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                isFooterMenuHidden = false
                isScrolling = false
            }
            
            // SAFETY: Update tab bar visibility to ensure it's shown
            updateTabBarVisibility()
            
            // Reset the flag after a short delay to allow normal behavior to resume
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                homeButtonExplicitlyShowingTabView = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Small delay to let the app settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                ensureTabViewIsVisible()
            }
        }
        .onChange(of: isFooterMenuHidden) { _, newValue in
            // Update tab bar visibility when scroll state changes
            updateTabBarVisibility()
        }
        .onChange(of: shouldHideFooterMenu) { _, newValue in
            // CRITICAL: Don't override if home button explicitly requested TabView to be visible
            guard !homeButtonExplicitlyShowingTabView else {
                print("🏠 ContentView: Ignoring shouldHideFooterMenu change - home button explicitly showing TabView")
                return
            }
            
            // CRITICAL: Automatically update isFooterMenuHidden based on shouldHideFooterMenu logic
            // This ensures TabView hides when scrolling after first-time playback
            if newValue != isFooterMenuHidden {
                isFooterMenuHidden = newValue
                print("🏠 ContentView: Auto-updating isFooterMenuHidden to \(newValue) based on shouldHideFooterMenu")
            }
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            // Do NOT clear iTunes artwork when navigating between views
            // iTunes artwork should only be cleared when actually stopping the radio player
            // This preserves the song artwork during view navigation while radio is playing
        }
        .onChange(of: isSearchPresented) { oldValue, newValue in
            // Automatically focus search field when search is presented
            if newValue {
                // Small delay to ensure the view is rendered before focusing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isSearchFieldFocused = true
                }
            } else {
                // Remove focus when search is dismissed
                isSearchFieldFocused = false
            }
        }
        // Removed tab state persistence - app always starts on radio tab
        .overlay(alignment: .bottom) {
            // Global Player positioned above tab bar, never covering it
            // Hide during search unless something is actively playing
            let isActivelyPlaying = radioPlayer.isPlaying || podcastPlayer.isPlaying
            if shouldShowGlobalPlayer && (!isSearchPresented || isActivelyPlaying) {
                GlobalPlayerView(
                    selectedPodcast: $selectedPodcast,
                    isPlayerSheetPresented: $isPlayerSheetPresented,
                    selectedTab: $selectedTab,
                    isFooterMenuHidden: $isFooterMenuHidden,
                    isScrolling: $isScrolling
                )
                .environmentObject(radioPlayer)
                .environmentObject(viewModel)
                .environmentObject(podcastPlayer)
                .environmentObject(podcastViewModel)
                .padding(.bottom, {
                    // Sit a fixed gap above whatever the tab bar actually measures, rather than a
                    // per-idiom constant: iPads with a home button have no bottom safe area to
                    // absorb the difference, so a constant tuned on iPhone lands on the bar.
                    // With the bar hidden there is nothing to clear, so cancel the safe-area inset
                    // out and let the player sit near the physical screen edge.
                    isFooterMenuHidden ? 15 - tabBarClearance.bottomInset : tabBarClearance.height + 6
                }())
                .background(TabBarClearanceProbe(isActive: !isFooterMenuHidden))
                // Add smooth sliding animation when TabView shows/hides
                .animation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0), value: shouldHideFooterMenu)
                // Add subtle scale and opacity animation for enhanced visual feedback
                .scaleEffect(shouldHideFooterMenu ? 1.02 : 1.0)
                .opacity(shouldShowGlobalPlayer ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.3), value: shouldShowGlobalPlayer)
                .allowsHitTesting(true) // Allow interaction with player only
                .offset(y: keyboardOffset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardOffset(from: notification)
        }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    // App is closing: dismiss the player UI overlay
                    isPlayerSheetPresented = false
                    // Clear intent so overlay condition reevaluates to false when next launched
                    podcastPlayer.userWantsToPlay = false
                    radioPlayer.userWantsToPlay = false
                }
            }
            
            // Full-screen data sync progress overlay for fresh installs - always show when syncing
            DataSyncProgressView()
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FreshInstallDataAvailable"))) { _ in
                    // Force UI refresh when sync completes
                    print("📢 ContentView: Received FreshInstallDataAvailable - forcing complete UI refresh")
                    DispatchQueue.main.async {
                        self.syncCompletionRefreshID = UUID()
                        print("🔄 ContentView: Updated syncCompletionRefreshID to force UI refresh")
                    }
                }
        }
    }
    
    // MARK: - Global Player Logic
    
    /// Determines if global player should be shown
    /// Shows global player when user intends to use audio:
    /// - User wants to play podcast (regardless of network connectivity), OR
    /// - Podcast is actively playing, OR
    /// - User wants to play radio (regardless of network connectivity)
    private var shouldShowGlobalPlayer: Bool {
        // Show if user wants to play podcast (regardless of network status or current playing state)
        if podcastPlayer.userWantsToPlay && podcastPlayer.currentEpisode != nil && podcastPlayer.currentFeed != nil {
            return true
        }
        
        // Show if podcast is actively playing
        if podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil && podcastPlayer.currentFeed != nil {
            return true
        }
        
        // ALWAYS SHOW PLAYER: Show if there's a current podcast episode and feed (ready to play)
        if podcastPlayer.currentEpisode != nil && podcastPlayer.currentFeed != nil {
            return true
        }
        
        // Show radio global player regardless of scene phase, based on user intent or active/paused playback
        if radioPlayer.userWantsToPlay { return true }
        if (radioPlayer.isPlaying || radioPlayer.connectionState == .paused) && radioPlayer.currentlyPlayingStation != nil, radioPlayer.userWantsToPlay {
            return true
        }
        
        // ALWAYS SHOW PLAYER: Show if there's a currently playing station (ready to play)
        if radioPlayer.currentlyPlayingStation != nil {
            return true
        }
        
        return false
    }
    
    /// Determines if footer menu should be hidden
    /// Hides when scrolling or when manually hidden via home button
    /// Only hides after user has played content for the first time
    private var shouldHideFooterMenu: Bool {
        // Always show menu if no content is playing
        guard shouldShowGlobalPlayer else { 
            return false 
        }
        
        // FIRST-TIME USER PROTECTION: Never hide TabView on fresh install until content has been played
        guard PlaybackManager.shared.hasEverPlayedContent() else { 
            return false 
        }
        
        // Hide menu when scrolling (only after content has been played)
        if isScrolling { 
            return true 
        }
        
        // Show/hide menu based on home button state
        return isFooterMenuHidden
    }
    
    /// Updates tab bar visibility using UIKit with enhanced animations
    private func updateTabBarVisibility() {
        DispatchQueue.main.async {
            guard let tabBarController = self.findAppTabBarController() else {
                return
            }
            
            // Enhanced animation with spring effect for smoother feel
            UIView.animate(
                withDuration: 0.4,
                delay: 0,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0.5,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: {
                    tabBarController.tabBar.isHidden = self.isFooterMenuHidden
                    
                    // Add subtle transform for extra visual feedback
                    if self.isFooterMenuHidden {
                        tabBarController.tabBar.transform = CGAffineTransform(translationX: 0, y: 10)
                    } else {
                        tabBarController.tabBar.transform = .identity
                    }
                },
                completion: nil
            )
        }
    }
    
    /// Locates the app's tab bar controller.
    /// `connectedScenes` is an unordered Set and includes the CarPlay scene, so taking `.first`
    /// intermittently resolved to the wrong scene and the tab bar was never shown again.
    private func findAppTabBarController() -> UITabBarController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        
        guard let rootViewController = keyWindow?.rootViewController else { return nil }
        return findTabBarController(in: rootViewController)
    }

    private func updateKeyboardOffset(from notification: Notification) {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                                .filter({ $0.session.role == .windowApplication })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else {
            keyboardOffset = 0
            return
        }

        let keyboardFrame = window.convert(value.cgRectValue, from: window.screen.coordinateSpace)
        let isDocked = keyboardFrame.maxY >= window.bounds.maxY - 1
        let overlap = isDocked ? max(0, window.bounds.maxY - keyboardFrame.minY) : 0
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25

        withAnimation(.easeOut(duration: duration)) {
            keyboardOffset = overlap
        }
    }
    
    /// Recursively finds UITabBarController in view hierarchy
    private func findTabBarController(in viewController: UIViewController) -> UITabBarController? {
        if let tabBarController = viewController as? UITabBarController {
            return tabBarController
        }
        
        for child in viewController.children {
            if let found = findTabBarController(in: child) {
                return found
            }
        }
        
        if let presented = viewController.presentedViewController {
            return findTabBarController(in: presented)
        }
        
        return nil
    }


    // MARK: - Conditional Liquid Glass Modifier
    
    struct ConditionalLiquidGlass: ViewModifier {
        let cornerRadius: CGFloat
        
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                content
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.3),
                                        Color.white.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
            }
        }
    }

    // MARK: - Radio Tab Content with Full Original Functionality
    
    private var radioTabContent: some View {
        NavigationStack {
            ZStack {
                Color.adaptiveBackground
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            if isSearchPresented {
                                searchBar
                            } else {
                                CountryPickerButton(
                                    selectedCountry: $viewModel.selectedCountry,
                                    countries: viewModel.countries,
                                    stationCount: { country in
                                        let stationCount = viewModel.stations.filter { $0.country == country }.count
                                        
                                        // Don't show count for countries with manual stations on fresh installs
                                        // Only show count when both manual and API stations are combined
                                        let hasManualStations = ManualStationManager.shared.hasManualStations(for: country)
                                        let hasAPIStations = stationCount > ManualStationManager.shared.getManualStationCount(for: country)
                                        
                                        // Show count only if:
                                        // 1. Country has no manual stations, OR
                                        // 2. Country has both manual and API stations
                                        if !hasManualStations || (hasManualStations && hasAPIStations) {
                                            return stationCount
                                        } else {
                                            return 0 // Hide count for manual-only stations
                                        }
                                    },
                                    onSelect: { [weak viewModel] country in
                                        // Load stations for selected country (use cache if available)
                                        Task {
                                            UIDevice.playHapticFeedback()
                                            await viewModel?.fetchStationsForSelectedCountry(forceRefresh: false)
                                            await MainActor.run {
                                                viewModel?.syncStationsWithCloudKit()
                                            }
                                        }
                                    },
                                    isDisabled: isOffline,
                                    compact: true
                                )
                            }

                            headerActions
                        }
                        .padding(.horizontal, 16)

                        if !isSearchPresented {
                            subTabBar
                        }
                    }
                    .padding(.top, topPadding)
                    .padding(.bottom, isSearchPresented ? 6 : 10)
                    .background(Color.adaptiveBackground)
                    .overlay(alignment: .top) {
                        RadioSyncIndicator()
                            .padding(.top, topPadding + 48)
                    }
                    
                    // SRRadioListView handles its own sub-tabs internally
                    SRRadioListView(isEditing: $isEditingMode,
                                    selectedStationForEdit: $selectedStationForEdit,
                                    selectedTab: $viewModel.selectedTab,
                                    selectedSubTab: $viewModel.selectedSubTab,
                                    activeSheet: $activeSheet,
                                    isPlayerSheetPresented: $isPlayerSheetPresented,
                                    searchText: $searchText,
                                    isScrolling: $isScrolling,
                                    isFooterMenuHidden: $isFooterMenuHidden,
                                    isSearchPresented: $isSearchPresented)
                        .environmentObject(viewModel)
                        .environmentObject(radioPlayer)
                    
                    // Player area is now handled by the global overlay
                    // This ensures consistent player display across all tabs
                    // No individual player needed here as GlobalPlayerView handles all cases
                }
                // The list runs to the screen edge so station rows, not empty background,
                // sit under the floating tab bar.
                .ignoresSafeArea(.container, edges: .bottom)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded { _ in
                        // Dismiss keyboard when tapping outside search box
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                )
                .onReceive(NotificationCenter.default.publisher(for: .stationsUpdated)) { _ in
                    // Force UI update without reloading from Core Data
                    // This prevents manual stations from being wiped out after they're loaded
                    viewModel.objectWillChange.send()
                    
                    // If newly added stations belong to current country, ensure All tab is visible
                    let countryCount = viewModel.stations.filter { $0.country == viewModel.selectedCountry }.count
                    if countryCount > 0 && viewModel.selectedSubTab != .all {
                        viewModel.selectedSubTab = .all
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .countryChanged)) { _ in
                    // Handle country changes without affecting currently playing station
                    // Force UI update without reloading from Core Data
                    viewModel.objectWillChange.send()
                    
                    // If newly selected country has stations, ensure All tab is visible
                    let countryCount = viewModel.stations.filter { $0.country == viewModel.selectedCountry }.count
                    if countryCount > 0 && viewModel.selectedSubTab != .all {
                        viewModel.selectedSubTab = .all
                    }
                }
                
                if alertManager.showCustomAlert {
                    CustomAlertContainer()
                        .environmentObject(alertManager)
                }
            }
            // Add/Edit Station are pushed onto the radio tab's navigation stack. They must not
            // reach this binding at all, or `item:` presents an empty sheet over the push.
            .sheet(item: Binding(
                get: { activeSheet == .playerSheet ? activeSheet : nil },
                set: { newValue in
                    if newValue == nil && activeSheet == .playerSheet {
                        activeSheet = nil
                    }
                }
            )) { item in
                switch item {
                case .addStation, .editStation:
                    EmptyView()
                case .playerSheet:
                    RadioPlayerSheetView()
                        .environmentObject(radioPlayer)
                        .environmentObject(viewModel)
                }
            }

            .fullScreenCover(isPresented: $isPlayerSheetPresented) {
                RadioPlayerSheetView()
                    .environmentObject(radioPlayer)
                    .environmentObject(viewModel)
            }
            .fullScreenCover(isPresented: $showingSubscriptionView) {
                SubscriptionView()
                    .environmentObject(subscriptionManager)
            }

            .onReceive(radioPlayer.bitrateSubject) { newBitrateMessage in
                bitrateMessage = newBitrateMessage
            }
            .onChange(of: subscriptionManager.subscriptionStatus) { oldStatus, newStatus in
                // Auto-hide subscription sheet if user becomes subscribed/trial
                if showingSubscriptionView && subscriptionManager.isSubscribedOrInTrial {
                    print("✅ Subscription status changed to \(newStatus) - hiding subscription sheet")
                    showingSubscriptionView = false
                }
            }
            .onChange(of: activeSheet) { oldValue, newValue in
                // Nothing to clear here anymore; Edit Station owns `selectedStationForEdit`
                // as its navigation path.
                _ = (oldValue, newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToAlarmStation"))) { notification in
                handleAlarmStationNavigation(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToPodcastFeed)) { notification in
                // Handle lock screen podcast feed navigation
                if let userInfo = notification.userInfo,
                   let feedId = userInfo["feedId"] as? String,
                   let episodeId = userInfo["episodeId"] as? String {
                    DispatchQueue.main.async {
                        // Switch to podcast tab
                        selectedTab = .podcast
                        
                        // Find and select the feed
                        if let feed = podcastViewModel.podcastFeeds.first(where: { $0.id == feedId }) {
                            selectedPodcast = feed
                            scrollToEpisodeID = episodeId
                            print("🧭 Main App: Navigating to podcast feed from lock screen: \(feed.title)")
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToAllTab)) { _ in
                handleSwitchToAllStations()
            }
            .navigationBarHidden(true)
            .navigationDestination(item: $selectedStationForEdit) { station in
                EditStationView(station: station)
                    .environmentObject(viewModel)
                    .environmentObject(permissionManager)
            }
            .navigationDestination(isPresented: Binding(
                get: { activeSheet == .addStation },
                set: { isPresented in
                    if !isPresented && activeSheet == .addStation {
                        activeSheet = nil
                    }
                }
            )) {
                AddStationView(activeSheet: $activeSheet, selectedCountry: viewModel.selectedCountry) { savedCountry in
                    viewModel.selectedCountry = savedCountry
                    viewModel.selectedSubTab = .all
                    // Ensure fresh data is visible after adding a station
                    viewModel.loadStationsFromCoreData()
                }
                .environmentObject(viewModel)
                .environmentObject(permissionManager)
            }
        }
    }
    
    // MARK: - Radio List Header
    
    @Namespace private var subTabNamespace
    
    private var headerActions: some View {
        HStack(spacing: 0) {
            if isSearchPresented {
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isSearchPresented = false
                        searchText = ""
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.adaptivePrimaryText)
                .padding(.horizontal, 14)
            } else {
                headerActionButton("magnifyingglass") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isSearchPresented = true
                    }
                }
                
                headerActionButton(viewModel.isAscendingSort ? "arrow.up.circle" : "arrow.down.circle") {
                    switch viewModel.selectedSubTab {
                    case .recent:
                        viewModel.sortRecentStationsAlphabetically()
                    case .favorites:
                        // Favorites tab - show alert to warn about modifying order
                        alertManager.showCustomAlert(for: .confirmFavoritesSortChange) {
                            viewModel.sortFavoritesAlphabetically()
                        }
                    case .all:
                        viewModel.sortStationsAlphabetically()
                    }
                }
                
                headerActionButton("plus") {
                    if viewModel.selectedCountry == "Select Country" {
                        alertManager.showCustomAlert(for: .selectCountryBeforeAddingStation)
                    } else {
                        activeSheet = .addStation
                    }
                }
            }
        }
        .frame(height: 40)
        .background(Capsule().fill(Color.adaptiveSecondaryBackground))
        .modifier(ConditionalLiquidGlass(cornerRadius: 20))
    }
    
    private func headerActionButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.adaptivePrimaryText)
                .frame(width: 34, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var subTabBar: some View {
        HStack(spacing: 4) {
            ForEach(RadioSubTab.allCases, id: \.self) { subTab in
                let isSelected = viewModel.selectedSubTab == subTab
                
                Button {
                    UIDevice.playHapticFeedback()
                    withAnimation(.snappy(duration: 0.28)) {
                        viewModel.selectedSubTab = subTab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: subTab.iconName)
                            .font(.caption.weight(.semibold))
                        Text(subTab.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? selectedSubTabForeground : Color.adaptiveSecondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(selectedSubTabFill)
                                .shadow(color: colorScheme == .dark ? .clear : SRColor.accent.opacity(0.35),
                                        radius: 4, y: 2)
                                .matchedGeometryEffect(id: "selectedSubTab", in: subTabNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.adaptiveSectionBackground))
        .padding(.horizontal, 16)
    }

    /// A solid pill is what makes the selection readable on white; on black the subtle tint already
    /// reads as active and a solid one is too heavy.
    private var selectedSubTabFill: Color {
        colorScheme == .dark ? Color.blue.opacity(0.15) : SRColor.accent
    }

    private var selectedSubTabForeground: Color {
        colorScheme == .dark ? .blue : .white
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundColor(.adaptiveSecondaryText)
            
            TextField("Search stations...", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.subheadline)
                .foregroundColor(.adaptivePrimaryText)
                .focused($isSearchFieldFocused)
                .submitLabel(.search)
            
            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.adaptiveSecondaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Capsule().fill(Color.adaptiveFieldBackground))
        .onAppear {
            // Automatically focus the search field when it appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFieldFocused = true
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func setupTabView() {
        // Additional tab view configuration if needed
        // Tab bar appearance is already configured in init
    }
    
    /// Ensure TabView is visible - called on app appear and when needed
    private func ensureTabViewIsVisible() {
        // CRITICAL FIX: ALWAYS ensure TabView is visible when this is called
        // Don't check state conditions - just force it visible
        
        // Only update if needed to avoid unnecessary animations
        if isFooterMenuHidden || isScrolling {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                isFooterMenuHidden = false
                isScrolling = false
            }
        }
        // Re-apply unconditionally: the UIKit bar can be left hidden by a TabView rebuild even
        // when the state already says it should be visible, and nothing else would correct it.
        updateTabBarVisibility()
    }
    
    private func checkAndStartDataSync() {
        // Check if this is a fresh install or if sync is needed
        if DataSyncManager.shared.checkIfSyncNeeded() {
            DataSyncManager.shared.startFreshInstallSync()
        }
    }
    
    private func checkSubscriptionStatus() {
        // Use async/await to properly wait for subscription status update
        Task {
            // Wait a moment for the app to fully load
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // Ensure subscription status is fully updated before checking
            await subscriptionManager.updateSubscriptionStatus()
            
            await MainActor.run {
                // Double-check subscription status after update
                if !subscriptionManager.isSubscribedOrInTrial {
                    showingSubscriptionView = true
                } else {
                    print("   Current status: \(subscriptionManager.subscriptionStatus)")
                }
            }
        }
    }
    
    private func handleAlarmStationNavigation(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String,
              let stationCountry = userInfo["stationCountry"] as? String,
              let isFavorite = userInfo["isFavorite"] as? Bool else {
            print("❌ Invalid alarm station navigation data")
            return
        }
        
        print("🧭 Navigating to alarm station: \(stationId) in country: \(stationCountry)")
        
        // Ensure we're on the radio tab
        selectedTab = .radio
        
        // Navigate to the appropriate sub-tab based on station properties
        if isFavorite {
            // Station is a favorite - navigate to favorites tab
            viewModel.selectedSubTab = .favorites
            print("📍 Navigated to Favorites tab for alarm station")
        } else {
            // Station is not a favorite - navigate to All tab and set country
            viewModel.selectedCountry = stationCountry
            viewModel.selectedSubTab = .all
            print("📍 Navigated to All tab for country: \(stationCountry)")
        }
        
        // Verify navigation completed and station is visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let station = viewModel.stations.first(where: { $0.id == stationId }) {
                print("✅ Alarm station found after navigation: \(station.name)")
                
                // Ensure the station is playing if it's not already
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !radioPlayer.isPlaying || radioPlayer.currentlyPlayingStation?.id != stationId {
                        if let index = viewModel.stations.firstIndex(where: { $0.id == stationId }) {
                            print("🔄 Ensuring alarm station playback: \(station.name)")
                            radioPlayer.playStation(at: index, from: viewModel.stations)
                        }
                    }
                }
            } else {
                print("❌ Alarm station not found after navigation: \(stationId)")
            }
        }
    }
    
    private func handleSwitchToAllStations() {
        print("🧭 Navigating to All Stations tab from Set Program Alert")
        
        // Switch to the radio tab
        selectedTab = .radio
        
        // Switch to All Stations tab within radio
        viewModel.selectedSubTab = .all
        
        print("📍 Successfully navigated to All Stations tab")
    }
}

// MARK: - Compact Player View

struct CompactPlayerView: View {
    let currentStation: RadioStation
    let metadata: String?
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Binding var isPlayerSheetPresented: Bool
    @Environment(\.colorScheme) var colorScheme
    
    // Computed properties for adaptive colors
    private var playbackControlIconColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    // Secondary grey is too low-contrast against the glass background at caption size.
    private var metadataTextColor: Color {
        colorScheme == .dark ? .white : .adaptiveSecondaryText
    }
    
    private var buttonGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.25),
                Color.white.opacity(0.05),
                Color.white.opacity(0.15)
            ]
        } else {
            return [
                Color.black.opacity(0.15),
                Color.black.opacity(0.05),
                Color.black.opacity(0.10)
            ]
        }
    }
    
    private var buttonBorderColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.4),
                Color.white.opacity(0.1),
                Color.white.opacity(0.3)
            ]
        } else {
            return [
                Color.black.opacity(0.3),
                Color.black.opacity(0.15),
                Color.black.opacity(0.25)
            ]
        }
    }
    
    var body: some View {
        if #available(iOS 26.0, *) {
            // Compact single-row layout with liquid glass effect
            HStack(spacing: 12) {
                // Tappable artwork area for opening player sheet
                Button(action: {
                    print("🖼️ Artwork tapped - OPENING player sheet")
                    isPlayerSheetPresented.toggle()
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.clear)
                            .frame(width: 44, height: 44)
                        
                        albumArtworkView
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                // Tappable text area for opening player sheet - expanded to fill space
                Button(action: {
                    print("📝 Text area tapped - OPENING player sheet")
                    isPlayerSheetPresented.toggle()
                }) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Station name
                        Text(currentStation.name)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        
                        // Metadata with connection status
                        HStack(spacing: 4) {
                            if let shazamTitle = radioPlayer.displayTitle, let shazamArtist = radioPlayer.displayArtist {
                                ScrollOnceText(text: "\(shazamTitle) — \(shazamArtist)", color: metadataTextColor)
                            } else if let meta = metadata, !meta.isEmpty {
                                let split = radioPlayer.splitArtistTitle(from: meta, fallbackArtist: currentStation.name, fallbackTitle: meta)
                                ScrollOnceText(text: "\(split.title) — \(split.artist)", color: metadataTextColor)
                            } else {
                                Text("Live Radio")
                                    .font(.caption)
                                    .foregroundColor(metadataTextColor)
                                    .lineLimit(1)
                            }
                            
                            // Connection status indicator
                            connectionStatusView
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12) // Add spacing from play button
                    .contentShape(Rectangle()) // Make entire area tappable
                }
                .buttonStyle(PlainButtonStyle())
                
                // Essential controls only - just play/pause button
                Button(action: {
                    print("⏯️ Play/pause button action - NOT opening sheet")
                    radioPlayer.playPause()
                }) {
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 44, height: 44)
                        
                        // Glass gradient overlay for depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .frame(width: 44, height: 44)
                        
                        if radioPlayer.isBuffering || radioPlayer.connectionState == .connecting {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(playbackControlIconColor)
                        } else {
                            // Show pause when actually playing; show play when paused or stopped
                            Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.headline)
                                .foregroundColor(playbackControlIconColor)
                                .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                        }
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                // Invisible background that blocks tap-through while allowing glass effect
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.clear)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
            )
            .glassEffect(in: RoundedRectangle(cornerRadius: 16))
            .frame(minHeight: 60)
            .contentShape(Rectangle())
            .allowsHitTesting(true)
        } else {
            // Fallback for earlier iOS versions
            HStack(spacing: 12) {
                // Tappable artwork area for opening player sheet
                Button(action: {
                    print("🖼️ Artwork tapped - OPENING player sheet")
                    isPlayerSheetPresented.toggle()
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.clear)
                            .frame(width: 44, height: 44)
                        
                        albumArtworkView
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                // Tappable text area for opening player sheet
                Button(action: {
                    print("📝 Text area tapped - OPENING player sheet")
                    isPlayerSheetPresented.toggle()
                }) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Station name
                        Text(currentStation.name)
                            .font(.subheadline)
                            .foregroundColor(.adaptivePrimaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        
                        // Metadata with connection status
                        HStack(spacing: 4) {
                            if let shazamTitle = radioPlayer.displayTitle, let shazamArtist = radioPlayer.displayArtist {
                                ScrollOnceText(text: "\(shazamTitle) — \(shazamArtist)", color: metadataTextColor)
                            } else if let meta = metadata, !meta.isEmpty {
                                let split = radioPlayer.splitArtistTitle(from: meta, fallbackArtist: currentStation.name, fallbackTitle: meta)
                                ScrollOnceText(text: "\(split.title) — \(split.artist)", color: metadataTextColor)
                            } else {
                                Text("Live Radio")
                                    .font(.caption)
                                    .foregroundColor(metadataTextColor)
                                    .lineLimit(1)
                            }
                            
                            // Connection status indicator
                            connectionStatusView
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                // Essential controls only - just play/pause button
                Button(action: {
                    print("⏯️ Play/pause button action - NOT opening sheet")
                    radioPlayer.playPause()
                }) {
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 44, height: 44)
                        
                        // Glass gradient overlay for depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .frame(width: 44, height: 44)
                        
                        if radioPlayer.isBuffering || radioPlayer.connectionState == .connecting {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(playbackControlIconColor)
                        } else {
                            // Show pause when actually playing; show play when paused or stopped
                            Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.headline)
                                .foregroundColor(playbackControlIconColor)
                                .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                        }
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.adaptiveSecondaryBackground)
            )
            .frame(minHeight: 60)
            .contentShape(Rectangle())
            .allowsHitTesting(true)
        }
    }
    
    @ViewBuilder
    private var albumArtworkView: some View {
        // Priority: When playing (iTunes artwork > station artwork), When paused (station artwork > iTunes artwork)
        if radioPlayer.isPlaying, let iTunesAlbumArt = radioPlayer.iTunesAlbumArt {
            // When playing, prioritize song artwork
            Image(uiImage: iTunesAlbumArt)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if radioPlayer.isPlaying, let albumArt = radioPlayer.albumArt {
            Image(uiImage: albumArt)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if let iconData = currentStation.iconData, 
                  let imageData = Data(base64Encoded: iconData),
                  let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .background(Color.white.opacity(0.1))
        } else {
            ZStack {
                Color.adaptiveBorder
                
                // Always show radio icon instead of first 2 letters
                Image(systemName: "radio")
                    .font(.title3)
                    .foregroundColor(.adaptivePrimaryText)
            }
        }
    }
    
    @ViewBuilder
    private var connectionStatusView: some View {
        HStack(spacing: 2) {
            switch radioPlayer.connectionState {
            case .connecting:
                ProgressView()
                    .scaleEffect(0.5)
                    .tint(.orange)
                Text("•")
                    .foregroundColor(.orange)
                    .font(.caption2)
            case .disconnected:
                Image(systemName: "wifi.slash")
                    .font(.caption2)
                    .foregroundColor(.red)
            case .buffering:
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .rotationEffect(.degrees(360))
                    .animation(
                        Animation.linear(duration: 1.0).repeatForever(autoreverses: false), 
                        value: radioPlayer.connectionState
                    )
            case .connected, .paused:
                EmptyView()
            case .error:
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
    }
}

// MARK: - Compact Podcast Player View

struct UnifiedPodcastPlayerView: View {
    let currentEpisode: PodcastEpisode
    let currentFeed: PodcastFeed
    @ObservedObject var podcastPlayer: PodcastPlayer
    @ObservedObject var viewModel: PodcastViewModel
    @Binding var selectedPodcast: PodcastFeed?
    var onListButtonTap: (() -> Void)?
    var onCloseButtonTap: (() -> Void)?
    
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var sizeClass
    
    // Computed properties for adaptive colors
    private var playbackControlIconColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var buttonGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.25),
                Color.white.opacity(0.05),
                Color.white.opacity(0.15)
            ]
        } else {
            return [
                Color.black.opacity(0.15),
                Color.black.opacity(0.05),
                Color.black.opacity(0.10)
            ]
        }
    }
    
    private var buttonBorderColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.4),
                Color.white.opacity(0.1),
                Color.white.opacity(0.3)
            ]
        } else {
            return [
                Color.black.opacity(0.3),
                Color.black.opacity(0.15),
                Color.black.opacity(0.25)
            ]
        }
    }
    
    @State private var showChaptersNotes = false
    @State private var showAudioSettings = false
    @State private var showDetailedPlayer = false
    
    // Responsive sizing that scales with Dynamic Type
    private var artworkSize: CGFloat {
        sizeClass == .compact ? 40 : 48  // Reduced from 50/60 to 40/48 for more title space
    }
    
    private var buttonSize: CGFloat {
        sizeClass == .compact ? 40 : 48  // Reduced from 44/52 to 40/48 for smaller rewind/fast forward buttons
    }
    
    private var playButtonSize: CGFloat {
        sizeClass == .compact ? 44 : 52
    }
    
    private var iconSize: CGFloat {
        sizeClass == .compact ? 14 : 16
    }
    
    private var playIconSize: CGFloat {
        sizeClass == .compact ? 18 : 20
    }
    
    private var skipButtonIconSize: CGFloat {
        sizeClass == .compact ? 20 : 24  // Reduced from 22/26 to 20/24 for smaller button appearance
    }
    
    private var horizontalPadding: CGFloat {
        sizeClass == .compact ? 6 : 10  // Reduced from 8/12 to 6/10 for maximum title space
    }
    
    private var buttonSpacing: CGFloat {
        sizeClass == .compact ? -6 : -5  // Further increased negative spacing to bring buttons very close to play button
    }
    
    // PERFORMANCE: Robust navigation throttling to prevent CPU spikes from repeated calls
    @State private var lastNavigationTime: Date = Date.distantPast
    @State private var isNavigationInProgress: Bool = false
    private let navigationThrottleInterval: TimeInterval = 5.0 // 5 seconds minimum between navigations to prevent loops
    
    // Navigation action to currently playing episode
    private func navigateToCurrentEpisode() {
        let now = Date()
        
        // CRITICAL: Prevent navigation if already in progress or too soon
        if isNavigationInProgress {
            print("🚫 Navigation blocked - already in progress")
            return
        }
        
        // PERFORMANCE: Throttle navigation calls to prevent excessive CPU usage
        guard now.timeIntervalSince(lastNavigationTime) >= navigationThrottleInterval else {
            print("🚫 Navigation throttled - too soon since last navigation (\(String(format: "%.1f", now.timeIntervalSince(lastNavigationTime)))s < \(navigationThrottleInterval)s)")
            return
        }
        
        // Set navigation in progress to prevent concurrent calls
        isNavigationInProgress = true
        lastNavigationTime = now
        
        print("Navigating to currently playing episode: \(currentEpisode.title)")
        
        // CRITICAL FIX: Save current progress before navigating to episode list
        // This ensures the episode list shows the live progress, not stale saved progress
        podcastPlayer.handleNavigationAway()
        
        selectedPodcast = currentFeed
        // Request immediate refresh to show latest episodes while displaying cached ones
        viewModel.requestFeedRefresh(currentFeed.id)
        // Use the existing onListButtonTap functionality if available
        onListButtonTap?()
        
        // Reset navigation flag after a delay to allow the navigation to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isNavigationInProgress = false
        }
    }
    
    var body: some View {
        if #available(iOS 26.0, *) {
            // Compact single-row layout with center alignment for Dynamic Type support
                HStack(alignment: .center, spacing: 4) {  // Reduced from 6 to 4 for maximum title space
                    // Tappable area that includes artwork and episode info - opens detailed player
                    Button(action: {
                        showDetailedPlayer = true
                    }) {
                        HStack(alignment: .center, spacing: 4) {
                            // Artwork
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.adaptiveBorder)
                                    .frame(width: artworkSize, height: artworkSize)
                                
                                feedArtworkView
                                    .frame(width: artworkSize, height: artworkSize)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            
                            // Episode info with title and date
                            EpisodeInfoView(episode: currentEpisode)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 4)  // Add left padding for better text positioning
                                .padding(.trailing, 8) // Add right padding to extend tap area closer to buttons
                        }
                        .contentShape(Rectangle()) // Ensure entire area is tappable and blocks tap-through
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Player controls with timer aligned under play button
                    VStack(spacing: 1) {
                        Spacer().frame(height: 4)
                        // Simplified controls - only play/pause and 30s fast forward
                        HStack(spacing: 12) {
                            // Play/Pause button - centered
                            Button(action: {
                                podcastPlayer.togglePlayPause()
                            }) {
                                ZStack {
                                    // Base glass layer
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .frame(width: playButtonSize, height: playButtonSize)
                                    
                                    // Glass gradient overlay for depth
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: buttonGradientColors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: playButtonSize, height: playButtonSize)
                                    
                                    // Glass border with subtle glow
                                    Circle()
                                        .stroke(
                                            LinearGradient(
                                                colors: buttonBorderColors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 1.5
                                        )
                                        .frame(width: playButtonSize, height: playButtonSize)
                                    
                                    if podcastPlayer.loadingEpisodeId == currentEpisode.id && !podcastPlayer.isPlaying {
                                        // Show loading spinner when episode is loading
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: playbackControlIconColor))
                                            .scaleEffect(0.8)
                                    } else if podcastPlayer.isAttemptingReconnection || podcastPlayer.connectionState == .connecting || podcastPlayer.connectionState == .buffering {
                                        // Show spinning indicator when reconnecting or buffering
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: playbackControlIconColor))
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: podcastPlayer.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: playIconSize))
                                            .foregroundColor(playbackControlIconColor)
                                    }
                                }
                                .modifier(GlassEffectModifier(shape: Circle()))
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            // Fast forward 30s - scrub forward through episode timeline
                            Button(action: {
                                print("🔴 DEBUG: Fast forward button pressed - calling skipForward")
                                podcastPlayer.skipForward()
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(colorScheme == .dark ? Color.adaptiveSecondaryBackground.opacity(0.3) : Color.primary.opacity(0.15))
                                        .frame(width: buttonSize, height: buttonSize)
                                    
                                    Image(systemName: "goforward.30")
                                        .font(.system(size: skipButtonIconSize))
                                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                                }
                                .modifier(GlassEffectModifier(shape: Circle()))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        // Connection status indicator for podcast player
                        podcastConnectionStatusView
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 2)
                .background(
                    // Same background as radio player
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.clear)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                )
                .glassEffect(in: RoundedRectangle(cornerRadius: 16))
                .background(
                    // Invisible background layer to block tap-through while allowing button interactions
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                )
            .fixedSize(horizontal: false, vertical: true) // Allow the entire player to expand vertically as needed
            .fullScreenCover(isPresented: $showChaptersNotes) {
                PodcastChaptersNotesView(
                    episode: currentEpisode,
                    feed: currentFeed,
                    podcastPlayer: podcastPlayer,
                    isPresented: $showChaptersNotes
                )
            }
            .sheet(isPresented: $showAudioSettings) {
                AudioSettingsSheet(podcastPlayer: podcastPlayer)
                    .presentationDetents([.fraction(0.5), .large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showDetailedPlayer) {
                PodcastPlayerSheetView(
                    episode: currentEpisode,
                    feed: currentFeed,
                    podcastPlayer: podcastPlayer,
                    viewModel: viewModel,
                    isPresented: $showDetailedPlayer
                )
            }
        } else {
            // Fallback for earlier iOS versions
            // Compact single-row layout with center alignment for Dynamic Type support
                HStack(alignment: .center, spacing: 4) {  // Reduced from 6 to 4 for maximum title space
                    // Tappable area that includes artwork and episode info - opens detailed player
                    Button(action: {
                        showDetailedPlayer = true
                    }) {
                        HStack(alignment: .center, spacing: 4) {
                            // Artwork
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.adaptiveBorder)
                                    .frame(width: artworkSize, height: artworkSize)
                                
                                feedArtworkView
                                    .frame(width: artworkSize, height: artworkSize)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            
                            // Episode info with title and date
                            EpisodeInfoView(episode: currentEpisode)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 4)  // Add left padding for better text positioning
                                .padding(.trailing, 8) // Add right padding to extend tap area closer to buttons
                        }
                        .contentShape(Rectangle()) // Ensure entire area is tappable and blocks tap-through
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Player controls with timer aligned under play button
                    VStack(spacing: 1) {
                        // Simplified controls - only play/pause and 30s fast forward
                        HStack(spacing: 12) {
                            // Play/Pause button - centered
                            Button(action: {
                                podcastPlayer.togglePlayPause()
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(colorScheme == .dark ? Color.black.opacity(0.6) : Color.primary.opacity(0.8))
                                        .frame(width: playButtonSize, height: playButtonSize)
                                    
                                    if podcastPlayer.loadingEpisodeId == currentEpisode.id && !podcastPlayer.isPlaying {
                                        // Show loading spinner when episode is loading
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .scaleEffect(0.8)
                                    } else if podcastPlayer.isAttemptingReconnection || podcastPlayer.connectionState == .connecting || podcastPlayer.connectionState == .buffering {
                                        // Show spinning indicator when reconnecting or buffering
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: podcastPlayer.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: playIconSize))
                                            .foregroundColor(.white)
                                    }
                                }
                                .modifier(GlassEffectModifier(shape: Circle()))
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            // Fast forward 30s - scrub forward through episode timeline
                            Button(action: {
                                print("🔴 DEBUG: Fast forward button pressed - calling skipForward")
                                podcastPlayer.skipForward()
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(colorScheme == .dark ? Color.adaptiveSecondaryBackground.opacity(0.3) : Color.primary.opacity(0.15))
                                        .frame(width: buttonSize, height: buttonSize)
                                    
                                    Image(systemName: "goforward.30")
                                        .font(.system(size: skipButtonIconSize))
                                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                                }
                                .modifier(GlassEffectModifier(shape: Circle()))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        // Connection status indicator for podcast player
                        podcastConnectionStatusView
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.adaptiveSecondaryBackground)
            )
            .background(
                // Invisible background layer to block tap-through while allowing button interactions
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
            )
            .fixedSize(horizontal: false, vertical: true) // Allow the entire player to expand vertically as needed
            .fullScreenCover(isPresented: $showChaptersNotes) {
                PodcastChaptersNotesView(
                    episode: currentEpisode,
                    feed: currentFeed,
                    podcastPlayer: podcastPlayer,
                    isPresented: $showChaptersNotes
                )
            }
            .sheet(isPresented: $showAudioSettings) {
                AudioSettingsSheet(podcastPlayer: podcastPlayer)
                    .presentationDetents([.fraction(0.5), .large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showDetailedPlayer) {
                PodcastPlayerSheetView(
                    episode: currentEpisode,
                    feed: currentFeed,
                    podcastPlayer: podcastPlayer,
                    viewModel: viewModel,
                    isPresented: $showDetailedPlayer
                )
            }
        }
    }

    
    @ViewBuilder
    private var feedArtworkView: some View {
        // Priority: Direct image data > Base64 icon data > default
        if let imageData = currentFeed.imageData, !imageData.isEmpty {
            if let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                defaultPodcastIcon
            }
        } else if let iconData = currentFeed.iconData, !iconData.isEmpty {
            if let data = Data(base64Encoded: iconData), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                defaultPodcastIcon
            }
        } else {
            defaultPodcastIcon
        }
    }
    
            @ViewBuilder
    private var defaultPodcastIcon: some View {
        ZStack {
            Color.adaptiveBorder
            
                                Image(systemName: "microphone")
                .font(.title3)
                .foregroundColor(.adaptivePrimaryText)
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }
        
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    private func formatTimeForDisplay(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "00:00" }
        
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    @ViewBuilder
    private var podcastConnectionStatusView: some View {
        HStack(spacing: 2) {
            switch podcastPlayer.connectionState {
            case .loading:
                ProgressView()
                    .scaleEffect(0.4)
                    .tint(.blue)
                Text("Loading...")
                    .font(.caption2)
                    
            case .connecting:
                ProgressView()
                    .scaleEffect(0.4)
                    .tint(.orange)
                Text("•")
                    .foregroundColor(.orange)
                    .font(.caption2)
            case .disconnected:
                Image(systemName: "wifi.slash")
                    .font(.caption2)
                    .foregroundColor(.red)
                Text("Offline")
                    .font(.caption2)
                    .foregroundColor(.red)
            case .buffering:
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .rotationEffect(.degrees(360))
                    .animation(
                        Animation.linear(duration: 1.0).repeatForever(autoreverses: false), 
                        value: podcastPlayer.connectionState
                    )
                Text("Buffering")
                    .font(.caption2)
                    .foregroundColor(.orange)
            case .connected:
                EmptyView()
            case .error:
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundColor(.red)
                Text("Error")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .frame(height: 12)
    }
}

// MARK: - Mini Podcast Player View (Full Player Style)

typealias MiniPodcastPlayerView = UnifiedPodcastPlayerView

struct CompactPodcastPlayerView: View {
    let currentEpisode: PodcastEpisode
    let currentFeed: PodcastFeed
    @ObservedObject var podcastPlayer: PodcastPlayer
    @ObservedObject var viewModel: PodcastViewModel
    @Binding var selectedPodcast: PodcastFeed?
    var onListButtonTap: (() -> Void)?
    var onCloseButtonTap: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        if #available(iOS 26.0, *) {
            UnifiedPodcastPlayerView(
                currentEpisode: currentEpisode,
                currentFeed: currentFeed,
                podcastPlayer: podcastPlayer,
                viewModel: viewModel,
                selectedPodcast: $selectedPodcast,
                onListButtonTap: onListButtonTap,
                onCloseButtonTap: onCloseButtonTap
            )
        } else {
            // Fallback for earlier iOS versions
            UnifiedPodcastPlayerView(
                currentEpisode: currentEpisode,
                currentFeed: currentFeed,
                podcastPlayer: podcastPlayer,
                viewModel: viewModel,
                selectedPodcast: $selectedPodcast,
                onListButtonTap: onListButtonTap,
                onCloseButtonTap: onCloseButtonTap
            )
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.adaptiveSecondaryBackground)
            )
        }
    }
}

// MARK: - Currently Playing View

struct CurrentlyPlayingView: View {
    let currentStation: RadioStation
    let metadata: String?
    @EnvironmentObject var radioPlayer: RadioPlayer
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            // Album artwork - 64x64 design matching station list
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 64, height: 64)
                
                albumArtworkView
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            // Station and song info
            VStack(alignment: .leading, spacing: 2) {
                Text(currentStation.name)
                    .font(.body)
                    .foregroundColor(.adaptivePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                if let metadata = metadata, !metadata.isEmpty {
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundColor(.adaptiveSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Live Radio")
                        .font(.subheadline)
                        .foregroundColor(.adaptiveSecondaryText)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Play/pause button
            Button(action: {
                radioPlayer.playPause()
            }) {
                ZStack {
                    if radioPlayer.isBuffering {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .background(colorScheme == .dark ? Color.black.opacity(0.6) : Color.primary.opacity(0.8))
            .clipShape(Circle())
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    @ViewBuilder
    private var albumArtworkView: some View {
        // Priority: When playing (iTunes artwork > station artwork), When paused (station artwork > iTunes artwork)
        if radioPlayer.isPlaying, let iTunesAlbumArt = radioPlayer.iTunesAlbumArt {
            // When playing, prioritize song artwork
            Image(uiImage: iTunesAlbumArt)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if radioPlayer.isPlaying, let albumArt = radioPlayer.albumArt {
            Image(uiImage: albumArt)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if let iconData = currentStation.iconData, 
                  let imageData = Data(base64Encoded: iconData),
                  let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .background(Color.white.opacity(0.1))
        } else {
            ZStack {
                Color.gray.opacity(0.3)
                
                // Always show radio icon instead of first 2 letters
                Image(systemName: "radio")
                    .font(.title2)
                    .foregroundColor(.adaptivePrimaryText)
            }
        }
    }
}

// MARK: - Custom Alert Container

struct CustomAlertContainer: View {
    @EnvironmentObject var alertManager: AlertManager
    
    var body: some View {
        GeometryReader { geometry in
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    alertManager.dismissAlert()
                }
            
            CustomAlertView(
                title: alertManager.customAlertTitle,
                message: alertManager.customAlertMessage,
                buttonText: alertManager.customAlertPrimaryButtonText,
                buttonAction: {
                    alertManager.dismissAlert()
                    alertManager.customAlertPrimaryAction?()
                },
                secondaryButtonText: alertManager.customAlertSecondaryButtonText,
                secondaryButtonAction: {
                    alertManager.dismissAlert()
                    alertManager.customAlertSecondaryAction?()
                }
            )
            .frame(width: 300)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .transition(.opacity)
        .zIndex(2)
    }
}

// MARK: - Device Type Enum

enum DeviceType {
    case iPhoneSE
    case iPhoneSE2
    case iPhone11
    case iPhone13
    case iPhone14Pro
    case iPhone14Plus
    case iPhone15ProMax
    case iPhone15Pro
    case iPhone16Pro
    case iPadMini
    case iPadAir
    case iPadPro
    case other
}

// MARK: - Unified Radio Progress Banner

struct UnifiedRadioProgressBanner: View {
    @StateObject private var radioViewModel = RadioStationViewModel.shared
    @StateObject private var syncManager = DataSyncManager.shared
    @State private var hideCompletedBanner = false
    @State private var showDetailedSyncProgress = false
    
    /// Format time remaining in a human-readable format
    private func formatTimeRemaining(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        } else if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            let remainingSeconds = totalSeconds % 60
            return "\(minutes)m \(remainingSeconds)s"
        } else {
            let hours = totalSeconds / 3600
            let remainingMinutes = (totalSeconds % 3600) / 60
            return "\(hours)h \(remainingMinutes)m"
        }
    }
    
    var body: some View {
        if shouldShowBanner {
            VStack(spacing: 6) {
                // Top row with icon, title and percentage
                HStack(spacing: 8) {
                    // Progress icon with animation
                    progressIcon
                        .font(.headline)
                        .foregroundColor(iconColor)
                        .frame(width: 20)
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .scale.combined(with: .opacity)
                        ))
                        .animation(.easeInOut(duration: 0.2), value: currentOperationType)
                        .animation(.easeInOut(duration: 0.2), value: iconColor)
                    
                    // Progress message - FIXED HEIGHT
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bannerTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .id(bannerTitle)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.9)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                            .animation(.easeInOut(duration: 0.2), value: bannerTitle)
                        
                        // FIXED HEIGHT: Always reserve space for country info
                        Group {
                            if !currentCountryInfo.isEmpty {
                                Text(currentCountryInfo)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .animation(.easeInOut(duration: 0.2), value: currentCountryInfo)
                            } else {
                                Text("Loading data...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .opacity(0.0)
                            }
                        }
                        .frame(height: 16)
                    }
                    
                    Spacer()
                    
                    // Percentage
                    Text("\(Int(currentProgress * 100))%")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(iconColor)
                        .animation(.easeInOut(duration: 0.2), value: iconColor)
                }
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 4)
                            .cornerRadius(2)
                        
                        // Progress fill
                        Rectangle()
                            .fill(iconColor)
                            .frame(width: geometry.size.width * currentProgress, height: 4)
                            .cornerRadius(2)
                            .animation(.easeInOut(duration: 0.3), value: currentProgress)
                    }
                }
                .frame(height: 4)
                
                // FIXED HEIGHT: Operation status always reserve space
                Group {
                    if !operationStatus.isEmpty {
                        HStack {
                            Text(operationStatus)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .animation(.easeInOut(duration: 0.2), value: operationStatus)
                            Spacer()
                        }
                    } else {
                        HStack {
                            Text("Preparing operation...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .opacity(0.0)
                            Spacer()
                        }
                    }
                }
                .frame(height: 18)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bannerBackgroundColor)
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .animation(.easeInOut(duration: 0.2), value: bannerBackgroundColor)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity.combined(with: .move(edge: .top))
            ))
            .animation(.easeInOut(duration: 0.3), value: shouldShowBanner)
            .onTapGesture {
                // Show detailed progress for any CloudKit operations
                if currentOperationType == .cloudKitSave || currentOperationType == .cloudKitFetch || 
                   (syncManager.radioStationsStatus == .inProgress && shouldShowBanner) {
                    showDetailedSyncProgress = true
                }
            }
            .sheet(isPresented: $showDetailedSyncProgress) {
                NavigationView {
                    VStack(spacing: 20) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.system(size: 40))
                                
                            
                            Text("CloudKit Sync")
                                .font(.title2)
                                .fontWeight(.semibold)
                            
                            Text(syncManager.radioStationsOperation.isEmpty ? "Synchronizing..." : syncManager.radioStationsOperation)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top)
                        
                        // Progress Section
                        VStack(spacing: 12) {
                            // Progress Bar
                            ProgressView(value: syncManager.radioStationsProgress)
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                                .scaleEffect(x: 1, y: 2, anchor: .center)
                            
                            // Progress Percentage
                            Text("\(Int(syncManager.radioStationsProgress * 100))%")
                                .font(.title3)
                                .fontWeight(.medium)
                            
                            // Station Counts
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Current")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(syncManager.radioStationsCurrentCount)")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                
                                Spacer()
                                
                                VStack(spacing: 4) {
                                    Text("Total")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(syncManager.radioStationsTotalCount)")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                
                                Spacer()
                                
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("Remaining")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(syncManager.radioStationsRemainingCount)")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.orange)
                                }
                            }
                            .padding(.horizontal)
                            
                            // Time Estimates
                            if syncManager.radioStationsEstimatedTimeRemaining > 0 {
                                VStack(spacing: 8) {
                                    HStack {
                                        Text("Estimated time remaining:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(formatTimeRemaining(syncManager.radioStationsEstimatedTimeRemaining))
                                            .font(.caption)
                                            .fontWeight(.medium)
                                    }
                                    
                                    if syncManager.radioStationsAverageTimePerStation > 0 {
                                        HStack {
                                            Text("Average time per station:")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Text("\(String(format: "%.1f", syncManager.radioStationsAverageTimePerStation))s")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .padding(.horizontal)
                        
                        Spacer()
                        
                        // Close Button
                        Button("Close") {
                            showDetailedSyncProgress = false
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.primary.opacity(0.8))
                        .cornerRadius(10)
                        .padding(.horizontal)
                        .padding(.bottom)
                    }
                    .navigationTitle("Sync Progress")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarItems(trailing: Button("Done") {
                        showDetailedSyncProgress = false
                    })
                }
            }
            .onChange(of: syncManager.radioStationsStatus) { status in
                if status == .completed {
                    // Show completion for 3 seconds, then hide
                    hideCompletedBanner = false
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        await MainActor.run {
                            hideCompletedBanner = true
                            // Reset CloudKit status to .none after showing completion
                            syncManager.radioStationsStatus = .none
                            syncManager.radioStationsProgress = 0.0
                            syncManager.radioStationsOperation = ""

                        }
                    }
                } else if status == .inProgress || status == .pending {
                    // Reset the hide flag when new operations start
                    hideCompletedBanner = false
                }
            }
        }
    }
    
    // MARK: - Components
    
    @ViewBuilder
    private var progressIcon: some View {
        if currentOperationType == .cloudKitSave {
            Image(systemName: "icloud.and.arrow.up")
                .id("cloudKitSave")
        } else if currentOperationType == .cloudKitFetch {
            Image(systemName: "icloud.and.arrow.down")
                .id("cloudKitFetch")
        } else {
            // API fetching
            Image(systemName: "arrow.down.circle")
                .id("apiFetch")
        }
    }
    
    // MARK: - Computed Properties
    
    private var shouldShowBanner: Bool {
        // Show for active API fetching (only when actually fetching from API, not Core Data loading)
        let hasAPIFetching = radioViewModel.isLoadingFromAPI
        
        // Show for active CloudKit operations
        let hasActiveCloudKitSync = syncManager.radioStationsStatus == .inProgress
        
        // Show for completed CloudKit state briefly (unless manually hidden)
        let hasRecentCloudKitCompletion = syncManager.radioStationsStatus == .completed && 
                                         !hideCompletedBanner && 
                                         syncManager.radioStationsProgress > 0
        
        return hasAPIFetching || hasActiveCloudKitSync || hasRecentCloudKitCompletion
    }
    
    private var currentOperationType: OperationType {
        // Priority: Show CloudKit operations first (both active and completed)
        if syncManager.radioStationsStatus == .inProgress || 
           (syncManager.radioStationsStatus == .completed && !hideCompletedBanner && syncManager.radioStationsProgress > 0) {
            if syncManager.radioStationsOperation.contains("Saving") {
                return .cloudKitSave
            } else if syncManager.radioStationsOperation.contains("Fetching") || 
                      syncManager.radioStationsOperation.contains("Loading") {
                return .cloudKitFetch
            }
        }
        
        // Otherwise show API fetching
        return .apiFetch
    }
    
    private var currentProgress: Double {
        // Use CloudKit progress if available, otherwise use API progress
        if syncManager.radioStationsStatus == .inProgress && syncManager.radioStationsProgress > 0 {
            return syncManager.radioStationsProgress
        } else if radioViewModel.isLoading {
            return radioViewModel.loadingProgress
        } else if syncManager.radioStationsStatus == .completed {
            return 1.0
        }
        return 0.0
    }
    
    private var bannerTitle: String {
        switch currentOperationType {
        case .cloudKitSave:
            return "Saving stations to iCloud"
        case .cloudKitFetch:
            return "Loading stations from iCloud"
        case .apiFetch:
            return "Fetching stations from API"
        }
    }
    
    private var currentCountryInfo: String {
        // For API fetching, use the selected country
        if radioViewModel.isLoading && currentOperationType == .apiFetch {
            return "Loading \(radioViewModel.selectedCountry)"
        }
        
        // For CloudKit operations, extract country from operation string (simplified)
        let operation = syncManager.radioStationsOperation
        if operation.contains("processing") {
            if let processingIndex = operation.range(of: "processing ")?.upperBound,
               let endIndex = operation.range(of: "...", range: processingIndex..<operation.endIndex)?.lowerBound {
                let countryName = String(operation[processingIndex..<endIndex])
                return "Processing \(countryName)"
            }
        }
        
        // Fallback to generic text to maintain consistent layout
        if syncManager.radioStationsStatus == .inProgress {
            return "Processing data"
        }
        
        return ""
    }
    
    private var operationStatus: String {
        // For API fetching, use simplified stable messages
        if radioViewModel.isLoading && currentOperationType == .apiFetch {
            if radioViewModel.totalStationsToLoad > 0 {
                return "Converting stations to local format..."
            } else {
                // Simplify loading phase to avoid frequent text changes
                let phase = radioViewModel.loadingPhase
                if phase.contains("Connecting") {
                    return "Connecting to radio database..."
                } else if phase.contains("Download") || phase.contains("Receiving") {
                    return "Downloading station data..."
                } else if phase.contains("Finishing") {
                    return "Finalizing download..."
                } else {
                    return "Loading radio stations..."
                }
            }
        }
        
        // For CloudKit operations, simplify operation string
        let operation = syncManager.radioStationsOperation
        if operation.contains("Saving") {
            return "Saving data to iCloud..."
        } else if operation.contains("Fetching") || operation.contains("Loading") {
            return "Loading data from iCloud..."
        } else if !operation.isEmpty {
            return "Processing data..."
        }
        
        return ""
    }
    
    private var bannerBackgroundColor: Color {
        switch currentOperationType {
        case .cloudKitSave:
            return Color.blue.opacity(0.1)
        case .cloudKitFetch:
            return Color.green.opacity(0.1)
        case .apiFetch:
            return Color.orange.opacity(0.1)
        }
    }
    
    private var iconColor: Color {
        switch currentOperationType {
        case .cloudKitSave:
            return .blue
        case .cloudKitFetch:
            return .green
        case .apiFetch:
            return .orange
        }
    }
    
    // MARK: - Types
    
    private enum OperationType {
        case apiFetch
        case cloudKitSave
        case cloudKitFetch
    }
}

// MARK: - Minimal CloudKit Sync Indicator

struct MinimalCloudKitSyncIndicator: View {
    @StateObject private var syncManager = DataSyncManager.shared
    
    var body: some View {
        if syncManager.isMinimalCloudKitSyncing {
            HStack(spacing: 4) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.caption2)
                    .foregroundColor(.cyan)
                Text("Syncing...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.scale.combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: syncManager.isMinimalCloudKitSyncing)
        }
    }
}

// MARK: - Radio Sync Indicator

struct RadioSyncIndicator: View {
    @StateObject private var syncManager = DataSyncManager.shared
    @StateObject private var radioViewModel = RadioStationViewModel.shared
    
    var body: some View {
        Group {
            if shouldShowIndicator {
                HStack(spacing: 4) {
                    Image(systemName: currentIcon)
                        .font(.caption2)
                        .foregroundColor(currentColor)
                        .symbolEffect(.pulse, isActive: isAnimating)
                    
                    if showText {
                        Text(currentText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.scale.combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: shouldShowIndicator)
            }
        }
    }
    
    private var shouldShowIndicator: Bool {
        // Show for active API fetching
        let hasAPIFetching = radioViewModel.isLoadingFromAPI
        
        // Show for active CloudKit operations
        let hasActiveCloudKitSync = syncManager.radioStationsStatus == .inProgress
        
        // Only show when actively syncing - don't show completed state
        return hasAPIFetching || hasActiveCloudKitSync
    }
    
    private var currentIcon: String {
        if syncManager.radioStationsStatus == .inProgress {
            if syncManager.radioStationsOperation.contains("Saving") {
                return "icloud.and.arrow.up"
            } else if syncManager.radioStationsOperation.contains("Fetching") || 
                      syncManager.radioStationsOperation.contains("Loading") {
                return "icloud.and.arrow.down"
            }
        }
        
        // API fetching
        return "antenna.radiowaves.left.and.right"
    }
    
    private var currentColor: Color {
        if syncManager.radioStationsStatus == .inProgress {
            return .cyan
        } else {
            return .blue
        }
    }
    
    private var currentText: String {
        return "Syncing"
    }
    
    private var showText: Bool {
        // Show text only when actively syncing
        return syncManager.radioStationsStatus == .inProgress || radioViewModel.isLoading
    }
    
    private var isAnimating: Bool {
        return syncManager.radioStationsStatus == .inProgress || radioViewModel.isLoadingFromAPI
    }
}

// MARK: - Unified Podcast Progress Banner

struct UnifiedPodcastProgressBanner: View {
    @StateObject private var podcastViewModel = PodcastViewModel.shared
    @StateObject private var syncManager = DataSyncManager.shared
    @State private var hideCompletedBanner = false
    
    var body: some View {
        if shouldShowBanner {
            VStack(spacing: 6) {
                // Top row with icon, title and percentage
                HStack(spacing: 8) {
                    // Progress icon with animation
                    progressIcon
                        .font(.headline)
                        .foregroundColor(iconColor)
                        .frame(width: 20)
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .scale.combined(with: .opacity)
                        ))
                        .animation(.easeInOut(duration: 0.2), value: currentOperationType)
                        .animation(.easeInOut(duration: 0.2), value: iconColor)
                    
                    // Progress message - FIXED HEIGHT
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bannerTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .id(bannerTitle)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.9)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                            .animation(.easeInOut(duration: 0.2), value: bannerTitle)
                        
                        // FIXED HEIGHT: Always reserve space for operation info
                        Group {
                            if !currentOperationInfo.isEmpty {
                                Text(currentOperationInfo)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .animation(.easeInOut(duration: 0.2), value: currentOperationInfo)
                            } else {
                                Text("Processing data...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .opacity(0.0)
                            }
                        }
                        .frame(height: 16)
                    }
                    
                    Spacer()
                    
                    // Percentage
                    Text("\(Int(currentProgress * 100))%")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(iconColor)
                        .animation(.easeInOut(duration: 0.2), value: iconColor)
                }
                
                // Progress bar
                ProgressView(value: currentProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: iconColor))
                    .scaleEffect(y: 1.5, anchor: .center)
                    .animation(.easeInOut(duration: 0.2), value: currentProgress)
                    .animation(.easeInOut(duration: 0.2), value: iconColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(bannerBackgroundColor)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .animation(.easeInOut(duration: 0.2), value: bannerBackgroundColor)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity.combined(with: .move(edge: .top))
            ))
            .animation(.easeInOut(duration: 0.3), value: shouldShowBanner)

            .onChange(of: syncManager.episodeStatesStatus) { status in
                if status == .completed {
                    // Show completion for 3 seconds, then hide
                    hideCompletedBanner = false
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        await MainActor.run {
                            hideCompletedBanner = true
                            // Reset status to .none after showing completion
                            syncManager.episodeStatesStatus = .none
                            syncManager.episodeStatesProgress = 0.0
                            syncManager.episodeStatesOperation = ""
                        }
                    }
                } else if status == .inProgress || status == .pending {
                    // Reset the hide flag when new operations start
                    hideCompletedBanner = false
                }
            }
            .onChange(of: syncManager.crossDeviceFeedSyncStatus) { status in
                if status == .completed {
                    // Show completion for 3 seconds, then hide
                    hideCompletedBanner = false
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        await MainActor.run {
                            hideCompletedBanner = true
                        }
                    }
                } else if status == .inProgress {
                    // Reset the hide flag when new operations start
                    hideCompletedBanner = false
                }
            }
            .onChange(of: syncManager.podcastFeedsStatus) { status in
                if status == .completed {
                    // Show completion for 3 seconds, then hide
                    hideCompletedBanner = false
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        await MainActor.run {
                            hideCompletedBanner = true
                            // Reset status to .none after showing completion
                            syncManager.podcastFeedsStatus = .none
                            syncManager.podcastFeedsProgress = 0.0
                            syncManager.podcastFeedsOperation = ""
                        }
                    }
                } else if status == .inProgress || status == .pending {
                    // Reset the hide flag when new operations start
                    hideCompletedBanner = false
                }
            }
            .onChange(of: syncManager.isParsingFeeds) { isActive in
                // Handle feed parsing completion
                if !isActive && syncManager.feedParsingProgress >= 1.0 {
                    // Feed parsing just completed - show completion for 3 seconds, then hide
                    hideCompletedBanner = false
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        await MainActor.run {
                            hideCompletedBanner = true
                            // Reset feed parsing progress to clear the banner
                            syncManager.feedParsingProgress = 0.0
                            syncManager.feedParsingMessage = ""
                        }
                    }
                } else if isActive {
                    // Reset the hide flag when feed parsing starts
                    hideCompletedBanner = false
                }
            }
            // CloudKit saves now use minimal indicator instead of banner onChange handler
        }
    }
    
    // MARK: - Components
    
    @ViewBuilder
    private var progressIcon: some View {
        switch currentOperationType {
        case .episodeStateSync:
            Image(systemName: "icloud.and.arrow.down")
                .id("episodeStateSync")
        case .feedSync:
            Image(systemName: "rss")
                .id("feedSync")
        // case .feedParsing: // DISABLED
        //     Image(systemName: "doc.text.magnifyingglass")
        //         .id("feedParsing")
        case .crossDeviceFeedSync:
            Image(systemName: "icloud.and.arrow.down.fill")
                .id("crossDeviceFeedSync")
        case .coreDataOperation:
            Image(systemName: "cylinder.split.1x2")
                .id("coreDataOperation")
        }
    }
    
    // MARK: - Computed Properties
    
    private var shouldShowBanner: Bool {
        // Show banner for cross-device feed syncing (feeds added on other devices)
        let hasCrossDeviceFeedSync = syncManager.crossDeviceFeedSyncStatus == .inProgress || 
                                   (syncManager.crossDeviceFeedSyncStatus == .completed && !hideCompletedBanner)
        
        // Episode state sync (batch operations)
        let hasEpisodeStateSync = (syncManager.episodeStatesStatus == .inProgress && syncManager.episodeStatesTotalCount > 0) || 
                                 (syncManager.episodeStatesStatus == .completed && !hideCompletedBanner && 
                                  syncManager.episodeStatesProgress > 0 && syncManager.episodeStatesTotalCount > 0)
        
        // Feed parsing operations
        // let hasFeedParsing = syncManager.isParsingFeeds || 
        //                    (!syncManager.isParsingFeeds && !hideCompletedBanner && syncManager.feedParsingProgress >= 1.0)
        
        // Feed sync operations
        let hasFeedSync = (syncManager.podcastFeedsStatus == .inProgress && syncManager.podcastFeedsTotalCount > 0) || 
                         (syncManager.podcastFeedsStatus == .completed && !hideCompletedBanner && 
                          syncManager.podcastFeedsProgress > 0 && syncManager.podcastFeedsTotalCount > 0)
        
        // NOTE: Real-time episode sync banners are excluded from detailed episode views (Downloads/Favorites)
        // They only appear in the main PodcastListView
        // NOTE: Feed parsing banners have been removed completely
        return hasCrossDeviceFeedSync || hasEpisodeStateSync || hasFeedSync
    }
    
    private var currentOperationType: PodcastOperationType {
        // HIGHEST PRIORITY: Cross-device feed sync (feeds added on other devices)
        if (syncManager.crossDeviceFeedSyncStatus == .inProgress) || 
           (syncManager.crossDeviceFeedSyncStatus == .completed && !hideCompletedBanner) {
            return .crossDeviceFeedSync
        }
        
        // Priority: Show episode state sync (only if there are episodes)
        if (syncManager.episodeStatesStatus == .inProgress && syncManager.episodeStatesTotalCount > 0) || 
           (syncManager.episodeStatesStatus == .completed && !hideCompletedBanner && 
            syncManager.episodeStatesProgress > 0 && syncManager.episodeStatesTotalCount > 0) {
            return .episodeStateSync
        }
        
        // CloudKit saves now use minimal indicator instead of banner
        
        // Feed parsing banners have been DISABLED
        // if syncManager.isParsingFeeds || 
        //    (!syncManager.isParsingFeeds && !hideCompletedBanner && syncManager.feedParsingProgress >= 1.0) {
        //     return .feedParsing
        // }
        
        // Then show feed sync (only if there are feeds)
        if (syncManager.podcastFeedsStatus == .inProgress && syncManager.podcastFeedsTotalCount > 0) || 
           (syncManager.podcastFeedsStatus == .completed && !hideCompletedBanner && 
            syncManager.podcastFeedsProgress > 0 && syncManager.podcastFeedsTotalCount > 0) {
            return .feedSync
        }
        
        // Finally show local CoreData operations
        return .coreDataOperation
    }
    
    private var currentProgress: Double {
        switch currentOperationType {
        case .episodeStateSync:
            if syncManager.episodeStatesStatus == .completed {
                return 1.0
            }
            return syncManager.episodeStatesProgress
        case .feedSync:
            if syncManager.podcastFeedsStatus == .completed {
                return 1.0
            }
            return syncManager.podcastFeedsProgress
        // case .feedParsing: // DISABLED
        //     return 0.0 // DISABLED
        case .crossDeviceFeedSync:
            if syncManager.crossDeviceFeedSyncStatus == .completed {
                return 1.0
            }
            return syncManager.crossDeviceFeedSyncProgress
        case .coreDataOperation:
            return podcastViewModel.isLoading ? 0.5 : 0.0
        }
    }
    
    private var bannerTitle: String {
        switch currentOperationType {
        case .episodeStateSync:
            return "Syncing episode states"
        case .feedSync:
            return "Syncing podcast feeds"
        // case .feedParsing: // DISABLED
        //     return "" // DISABLED
        case .crossDeviceFeedSync:
            return "Syncing feeds from other devices"
        case .coreDataOperation:
            return "Processing podcast data"
        }
    }
    
    private var currentOperationInfo: String {
        switch currentOperationType {
        case .episodeStateSync:
            if syncManager.episodeStatesTotalCount > 0 {
                return "\(syncManager.episodeStatesCurrentCount)/\(syncManager.episodeStatesTotalCount) episodes"
            }
            return syncManager.episodeStatesOperation
        case .feedSync:
            if syncManager.podcastFeedsTotalCount > 0 {
                return "\(syncManager.podcastFeedsCurrentCount)/\(syncManager.podcastFeedsTotalCount) feeds"
            }
            return syncManager.podcastFeedsOperation
        // case .feedParsing: // DISABLED
        //     return "" // DISABLED
        case .crossDeviceFeedSync:
            if syncManager.crossDeviceFeedSyncTotalCount > 0 {
                return "\(syncManager.crossDeviceFeedSyncCurrentCount)/\(syncManager.crossDeviceFeedSyncTotalCount) feeds"
            }
            return syncManager.crossDeviceFeedSyncOperation
        case .coreDataOperation:
            return "Loading from local storage"
        }
    }
    
    private var bannerBackgroundColor: Color {
        switch currentOperationType {
        case .episodeStateSync:
            return Color.blue.opacity(0.1)
        case .feedSync:
            return Color.green.opacity(0.1)
        // case .feedParsing: // DISABLED
        //     return Color.clear // DISABLED
        case .crossDeviceFeedSync:
            return Color.cyan.opacity(0.1)
        case .coreDataOperation:
            return Color.orange.opacity(0.1)
        }
    }
    
    private var iconColor: Color {
        switch currentOperationType {
        case .episodeStateSync:
            return .blue
        case .feedSync:
            return .green
        // case .feedParsing: // DISABLED
        //     return .clear // DISABLED
        case .crossDeviceFeedSync:
            return .cyan
        case .coreDataOperation:
            return .orange
        }
    }
    
    // MARK: - Types
    
    private enum PodcastOperationType {
        case episodeStateSync
        case feedSync
        // case feedParsing // DISABLED - removed "Getting your episodes ready to play" banner
        case crossDeviceFeedSync
        case coreDataOperation
    }
}

// MARK: - Main Podcast List Banner (includes real-time episode sync)

struct MainPodcastListBanner: View {
    @StateObject private var podcastViewModel = PodcastViewModel.shared
    @StateObject private var syncManager = DataSyncManager.shared
    @State private var hideCompletedBanner = false
    
    // MARK: - Types
    
    private enum PodcastOperationType {
        case realTimeEpisodeSync
        case episodeStateSync
        case feedSync
        // case feedParsing // DISABLED - removed "Getting your episodes ready to play" banner
        case crossDeviceFeedSync
        case coreDataOperation
    }
    
    var body: some View {
        if shouldShowBanner {
            VStack(spacing: 6) {
                // Top row with icon, title and percentage
                HStack(spacing: 8) {
                    // Progress icon with animation
                    progressIcon
                        .font(.headline)
                        .foregroundColor(iconColor)
                        .frame(width: 20)
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .scale.combined(with: .opacity)
                        ))
                        .animation(.easeInOut(duration: 0.2), value: currentOperationType)
                        .animation(.easeInOut(duration: 0.2), value: iconColor)
                    
                    // Progress message - FIXED HEIGHT
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bannerTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .frame(height: 20, alignment: .leading)
                        
                        Text(currentOperationInfo)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(height: 14, alignment: .leading)
                    }
                    .frame(height: 34)
                    
                    Spacer()
                    
                    // Progress percentage
                    if currentOperationType != .realTimeEpisodeSync {
                        Text("\(Int(currentProgress * 100))%")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .frame(width: 35, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                // Progress bar (hidden for real-time sync)
                if currentOperationType != .realTimeEpisodeSync {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 3)
                            
                            Rectangle()
                                .fill(iconColor)
                                .frame(width: geometry.size.width * currentProgress, height: 3)
                                .animation(.easeInOut(duration: 0.3), value: currentProgress)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .background(bannerBackgroundColor)
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.3), value: shouldShowBanner)
            .onReceive(NotificationCenter.default.publisher(for: .init("PodcastFeedSyncCompleted"))) { _ in
                // Reset banner state when feed sync completes
                if syncManager.podcastFeedsStatus == .completed {
                    hideCompletedBanner = false
                }
            }
            .onChange(of: syncManager.crossDeviceFeedSyncStatus) { status in
                if status == .completed {
                    // Show completion for 3 seconds, then hide
                    hideCompletedBanner = false
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        await MainActor.run {
                            hideCompletedBanner = true
                            // Reset status to .none after showing completion
                            syncManager.crossDeviceFeedSyncStatus = .none
                            syncManager.crossDeviceFeedSyncProgress = 0.0
                            syncManager.crossDeviceFeedSyncOperation = ""
                        }
                    }
                } else if status == .inProgress || status == .pending {
                    // Reset the hide flag when new operations start
                    hideCompletedBanner = false
                }
            }
            .onChange(of: syncManager.podcastFeedsStatus) { status in
                if status == .completed {
                    // Show completion for 3 seconds, then hide
                    hideCompletedBanner = false
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        await MainActor.run {
                            hideCompletedBanner = true
                            // Reset status to .none after showing completion
                            syncManager.podcastFeedsStatus = .none
                            syncManager.podcastFeedsProgress = 0.0
                            syncManager.podcastFeedsOperation = ""
                        }
                    }
                } else if status == .inProgress || status == .pending {
                    // Reset the hide flag when new operations start
                    hideCompletedBanner = false
                }
            }
            .onChange(of: syncManager.isParsingFeeds) { isActive in
                // Handle feed parsing completion
                if !isActive && syncManager.feedParsingProgress >= 1.0 {
                    // Feed parsing just completed - show completion for 3 seconds, then hide
                    hideCompletedBanner = false
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        await MainActor.run {
                            hideCompletedBanner = true
                            // Reset feed parsing progress to clear the banner
                            syncManager.feedParsingProgress = 0.0
                            syncManager.feedParsingMessage = ""
                        }
                    }
                } else if isActive {
                    // Reset the hide flag when feed parsing starts
                    hideCompletedBanner = false
                }
            }
        }
    }
    
    // MARK: - Components
    
    @ViewBuilder
    private var progressIcon: some View {
        switch currentOperationType {
        case .realTimeEpisodeSync:
            Text(syncManager.realTimeEpisodeType.icon)
                .font(.headline)
                .id("realTimeEpisodeSync")
        case .episodeStateSync:
            Image(systemName: "icloud.and.arrow.down")
                .id("episodeStateSync")
        case .feedSync:
            Image(systemName: "rss")
                .id("feedSync")
        // case .feedParsing: // DISABLED
        //     Image(systemName: "doc.text.magnifyingglass")
        //         .id("feedParsing")
        case .crossDeviceFeedSync:
            Image(systemName: "icloud.and.arrow.down.fill")
                .id("crossDeviceFeedSync")
        case .coreDataOperation:
            Image(systemName: "cylinder.split.1x2")
                .id("coreDataOperation")
        }
    }
    
    // MARK: - Computed Properties
    
    private var shouldShowBanner: Bool {
        // HIGHEST PRIORITY: Real-time episode sync (immediate individual episode changes)
        let hasRealTimeEpisodeSync = syncManager.isRealTimeEpisodeSyncing
        
        // Show banner for cross-device feed syncing (feeds added on other devices)
        let hasCrossDeviceFeedSync = syncManager.crossDeviceFeedSyncStatus == .inProgress || 
                                   (syncManager.crossDeviceFeedSyncStatus == .completed && !hideCompletedBanner)
        
        // Episode state sync (batch operations)
        let hasEpisodeStateSync = (syncManager.episodeStatesStatus == .inProgress && syncManager.episodeStatesTotalCount > 0) || 
                                 (syncManager.episodeStatesStatus == .completed && !hideCompletedBanner && 
                                  syncManager.episodeStatesProgress > 0 && syncManager.episodeStatesTotalCount > 0)
        
        // Feed parsing operations
        // let hasFeedParsing = syncManager.isParsingFeeds || 
        //                    (!syncManager.isParsingFeeds && !hideCompletedBanner && syncManager.feedParsingProgress >= 1.0)
        
        // Feed sync operations
        let hasFeedSync = (syncManager.podcastFeedsStatus == .inProgress && syncManager.podcastFeedsTotalCount > 0) || 
                         (syncManager.podcastFeedsStatus == .completed && !hideCompletedBanner && 
                          syncManager.podcastFeedsProgress > 0 && syncManager.podcastFeedsTotalCount > 0)
        
        return hasRealTimeEpisodeSync || hasCrossDeviceFeedSync || hasEpisodeStateSync || hasFeedSync
    }
    
    private var currentOperationType: PodcastOperationType {
        // HIGHEST PRIORITY: Real-time episode sync (immediate individual episode changes)
        if syncManager.isRealTimeEpisodeSyncing {
            return .realTimeEpisodeSync
        }
        
        // SECOND PRIORITY: Cross-device feed sync (feeds added on other devices)
        if (syncManager.crossDeviceFeedSyncStatus == .inProgress) || 
           (syncManager.crossDeviceFeedSyncStatus == .completed && !hideCompletedBanner) {
            return .crossDeviceFeedSync
        }
        
        // Priority: Show episode state sync (only if there are episodes)
        if (syncManager.episodeStatesStatus == .inProgress && syncManager.episodeStatesTotalCount > 0) || 
           (syncManager.episodeStatesStatus == .completed && !hideCompletedBanner && 
            syncManager.episodeStatesProgress > 0 && syncManager.episodeStatesTotalCount > 0) {
            return .episodeStateSync
        }
        
        // Feed parsing banners have been DISABLED
        // if syncManager.isParsingFeeds || 
        //    (!syncManager.isParsingFeeds && !hideCompletedBanner && syncManager.feedParsingProgress >= 1.0) {
        //     return .feedParsing
        // }
        
        // Then show feed sync (only if there are feeds)
        if (syncManager.podcastFeedsStatus == .inProgress && syncManager.podcastFeedsTotalCount > 0) || 
           (syncManager.podcastFeedsStatus == .completed && !hideCompletedBanner && 
            syncManager.podcastFeedsProgress > 0 && syncManager.podcastFeedsTotalCount > 0) {
            return .feedSync
        }
        
        // Finally show local CoreData operations
        return .coreDataOperation
    }
    
    private var currentProgress: Double {
        switch currentOperationType {
        case .realTimeEpisodeSync:
            return 1.0 // Real-time sync shows as complete/instant
        case .episodeStateSync:
            if syncManager.episodeStatesStatus == .completed {
                return 1.0
            }
            return syncManager.episodeStatesProgress
        case .feedSync:
            if syncManager.podcastFeedsStatus == .completed {
                return 1.0
            }
            return syncManager.podcastFeedsProgress
        // case .feedParsing: // DISABLED
        //     return 0.0 // DISABLED
        case .crossDeviceFeedSync:
            if syncManager.crossDeviceFeedSyncStatus == .completed {
                return 1.0
            }
            return syncManager.crossDeviceFeedSyncProgress
        case .coreDataOperation:
            return podcastViewModel.isLoading ? 0.5 : 0.0
        }
    }
    
    private var bannerTitle: String {
        switch currentOperationType {
        case .realTimeEpisodeSync:
            return "\(syncManager.realTimeEpisodeType.displayName) synced"
        case .episodeStateSync:
            return "Syncing episode states"
        case .feedSync:
            return "Syncing podcast feeds"
        // case .feedParsing: // DISABLED
        //     return "" // DISABLED
        case .crossDeviceFeedSync:
            return "Syncing feeds from other devices"
        case .coreDataOperation:
            return "Processing podcast data"
        }
    }
    
    private var currentOperationInfo: String {
        switch currentOperationType {
        case .realTimeEpisodeSync:
            return "\(syncManager.realTimeEpisodeTitle): \(syncManager.realTimeEpisodeValue)"
        case .episodeStateSync:
            if syncManager.episodeStatesTotalCount > 0 {
                return "\(syncManager.episodeStatesCurrentCount)/\(syncManager.episodeStatesTotalCount) episodes"
            }
            return syncManager.episodeStatesOperation
        case .feedSync:
            if syncManager.podcastFeedsTotalCount > 0 {
                return "\(syncManager.podcastFeedsCurrentCount)/\(syncManager.podcastFeedsTotalCount) feeds"
            }
            return syncManager.podcastFeedsOperation
        // case .feedParsing: // DISABLED
        //     return "" // DISABLED
        case .crossDeviceFeedSync:
            if syncManager.crossDeviceFeedSyncTotalCount > 0 {
                return "\(syncManager.crossDeviceFeedSyncCurrentCount)/\(syncManager.crossDeviceFeedSyncTotalCount) feeds"
            }
            return syncManager.crossDeviceFeedSyncOperation
        case .coreDataOperation:
            return "Loading from local storage"
        }
    }
    
    private var bannerBackgroundColor: Color {
        switch currentOperationType {
        case .realTimeEpisodeSync:
            return Color.mint.opacity(0.15)
        case .episodeStateSync:
            return Color.blue.opacity(0.1)
        case .feedSync:
            return Color.green.opacity(0.1)
        // case .feedParsing: // DISABLED
        //     return Color.clear // DISABLED
        case .crossDeviceFeedSync:
            return Color.cyan.opacity(0.1)
        case .coreDataOperation:
            return Color.orange.opacity(0.1)
        }
    }
    
    private var iconColor: Color {
        switch currentOperationType {
        case .realTimeEpisodeSync:
            return .mint
        case .episodeStateSync:
            return .blue
        case .feedSync:
            return .green
        // case .feedParsing: // DISABLED
        //     return .clear // DISABLED
        case .crossDeviceFeedSync:
            return .cyan
        case .coreDataOperation:
            return .orange
        }
    }
}

// MARK: - Episode Info Component with Title and Date

struct EpisodeInfoView: View {
    let episode: PodcastEpisode
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Animated scrolling title
            AnimatedScrollingEpisodeTitle(title: episode.title)
            
            // Episode release date
            Text(formatEpisodeDate(episode.publicationDate))
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
                .lineLimit(1)
        }
    }
    
    private func formatEpisodeDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Single-Pass Scrolling Text

/// Scrolls overflowing single-line text to its end once, then settles back at the start.
struct ScrollOnceText: View {
    let text: String
    var font: Font = .caption
    var color: Color = .primary
    var height: CGFloat = 16

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?

    private let startDelay: TimeInterval = 2.0
    private let holdAtEnd: TimeInterval = 1.5
    private let pointsPerSecond: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { textGeometry in
                        Color.clear
                            .onAppear { textWidth = textGeometry.size.width }
                            .onChange(of: textGeometry.size.width) { _, newWidth in
                                textWidth = newWidth
                            }
                    }
                )
                .offset(x: offset)
                .frame(width: geometry.size.width, alignment: .leading)
                .clipped()
                .onAppear {
                    containerWidth = geometry.size.width
                    scheduleScroll()
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    containerWidth = newWidth
                }
                .onChange(of: text) { _, _ in
                    scheduleScroll()
                }
                .onDisappear {
                    scrollTask?.cancel()
                }
        }
        .frame(height: height)
    }

    private func scheduleScroll() {
        scrollTask?.cancel()
        offset = 0
        scrollTask = Task { @MainActor in
            // The text width lands a frame after the view does, so wait before measuring.
            try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let overflow = textWidth - containerWidth
            guard overflow > 1 else { return }

            let duration = Double(overflow / pointsPerSecond)
            withAnimation(.linear(duration: duration)) { offset = -overflow }

            try? await Task.sleep(nanoseconds: UInt64((duration + holdAtEnd) * 1_000_000_000))
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.6)) { offset = 0 }
        }
    }
}

// MARK: - Animated Scrolling Episode Title Component

struct AnimatedScrollingEpisodeTitle: View {
    let title: String
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var animationOffset: CGFloat = 0
    @State private var scrollCount: Int = 0
    @State private var isAnimating: Bool = false
    @State private var isInitialDelayComplete: Bool = false
    @State private var scrollTriggerTimer: Timer?
    @Environment(\.colorScheme) var colorScheme
    
    private let maxScrollRuns = 2 // Two complete scrolls then stop
    private let initialDelay: TimeInterval = 4.0 // 4 second delay before first scroll
    
    var body: some View {
        GeometryReader { geometry in
            let containerW = geometry.size.width
            
            Group {
                if isAnimating {
                    // During animation: show repeated title for seamless marquee effect
                    Text("\(title)  \(title)  \(title)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    // When not animating: show single title
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading) // Force text to start from left edge
            .offset(x: isAnimating ? animationOffset : 0) // Only apply offset during animation
                .background(
                    GeometryReader { textGeometry in
                        Color.clear
                            .onAppear {
                                textWidth = textGeometry.size.width
                                containerWidth = containerW
                                startInitialDelay()
                            }
                            .onChange(of: title) { _ in
                                // Reset animation for new title
                                resetAnimation()
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    textWidth = textGeometry.size.width
                                    containerWidth = containerW
                                    startInitialDelay()
                                }
                            }
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading) // Ensure text starts from beginning
            .frame(width: containerW, alignment: .leading) // Full width for proper text positioning
            .clipped()
            .onAppear {
                containerWidth = containerW
            }
            .onReceive(NotificationCenter.default.publisher(for: .userStoppedScrolling)) { _ in
                // Trigger scrolling 4 seconds after user stops scrolling in any view
                if isInitialDelayComplete && !isAnimating {
                    scrollTriggerTimer?.invalidate()
                    scrollTriggerTimer = Timer.scheduledTimer(withTimeInterval: initialDelay, repeats: false) { _ in
                        // Force start animation after 4-second delay, regardless of conditions
                        if textWidth > (containerWidth - 20) && scrollCount < maxScrollRuns {
                            isAnimating = true
                            animateScroll()
                        }
                    }
                }
            }
        }
        .frame(height: 20)
    }
    
    private func startInitialDelay() {
        // Cancel any existing timer
        scrollTriggerTimer?.invalidate()
        
        // Mark as ready for scroll triggering (but don't start scrolling automatically)
        isInitialDelayComplete = true
    }
    
    private func resetAnimation() {
        scrollTriggerTimer?.invalidate()
        scrollCount = 0
        isAnimating = false
        animationOffset = 0  // Ensure text returns to start position
        isInitialDelayComplete = false
    }
    
    private func startAnimationIfNeeded() {
        // Only proceed if initial delay is complete
        guard isInitialDelayComplete else { return }
        
        // Start scrolling when text reaches the red mark position
        // Reserve minimal space to prevent overlap with play button (approximately 20 points)
        let availableTextWidth = containerWidth - 20
        
        // Only animate if text is wider than available space and haven't exceeded max runs
        guard textWidth > availableTextWidth && scrollCount < maxScrollRuns else {
            isAnimating = false
            return
        }
        
        // Ensure we always start from the beginning of the title
        animationOffset = 0
        isAnimating = true
        
        // Small delay to ensure text is properly positioned before animation starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            animateScroll()
        }
    }
    
    private func animateScroll() {
        // Create seamless marquee effect: scroll just the text width to create continuous loop
        // This makes it appear like "Title Title Title..." without gaps
        let scrollDistance = textWidth // Only scroll the width of the text for seamless looping
        
        // Start continuous marquee animation immediately
        startScrollAnimation(scrollDistance: scrollDistance)
    }
    
    private func startScrollAnimation(scrollDistance: CGFloat) {
        // Ensure animation always starts from the beginning position
        animationOffset = 0
        
        // Adaptive scroll speed: moderate speed for better readability
        let scrollSpeed: Double = textWidth > 1000 ? 80 : textWidth > 500 ? 60 : 40 // Slower for better readability
        let animationDuration = Double(scrollDistance / scrollSpeed)
        
        // Check if this will be the final scroll before starting animation
        let willBeFinalScroll = (scrollCount + 1) >= maxScrollRuns
        
        // Log when second scroll starts
        if willBeFinalScroll {
            print("📱 EPISODE TITLE: Second (final) scroll starting at \(Date()) - Duration: \(animationDuration)s")
        }
        
        withAnimation(.linear(duration: animationDuration)) {
            animationOffset = -scrollDistance
        }
        
        // Handle final scroll completion - rewind back to beginning then stop
        if willBeFinalScroll {
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                print("📱 EPISODE TITLE: Second scroll ended at \(Date()) - Starting fade-in-place")
                
                // Fade-in-place effect: instantly reset position, then fade in single title
                withAnimation(.none) {
                    animationOffset = 0  // Instantly reset to beginning
                    isAnimating = false  // Switch to single title display
                }
                scrollCount += 1
                
                // Fade in the single title at the beginning position
                let fadeInDuration = 0.3
                withAnimation(.easeIn(duration: fadeInDuration)) {
                    // The title is already visible, this creates a smooth transition effect
                }
                
                print("📱 EPISODE TITLE: Fade-in-place completed at \(Date()) - Single title displayed from beginning")
            }
        } else {
            // Handle continuous scroll without pause for seamless marquee effect
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                // Reset position to beginning instantly for seamless loop
                withAnimation(.none) {
                    animationOffset = 0  // Instant reset to start for seamless loop
                }
                scrollCount += 1
                
                // Continue immediately without pause for seamless marquee effect
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    animateScroll()
                }
            }
        }
    }
}

struct ScrollableEpisodeTitle: View {
    let title: String
    @State private var isScrollable = false
    @State private var scrollOffset: CGPoint = .zero
    @State private var contentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.adaptivePrimaryText)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { textGeometry in
                                Color.clear
                                    .onAppear {
                                        contentHeight = textGeometry.size.height
                                        containerHeight = calculateHeight()
                                        isScrollable = contentHeight > containerHeight
                                    }
                                    .onChange(of: title) { _ in
                                        contentHeight = textGeometry.size.height
                                        containerHeight = calculateHeight()
                                        isScrollable = contentHeight > containerHeight
                                    }
                            }
                        )
                }
                .frame(height: calculateHeight())
                .clipped()
                .coordinateSpace(name: "scroll")
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .preference(key: ScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("scroll")).origin)
                    }
                )
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    scrollOffset = value
                }
            }
        }
        .frame(height: calculateHeight())
    }
    
    private func calculateHeight() -> CGFloat {
        // Calculate height for 3 lines of caption text
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let lineHeight = font.lineHeight
        return lineHeight * 3 + 4 // Add some padding
    }
    
    private func calculateScrollIndicatorHeight() -> CGFloat {
        guard contentHeight > 0 && containerHeight > 0 else { return 0 }
        let ratio = containerHeight / contentHeight
        let lineHeight = calculateHeight() - 20 // Account for arrow space
        return max(lineHeight * ratio, 15) // Minimum height of 15
    }
    
    private func calculateScrollIndicatorOffset() -> CGFloat {
        guard contentHeight > containerHeight else { return 0 }
        let maxScroll = contentHeight - containerHeight
        let scrollProgress = min(max(-scrollOffset.y, 0), maxScroll) / maxScroll
        let availableHeight = calculateHeight() - 20 // Account for arrow space
        let maxOffset = availableHeight - calculateScrollIndicatorHeight()
        return scrollProgress * maxOffset
    }
}

// MARK: - Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .preferredColorScheme(.dark)
            .environmentObject(AlertManager())
            .environmentObject(RadioStationViewModel())
    }
}

// MARK: - Glass Effect Modifier

struct GlassEffectModifier<S: Shape>: ViewModifier {
    let shape: S
    
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: shape)
        } else {
            content
        }
    }
}

