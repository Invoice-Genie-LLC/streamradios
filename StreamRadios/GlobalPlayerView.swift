//
//  GlobalPlayerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 12/28/24.
//

import SwiftUI
import AVFoundation

/// Publishes how tall the tab bar actually is, above the home indicator.
///
/// SwiftUI doesn't expose this, and it differs by idiom, OS version and whether the device has a
/// home indicator at all — a constant that clears the bar on iPhone overlaps it on iPad.
final class TabBarClearance: ObservableObject {
    static let shared = TabBarClearance()

    @Published private(set) var height: CGFloat = 49

    /// The window's bottom safe-area inset, so callers can cancel it out with negative padding.
    @Published private(set) var bottomInset: CGFloat = 0

    /// True when the system lays the tab bar out vertically along a side edge (iPhone Duo's outer
    /// display, and its inner display in landscape). There is then no bar along the bottom to
    /// clear. Always false on other iPhones and on iPad, where the bar is horizontal.
    @Published private(set) var isBarOnSide = false

    private var measuredForWindowSize: CGSize?
    private var lastWindowSize: CGSize?

    func measure(from view: UIView?, includeTabBar: Bool = true) {
        guard let window = view?.window else { return }

        let inset = window.safeAreaInsets.bottom
        if abs(inset - bottomInset) > 0.5 { bottomInset = inset }

        // A rotation, fold or unfold is measured while the tab bar is still on its way to its
        // new edge, and nothing lays out again once it lands. Without a second look the bar was
        // remembered along the bottom after turning iPhone Duo to landscape, which left the
        // header buttons inline instead of in the side column.
        if lastWindowSize != window.bounds.size {
            lastWindowSize = window.bounds.size
            for delay in [0.4, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
                    self?.measuredForWindowSize = nil
                    self?.measure(from: view, includeTabBar: includeTabBar)
                }
            }
        }

        guard includeTabBar else { return }
        if measuredForWindowSize == window.bounds.size { return }
        guard let bar = Self.tabBar(in: window) else { return }

        let barFrame = bar.convert(bar.bounds, to: window)

        // A bar that is taller than it is wide runs down the side of the display.
        let onSide = barFrame.height > barFrame.width && barFrame.width > 0
        if onSide != isBarOnSide { isBarOnSide = onSide }
        if onSide {
            measuredForWindowSize = window.bounds.size
            return
        }
        // The bar can be mid-transition or parked offscreen while it's hidden; ignore those frames.
        guard barFrame.maxY <= window.bounds.maxY + 1 else { return }
        let measured = window.bounds.maxY - barFrame.minY - inset
        guard measured > 0 else { return }

        measuredForWindowSize = window.bounds.size
        if abs(measured - height) > 0.5 { height = measured }
    }

    private static func tabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for subview in view.subviews {
            if let found = tabBar(in: subview) { return found }
        }
        return nil
    }
}

/// Whether this device folds (iPhone Duo).
///
/// Foldable iPhones get landscape support, so the open inner display can be used in every pose
/// as Apple's iPhone Duo guidelines ask. Every other iPhone and iPad stays portrait-only.
///
/// The Info.plist declares landscape for iPhone so the system lets the app fill iPhone Duo's inner
/// display: a portrait-locked app is shown there as a phone-sized window in the middle of the
/// display. The orientation callbacks in AppDelegate and SceneDelegate narrow it back to portrait
/// everywhere else.
final class FoldableDevice {
    static let shared = FoldableDevice()

    private static let hasHingeKey = "DeviceHasHinge"

    /// Hardware model identifiers of foldable iPhones.
    private static let foldableModelIdentifiers: Set<String> = ["iPhone19,4"]

    /// Known from the hardware model at launch, before any window exists to observe the hinge.
    /// The hinge observer and the value remembered from an earlier launch cover foldable models
    /// that aren't listed yet.
    private(set) var hasHinge = FoldableDevice.isFoldableModel
        || UserDefaults.standard.bool(forKey: FoldableDevice.hasHingeKey)

    private static var isFoldableModel: Bool {
        foldableModelIdentifiers.contains(modelIdentifier)
    }

    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Adds a hinge observer to the window once. Called from the tab bar probe, which is the first
    /// place the app's UIKit window is reachable.
    func observe(_ window: UIWindow?) {
        guard #available(iOS 27.1, *), let window,
              !window.interactions.contains(where: { $0 is UIHingeInteraction }) else { return }

        let interaction = UIHingeInteraction { [weak self, weak window] _, update in
            NSLog("DUODBG hinge update hinge=%@", String(describing: update.hinge))
            guard let self, update.hinge != nil, !self.hasHinge else { return }
            self.hasHinge = true
            UserDefaults.standard.set(true, forKey: FoldableDevice.hasHingeKey)
            // Ask the scene for its supported orientations again (see SceneDelegate).
            window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        window.addInteraction(interaction)
        NSLog("DUODBG hinge interaction added")
    }
}

/// Side-by-side layout for iPhone Duo's open inner display in landscape: the tabs and the mini
/// player keep the leading half, and the full Now Playing screen fills the trailing half instead
/// of opening as a cover. Never active on any other device or pose.
final class DuoSplit: ObservableObject {
    static let shared = DuoSplit()

    /// Posted by the podcast mini player when it is tapped while the split layout is in use.
    static let showPodcastPlayer = Notification.Name("DuoSplitShowPodcastPlayer")

    /// Where the tabs' own headers start in the split: their 10pt top padding, below the 24pt
    /// strip the navigation bar takes while the system bars run down the side. The players'
    /// headers use it to sit level with them.
    static func headerTopPadding(isBarOnSide: Bool) -> CGFloat {
        isBarOnSide ? 34 : 10
    }

    /// Share of the width given to Now Playing; the list keeps the rest. A little over half
    /// gives the artwork and controls room without cramping the list.
    private static let paneShare: CGFloat = 0.56

    /// How much larger the players draw their artwork in the split, to use that room.
    static let artworkScale: CGFloat = 1.15

    /// Narrower than this, two halves are too cramped to be useful (iPhone Duo's outer display).
    private static let minimumWidth: CGFloat = 700

    /// True while the app's content area is wide enough, and wider than tall, on a foldable.
    /// The mini players check this: a tap then goes to the tab that shows their player beside
    /// it instead of opening the player as a cover.
    @Published private(set) var isWide = false

    /// Width of the Now Playing half.
    @Published private(set) var paneWidth: CGFloat = 0

    /// Width of the system's side column (status items, tab bar, toolbar) beside the content.
    @Published private(set) var sideColumnWidth: CGFloat = 0

    func update(contentSize size: CGSize, trailingInset: CGFloat) {
        let wide = FoldableDevice.shared.hasHinge && size.width > size.height && size.width >= Self.minimumWidth
        let width = wide ? (size.width * Self.paneShare).rounded(.down) : 0
        if wide != isWide { isWide = wide }
        if abs(width - paneWidth) > 0.5 { paneWidth = width }
        if abs(trailingInset - sideColumnWidth) > 0.5 { sideColumnWidth = trailingInset }
    }
}

private struct DuoSplitPaneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for a full player shown as the Now Playing half of the iPhone Duo split, where there
    /// is nothing to dismiss.
    var isDuoSplitPane: Bool {
        get { self[DuoSplitPaneKey.self] }
        set { self[DuoSplitPaneKey.self] = newValue }
    }
}

/// A screen title pinned to the leading edge of the top bar.
///
/// Used on iPhone Duo, where the bar's buttons move to the side of the display: a centred title
/// would be left floating on its own, so it reads better at the leading edge. A custom view is
/// never moved into the vertical bar, so the title stays put.
struct DuoLeadingTitleItem: ToolbarContent {
    let title: String

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.adaptivePrimaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// Detents for the app's bottom sheets.
///
/// iPhone Duo's outer display is short: a half-height sheet there shows only the first row or
/// two of its content, so it opens at one taller height instead. It deliberately stops short of
/// the status items in the side column and has no `.large` detent there: a sheet that reaches
/// them gets its content inset from the trailing edge, which leaves the cards off-centre.
/// Every other device keeps the detents it is given.
private struct AdaptiveSheetDetents: ViewModifier {
    @ObservedObject private var tabBarClearance = TabBarClearance.shared
    let regular: Set<PresentationDetent>
    let duoFraction: CGFloat

    func body(content: Content) -> some View {
        content.presentationDetents(tabBarClearance.isBarOnSide ? [.fraction(duoFraction)] : regular)
    }
}

/// Balances a bottom sheet's content on iPhone Duo.
///
/// The system insets sheet content from the trailing edge there to keep it out of the side
/// column, even though these sheets open below the status items. That left the cards off-centre
/// with a dead strip beside them, so the content is widened back into the strip. A no-op on
/// every other device, where the leading and trailing insets are equal.
private struct DuoSheetBalance: ViewModifier {
    @ObservedObject private var tabBarClearance = TabBarClearance.shared
    let sidePadding: CGFloat

    func body(content: Content) -> some View {
        if tabBarClearance.isBarOnSide {
            GeometryReader { geometry in
                let strip = max(0, geometry.safeAreaInsets.trailing - geometry.safeAreaInsets.leading)
                content
                    .padding(.horizontal, sidePadding)
                    .padding(.trailing, -strip)
            }
        } else {
            content
        }
    }
}

extension View {
    func duoSheetBalance(sidePadding: CGFloat = 0) -> some View {
        modifier(DuoSheetBalance(sidePadding: sidePadding))
    }

    func adaptiveSheetDetents(_ regular: Set<PresentationDetent>, duoFraction: CGFloat = 0.72) -> some View {
        modifier(AdaptiveSheetDetents(regular: regular, duoFraction: duoFraction))
    }

    /// Sets `isLandscape` while this view is wider than it is tall on iPhone Duo, such as the open
    /// inner display in landscape, where full-size player artwork leaves too little height for
    /// the rest of the page. Always false on every other device.
    func trackDuoLandscape(_ isLandscape: Binding<Bool>) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            FoldableDevice.shared.hasHinge && proxy.size.width > proxy.size.height
        } action: { newValue in
            isLandscape.wrappedValue = newValue
        }
    }

}

/// The hand-drawn grabber at the top of the app's bottom sheets. The system already draws one,
/// and on iPhone Duo's short display the second one only costs height, so it is dropped there.
struct SheetGrabber: View {
    @ObservedObject private var tabBarClearance = TabBarClearance.shared

    var body: some View {
        if !tabBarClearance.isBarOnSide {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
        } else {
            Color.clear.frame(height: 14)
        }
    }
}

/// Invisible hook that lets `TabBarClearance` reach the UIKit window behind the SwiftUI hierarchy.
struct TabBarClearanceProbe: UIViewRepresentable {
    let isActive: Bool

    /// Re-measures whenever its own layout changes, so a fold, unfold or resize that moves the
    /// tab bar is picked up even when SwiftUI has no reason to update the representable.
    final class ProbeView: UIView {
        var isActive = true

        override func layoutSubviews() {
            super.layoutSubviews()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                FoldableDevice.shared.observe(self.window)
                TabBarClearance.shared.measure(from: self, includeTabBar: self.isActive)
            }
        }
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isActive = isActive
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.isActive = isActive
        DispatchQueue.main.async {
            TabBarClearance.shared.measure(from: uiView, includeTabBar: isActive)
        }
    }
}

/// Global player that displays across all main views (except sheet views)
/// Shows either podcast or radio player depending on what's currently playing
/// Uses the same positioning and logic as ContentView
struct GlobalPlayerView: View {
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var podcastPlayer: PodcastPlayer
    @EnvironmentObject var podcastViewModel: PodcastViewModel
    
    @Binding var selectedPodcast: PodcastFeed?
    @Binding var isPlayerSheetPresented: Bool
    @Binding var selectedTab: Tab
    @Binding var isFooterMenuHidden: Bool
    @Binding var isScrolling: Bool
    
    @State private var scrollToEpisodeID: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Player area with home button - prioritize based on last active player
            if shouldShowPodcastPlayerFirst,
               let currentEpisode = podcastPlayer.currentEpisode,
               let currentFeed = podcastPlayer.currentFeed {
                // Show podcast player only when we have both episode and feed loaded
                HStack(spacing: 8) {
                    // Home button on the left (only shows when scrolling)
                    HomeButton(isFooterMenuHidden: $isFooterMenuHidden, isScrolling: $isScrolling)
                        .zIndex(1) // Ensure home button is above player to prevent tap-through
                    
                    // Podcast player with smooth animation
                    CompactPodcastPlayerView(
                        currentEpisode: currentEpisode,
                        currentFeed: currentFeed,
                        podcastPlayer: podcastPlayer,
                        viewModel: podcastViewModel,
                        selectedPodcast: $selectedPodcast,
                        onListButtonTap: {
                            // Switch to podcast tab and set the current feed
                            selectedPodcast = currentFeed
                            podcastViewModel.requestFeedRefresh(currentFeed.id)
                            selectedTab = .podcast
                        },
                        onCloseButtonTap: {
                            // Do not dismiss the player when closing; just pause and keep it visible
                            podcastPlayer.pause()
                        }
                    )
                    .zIndex(0) // Player is below home button
                }
                .padding(.horizontal, playerHorizontalPadding)
            } else if shouldShowRadioPlayerFirst {
                // STABILITY FIX: Show radio player with stable station display and home button
                if let currentStation = radioPlayer.currentlyPlayingStation {
                    // CRITICAL: Use radioPlayer.currentlyPlayingStation as the source of truth for display
                    // This ensures station info remains consistent regardless of country switching or auto-play
                    HStack(spacing: 8) {
                        // Home button on the left (only shows when scrolling)
                        HomeButton(isFooterMenuHidden: $isFooterMenuHidden, isScrolling: $isScrolling)
                            .zIndex(1) // Ensure home button is above player to prevent tap-through
                        
                        // Radio player with smooth animation
                        CompactPlayerView(currentStation: currentStation, metadata: radioPlayer.metadata, isPlayerSheetPresented: $isPlayerSheetPresented)
                            .environmentObject(radioPlayer)
                            .environmentObject(viewModel)
                            .zIndex(0) // Player is below home button
                    }
                    .padding(.horizontal, playerHorizontalPadding)
                    .padding(.bottom, 0)
                } else if !viewModel.stations.isEmpty && shouldShowRadioPlayerFirst {
                    // Show first available station as default when no station is set and radio should be prioritized
                    let defaultStation = viewModel.stations.first!
                    HStack(spacing: 8) {
                        // Home button on the left (only shows when scrolling)
                        HomeButton(isFooterMenuHidden: $isFooterMenuHidden, isScrolling: $isScrolling)
                            .zIndex(1) // Ensure home button is above player to prevent tap-through
                        
                        // Radio player with smooth animation
                        CompactPlayerView(currentStation: defaultStation, metadata: nil, isPlayerSheetPresented: $isPlayerSheetPresented)
                            .environmentObject(radioPlayer)
                            .environmentObject(viewModel)
                            .zIndex(0) // Player is below home button
                    }
                    .padding(.horizontal, playerHorizontalPadding)
                    .padding(.bottom, 0)
                }
            }
        }
        .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 600 : .infinity)
        // Network status floats just above the mini-player without taking layout space.
        .overlay(alignment: .top) {
            PlaybackStatusPill()
                .alignmentGuide(.top) { $0[.bottom] + 8 }
        }
        .background(
            // Invisible background to block tap-through while allowing button interactions
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .allowsHitTesting(true)
        )
    }
    
    /// Determines if podcast player should be shown
    /// Shows podcast player when there's a current episode and feed loaded
    /// Player stays visible whether playing, paused, or stopped
    private var shouldShowPodcastPlayer: Bool {
        // Show player whenever there's a current episode and feed
        // This keeps the player visible even when paused
        return podcastPlayer.currentEpisode != nil && podcastPlayer.currentFeed != nil
    }
    
    /// Determines if radio player should be shown
    /// Shows radio player when there's a current station set
    /// Player stays visible whether playing, paused, or stopped
    private var shouldShowRadioPlayer: Bool {
        // Show player whenever there's a current station
        // This keeps the player visible even when paused
        return radioPlayer.currentlyPlayingStation != nil
    }
    
    /// Determines if podcast player should be prioritized based on last active player
    private var shouldShowPodcastPlayerFirst: Bool {
        let lastActivePlayer = PlaybackManager.shared.getLastActivePlayer()
        
        // If podcast was the last active player, prioritize it (even without content loaded yet)
        if lastActivePlayer == .podcast {
            return true
        }
        
        // If only podcast has content, show it
        if shouldShowPodcastPlayer && !shouldShowRadioPlayer {
            return true
        }
        
        // If both have content, check last active player
        if shouldShowPodcastPlayer && shouldShowRadioPlayer {
            return lastActivePlayer == .podcast
        }
        
        // Default: don't show podcast first
        return false
    }
    
    /// Consistent horizontal padding for the player
    /// Player maintains the same size regardless of scrolling state and TabView visibility
    /// Same padding whether TabView is visible or hidden for consistent appearance
    private var playerHorizontalPadding: CGFloat {
        // Consistent padding in all states to match screenshot spacing
        return 24
    }
    
    /// Determines if radio player should be prioritized based on last active player
    private var shouldShowRadioPlayerFirst: Bool {
        let lastActivePlayer = PlaybackManager.shared.getLastActivePlayer()
        
        // If radio was the last active player, prioritize it
        if lastActivePlayer == .radio {
            return true
        }
        
        // If podcast was the last active player, don't show radio first
        if lastActivePlayer == .podcast {
            return false
        }
        
        // If only radio has content, show it
        if shouldShowRadioPlayer && !shouldShowPodcastPlayer {
            return true
        }
        
        // If both have content, check last active player
        if shouldShowPodcastPlayer && shouldShowRadioPlayer {
            return lastActivePlayer == .radio
        }
        
        // Default: show radio if it has content and no last active player preference
        return shouldShowRadioPlayer
    }
    
}

// MARK: - Home Button Component

struct HomeButton: View {
    @Binding var isFooterMenuHidden: Bool
    @Binding var isScrolling: Bool
    @Environment(\.colorScheme) var colorScheme
    
    // The button is the only way back to the tab bar, so its visibility has to be derived from
    // the menu state. A latched @State flag resets whenever the player is rebuilt, which stranded
    // the user with no tab bar and no way to restore it.
    //
    // When the system puts the tab bar down the side (iPhone Duo) it stays on screen while
    // scrolling, so there is nothing to bring back and the button would only crowd the player.
    @ObservedObject private var tabBarClearance = TabBarClearance.shared
    private var shouldShow: Bool { (isFooterMenuHidden || isScrolling) && !tabBarClearance.isBarOnSide }
    
    // Computed properties for adaptive colors
    private var iconColor: Color {
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
    
    var body: some View {
        Group {
            if shouldShow {
                Button(action: {
                    print("🏠 HOME BUTTON: Tapped - forcing TabView to show")
                    // Use smooth animation for TabView restoration
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        // CRITICAL: Always force TabView to show regardless of current state
                        isFooterMenuHidden = false // Show TabView when tapped
                        isScrolling = false // Stop scrolling state immediately
                    }
                    
                    // SAFETY: Post notification to ensure all views reset their scrolling state
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ForceTabViewVisible"),
                        object: nil,
                        userInfo: ["source": "HomeButton"]
                    )
                    
                    print("🏠 HOME BUTTON: TabView restoration complete - isFooterMenuHidden: \(isFooterMenuHidden), isScrolling: \(isScrolling)")
                }) {
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 55, height: 55)
                        
                        // Glass gradient overlay for more depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 55, height: 55)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .frame(width: 55, height: 55)
                        
                        Image(systemName: "house.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(iconColor)
                            .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(PlainButtonStyle())
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.3).combined(with: .opacity).combined(with: .move(edge: .leading)),
                    removal: .scale(scale: 0.8).combined(with: .opacity).combined(with: .move(edge: .leading))
                ))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: shouldShow)
    }
}

 
