import StoreKit
import StreamRadiosCore
import SwiftUI

/// StreamRadios Pro status on the Watch: StoreKit (shared Apple Account purchases) OR the iPhone's status.
@MainActor
@Observable
final class WatchEntitlementStore {
    enum Status: Equatable { case unknown, entitled, notEntitled }

    /// Same App Store products as the iPhone paywall (yearly subscription with trial, lifetime purchase).
    static let productIDs = ["StreamRadiosPro", "STR12RA"]

    private(set) var status: Status
    private(set) var products: [Product] = []
    private(set) var isWorking = false
    private(set) var message: String?
    private(set) var canMakePayments = AppStore.canMakePayments
    private(set) var isEligibleForIntroOffer = false

    /// Browsing is free; only playback needs Pro. Unknown is allowed so subscribers never get blocked by a slow check.
    var isPlaybackAllowed: Bool { status != .notEntitled }

    @ObservationIgnored private var storeKitEntitled = false
    @ObservationIgnored private var storeKitChecked = false
    @ObservationIgnored private var phoneEntitled: Bool?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private let cacheKey = "watchEntitlementCache"

    init() {
        if let cached = UserDefaults.standard.object(forKey: cacheKey) as? Bool {
            status = cached ? .entitled : .notEntitled
        } else {
            status = .unknown
        }
    }

    func start() async {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update { await transaction.finish() }
                    await self?.refresh()
                }
            }
        }
        await refresh()
        await loadProducts()
    }

    func loadProducts() async {
        canMakePayments = AppStore.canMakePayments
        if products.isEmpty {
            products = ((try? await Product.products(for: Self.productIDs)) ?? []).sorted { $0.price < $1.price }
        }
        if let subscription = products.first(where: { $0.subscription != nil })?.subscription {
            isEligibleForIntroOffer = await subscription.isEligibleForIntroOffer
        }
    }

    func refresh() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expiration = transaction.expirationDate, expiration < .now { continue }
            entitled = true
        }
        storeKitEntitled = entitled
        storeKitChecked = true
        recompute()
    }

    func applyPhone(_ value: Bool?) {
        guard let value else { return }
        phoneEntitled = value
        recompute()
    }

    func purchase(_ product: Product) async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification { await transaction.finish() }
                await refresh()
            case .pending:
                message = "Purchase is waiting for approval."
            default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do { try await AppStore.sync() } catch { message = error.localizedDescription }
        await refresh()
        if status != .entitled, message == nil { message = "No active purchase found for this Apple Account." }
    }

    private func recompute() {
        let newStatus: Status
        if storeKitEntitled || phoneEntitled == true {
            newStatus = .entitled
        } else if storeKitChecked {
            // Only lock after StoreKit answered, so a slow check never flashes the paywall at subscribers.
            newStatus = .notEntitled
        } else {
            return
        }
        guard newStatus != status else { return }
        status = newStatus
        UserDefaults.standard.set(newStatus == .entitled, forKey: cacheKey)
    }
}

/// Sign-up screen following Apple's watchOS in-app purchase guidance: what the subscription includes on Watch,
/// each plan locked up with its price/duration/trial terms, restore, and Terms/Privacy links.
private struct WatchPaywallView: View {
    let store: WatchEntitlementStore
    let onCheckIPhone: () -> Void
    @State private var legalDocument: WatchLegalDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 4) {
                    Image(systemName: "crown.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                    Text("StreamRadios Pro")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)

                Text("Play radio stations and podcasts on Apple Watch, with favorites, progress and downloads kept in sync with your iPhone and CarPlay. One purchase unlocks StreamRadios on all your devices.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.canMakePayments {
                    if store.products.isEmpty {
                        ProgressView("Loading plans")
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(store.products, id: \.id) { product in
                        planOption(for: product)
                    }
                    if !store.products.isEmpty {
                        Text("Buying on Apple Watch needs your Apple Account signed in to the App Store (Watch app on iPhone > App Store).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Purchases are restricted on this Apple Watch. Ask the account owner, or subscribe in StreamRadios on your iPhone.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message = store.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Restore Purchases") {
                    Task { await store.restore() }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)

                Divider()

                Text("Prefer your iPhone? Subscribe in StreamRadios on iPhone and your Apple Watch unlocks automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onCheckIPhone()
                    Task { await store.refresh() }
                } label: {
                    Label("I Subscribed on iPhone", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }

                Text("Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. Payment is charged to your Apple Account. Manage or cancel in your Apple Account settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // watchOS can't open web pages, so the documents are shown natively.
                VStack(spacing: 6) {
                    Button {
                        legalDocument = .terms
                    } label: {
                        Label("Terms of Use", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        legalDocument = .privacy
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption2)
            }
            .padding(.horizontal, 6)
        }
        .sheet(item: $legalDocument) { document in
            WatchLegalDocumentView(document: document)
        }
        .disabled(store.isWorking)
        .overlay {
            if store.isWorking { ProgressView() }
        }
        .task { await store.loadProducts() }
    }

    /// Each purchase button is locked up with its own terms so they stay together while scrolling.
    private func planOption(for product: Product) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                Task { await store.purchase(product) }
            } label: {
                VStack(spacing: 1) {
                    Text(product.displayName)
                        .font(.footnote.weight(.semibold))
                    Text(headline(for: product))
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .foregroundStyle(.black)

            Text(terms(for: product))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headline(for product: Product) -> String {
        guard let subscription = product.subscription else { return "\(product.displayPrice) one-time" }
        if store.isEligibleForIntroOffer, let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial {
            return "\(periodText(offer.period, count: offer.periodCount)) free"
        }
        return "\(product.displayPrice) / \(unitText(subscription.subscriptionPeriod.unit))"
    }

    private func terms(for product: Product) -> String {
        guard let subscription = product.subscription else {
            return "Lifetime access for \(product.displayPrice). One-time purchase; does not renew."
        }
        let period = unitText(subscription.subscriptionPeriod.unit)
        if store.isEligibleForIntroOffer, let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial {
            return "\(periodText(offer.period, count: offer.periodCount)) free trial, then \(product.displayPrice) per \(period). Renews automatically each \(period) until canceled."
        }
        return "\(product.displayPrice) per \(period). Renews automatically each \(period) until canceled."
    }

    private func periodText(_ period: Product.SubscriptionPeriod, count: Int) -> String {
        let total = period.value * max(count, 1)
        let unit = unitText(period.unit)
        return "\(total)-\(unit)"
    }

    private func unitText(_ unit: Product.SubscriptionPeriod.Unit) -> String {
        switch unit {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        @unknown default: "period"
        }
    }
}

/// Full text of the published legal pages (autoforms.github.io/streamradios/terms.html and privacy.html).
/// Keep in sync with those pages and the iPhone's TermsAndConditionsView when they change.
private enum WatchLegalDocument: String, Identifiable {
    case terms, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: "Terms of Use"
        case .privacy: "Privacy Policy"
        }
    }

    var sections: [(heading: String, lines: [String])] {
        switch self {
        case .terms: Self.termsSections
        case .privacy: Self.privacySections
        }
    }

    private static let termsSections: [(heading: String, lines: [String])] = [
        ("", ["StreamRadios — Terms of Use (EULA)", "Last updated: 27 August 2026"]),
        ("Agreement", [
            "These Terms of Use form the End User License Agreement (EULA) between you and StreamRadios for the StreamRadios application. By downloading, installing, or using the app you agree to these terms. If you do not agree, do not use the app."
        ]),
        ("Subscriptions, Free Trial and Payments", [
            "StreamRadios offers the following purchases through the Apple App Store:",
            "• StreamRadios Pro — $9.99 per year, an auto-renewable subscription with a 7-day free trial for new subscribers.",
            "• Lifetime Access — $29.99, a one-time, non-renewing purchase.",
            "Prices are in U.S. dollars and may vary by storefront. The price shown at the point of purchase in the app is the price that applies to you."
        ]),
        ("Billing and automatic renewal", [
            "• Payment is charged to your Apple Account at confirmation of purchase.",
            "• The subscription renews automatically for the same period at the same price unless auto-renew is turned off at least 24 hours before the end of the current period.",
            "• Your Apple Account is charged for renewal within 24 hours prior to the end of the current period.",
            "• You can manage your subscription and turn off auto-renewal in your device's Settings under your Apple Account subscriptions, at any time after purchase.",
            "• Any unused portion of a free trial is forfeited when you purchase a subscription.",
            "• Deleting the app does not cancel a subscription; you must cancel through your Apple Account."
        ]),
        ("Refunds", [
            "Purchases are processed by Apple, and refunds are handled by Apple according to its policies. StreamRadios cannot issue refunds directly. Refund requests can be submitted at reportaproblem.apple.com."
        ]),
        ("Platform Access and User Responsibilities", [
            "StreamRadios provides audio streaming services exclusively for individual, personal entertainment. The app is designed for personal use only and may not be used for commercial purposes or public broadcasting. Users must comply with all applicable laws while using the service — any attempts to circumvent security measures, reverse engineer the software, or interfere with the app's functionality may violate these terms and applicable laws.",
            "All user data, including favorites, downloads, and preferences, is stored securely in the user's personal iCloud account. StreamRadios does not collect, store, or have access to personal user information, ensuring complete privacy and data ownership remains with the individual user.",
            "Mobile users are responsible for all carrier fees, data usage charges, and related telecommunications costs incurred while using StreamRadios. Streaming audio content may consume significant data, so users should monitor their data usage according to their mobile plan."
        ]),
        ("Third-Party Audio Content", [
            "StreamRadios aggregates audio content from various sources including:",
            "• Live radio stations, podcasts, and streaming audio programming",
            "• User-submitted media including images, text, audio files, artwork, and multimedia content",
            "• External website links and internet resources",
            "Audio content available through StreamRadios belongs to the original creators and broadcasters. This material is protected under copyright law and international treaties. Users cannot copy, redistribute, create derivatives, or publicly broadcast any content without explicit permission from the rights holders, except where fair use applies.",
            "Content providers may implement digital rights management (DRM) and other technological protection measures. These systems can limit or block content playback, and StreamRadios has no control over these restrictions. We cannot guarantee uninterrupted access to any particular audio stream or content.",
            "Users who attempt to circumvent, disable, or tamper with content protection systems violate these terms and may face legal action and account deletion.",
            "StreamRadios acts as a content aggregator and does not create or control the audio programming available on our platform. We make no guarantees about:",
            "• Continuous availability of specific stations or programs",
            "• Audio quality or streaming reliability",
            "• Content accuracy, appropriateness, or legal compliance",
            "• Broadcasting schedules or program changes",
            "Content providers may modify, remove, or restrict their programming without notice to StreamRadios or our users."
        ]),
        ("Software Rights and Usage Restrictions", [
            "The StreamRadios application contains proprietary code and intellectual property owned by StreamRadios and our licensors. Users receive a personal, non-transferable license to use our software for accessing audio content only. This license does not permit:",
            "• Reverse engineering, decompiling, or extracting source code",
            "• Automated data collection, scraping, or systematic downloading",
            "• Creating competing services or derivative applications",
            "• Removing copyright notices or proprietary markings",
            "StreamRadios actively protects intellectual property rights and expects users to do the same. We will investigate reported copyright violations and remove infringing content when notified by rights holders. Repeat offenders will have their accounts permanently suspended."
        ]),
        ("Copyright Violation Reporting", [
            "Rights holders who believe their content is being used without authorization on StreamRadios should submit a formal takedown request to support@streamradios.app. Valid notices must include:",
            "• Clear identification of the copyrighted work",
            "• Location of the allegedly infringing content on our platform",
            "• Contact information for the rights holder or authorized representative",
            "• A statement of good faith belief that the use is unauthorized",
            "• Declaration that the information provided is accurate",
            "Upon receiving valid takedown notices, StreamRadios will promptly remove the disputed content and notify the user who posted it."
        ]),
        ("Apple App Store Terms", [
            "StreamRadios available through Apple's App Store is governed by this agreement between you and StreamRadios only. Apple is not a party to these terms and has no responsibility for our application or its content.",
            "Apple provides no technical support, maintenance, or warranties for StreamRadios. If you experience technical issues, contact StreamRadios directly. Apple's only obligation is to refund purchase prices for defective applications when notified.",
            "Apple is not liable for any claims related to StreamRadios including:",
            "• Product defects or consumer protection violations",
            "• Failure to meet local regulatory requirements",
            "• Intellectual property disputes",
            "Apple and its subsidiaries are third-party beneficiaries of this agreement and, upon your acceptance, have the right to enforce it against you. Users must comply with Apple's App Store terms of service when using StreamRadios on iOS devices."
        ]),
        ("General Mobile Platform Requirements", [
            "Regardless of your mobile platform, users agree to:",
            "• Follow all applicable app store guidelines and policies",
            "• Respect platform-specific content restrictions",
            "• Maintain appropriate device security and software updates",
            "• Report technical issues through proper channels",
            "StreamRadios reserves the right to modify these terms as needed to maintain compliance with evolving mobile platform requirements."
        ]),
        ("Contact", ["Questions about these terms can be sent to support@streamradios.app."])
    ]

    private static let privacySections: [(heading: String, lines: [String])] = [
        ("", ["StreamRadios — Privacy Policy", "Last updated: 27 August 2026"]),
        ("Our Commitment to Privacy", [
            "At StreamRadios, we respect your privacy and are committed to protecting it. This Privacy Policy explains our practices regarding the handling of your information and how we ensure your privacy is maintained."
        ]),
        ("Information We Do Not Collect", [
            "StreamRadios does not collect or store any personal information from our users. We do not track your activities, nor do we gather any personal data such as names, email addresses, or location data."
        ]),
        ("Data Storage and Security", [
            "iCloud Account: All data related to your radio stations and favorites is stored locally on your device and backed up to your personal iCloud account. This data is governed by Apple's iCloud privacy and security measures and is not accessible by StreamRadios or any third parties."
        ]),
        ("Purchases", [
            "Subscriptions and one-time purchases are processed entirely by Apple through the App Store. StreamRadios never receives or stores your payment details. Purchase terms are described in our Terms of Use."
        ]),
        ("Changes to This Privacy Policy", [
            "We may update this Privacy Policy from time to time. Any changes will be posted on this page with an updated revision date."
        ]),
        ("Contact Us", [
            "If you have any questions or concerns about our privacy practices, please contact us at support@streamradios.app."
        ])
    ]
}

private struct WatchLegalDocumentView: View {
    let document: WatchLegalDocument
    @State private var showContact = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        if !section.heading.isEmpty {
                            Text(section.heading)
                                .font(.footnote.weight(.semibold))
                        }
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(section.heading.isEmpty ? .primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if line.contains(SRSupportContact.email) {
                                Button {
                                    showContact = true
                                } label: {
                                    Label(SRSupportContact.email, systemImage: "envelope.fill")
                                        .font(.caption2.weight(.semibold))
                                        .underline()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.mint)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(document.title)
        .sheet(isPresented: $showContact) {
            WatchContactSupportView()
        }
    }
}

/// Offers the email to the iPhone via Handoff while visible, since watchOS can't compose email.
private struct WatchContactSupportView: View {
    // Retained explicitly: SwiftUI's .userActivity inside a sheet didn't reliably become current.
    @State private var activity: NSUserActivity?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title3)
                    .foregroundStyle(.mint)
                Text("Email Support")
                    .font(.headline)
                Text(SRSupportContact.email)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("On your iPhone, tap the StreamRadios Handoff banner in the App Switcher to open a new email to us.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Not nearby? Email the address above from any device.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
        }
        .onAppear {
            let handoff = NSUserActivity(activityType: SRSupportContact.handoffActivityType)
            handoff.title = "Email StreamRadios Support"
            handoff.isEligibleForHandoff = true
            handoff.userInfo = ["email": SRSupportContact.email]
            handoff.becomeCurrent()
            activity = handoff
        }
        .onDisappear {
            activity?.invalidate()
            activity = nil
        }
    }
}

struct WatchRootView: View {
    private static let favoriteStationLimit = 40
    @Environment(\.scenePhase) private var scenePhase
    private enum LibraryTab: Hashable {
        case radio
        case podcasts
    }

    private enum RadioMode: CaseIterable, Hashable {
        case recent
        case favorites
        case all

        var title: String {
            switch self {
            case .recent: "Recent"
            case .favorites: "Favorites"
            case .all: "All"
            }
        }

        var systemImage: String {
            switch self {
            case .recent: "clock.fill"
            case .favorites: "heart.fill"
            case .all: "list.bullet"
            }
        }
    }

    @State private var library = WatchLibraryStore()
    @State private var radioDirectory = WatchRadioDirectory()
    @State private var podcasts = WatchPodcastLibrary()
    @State private var player = WatchAudioPlayer()
    @State private var selectedTab = LibraryTab.radio
    @State private var radioMode = RadioMode.recent
    @State private var showNowPlaying = false
    @State private var entitlements = WatchEntitlementStore()
    @State private var showPhoneUnavailableAlert = false

    var body: some View {
        ZStack {
            NavigationStack {
                List {
                librarySwitcher
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 6, trailing: 4))

                Section {
                    Button {
                        showNowPlaying = true
                    } label: {
                        HStack(spacing: 10) {
                            WatchArtworkView(
                                url: player.artworkURL,
                                data: player.artworkData,
                                systemImage: player.item?.systemImage ?? "waveform"
                            )
                            .frame(width: 46, height: 46)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("PLAY NOW")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                Text(player.item?.title ?? "Nothing Playing")
                                    .font(.headline)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)
                            Image(systemName: player.isPlaybackRequested ? "waveform" : "play.fill")
                                .foregroundStyle(Color.accentColor)
                                .playingWaveEffect(player.isPlaying)
                        }
                    }
                }

                Section(selectedTab == .radio ? radioMode.title : "Subscriptions") {
                    switch selectedTab {
                    case .radio:
                        radioLibrary
                    case .podcasts:
                        podcastLibrary
                    }
                }

                refreshButton
            }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: $showNowPlaying) {
                    WatchNowPlayingView(player: player)
                }
            }

            if !library.hasCompletedInitialSync {
                initialSyncView
            }

            // Hard paywall like the iPhone app; the library keeps syncing underneath so it's ready on unlock.
            if library.hasCompletedInitialSync, entitlements.status == .notEntitled {
                WatchPaywallView(store: entitlements) {
                    Task { await library.reload() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .transition(.opacity)
            }

            if let result = library.manualSyncResult {
                syncResultBanner(result)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: library.manualSyncResult)
        .animation(.easeInOut(duration: 0.25), value: entitlements.status)
        .task {
            player.canStartPlayback = { [entitlements] in entitlements.isPlaybackAllowed }
            player.onPlaybackBlocked = nil
            entitlements.applyPhone(library.phoneEntitlement)
            await entitlements.start()
        }
        .onChange(of: library.phoneEntitlement) { _, value in
            entitlements.applyPhone(value)
        }
        .onChange(of: entitlements.status) { _, status in
            if status == .notEntitled { player.pauseForPaywall() }
        }
        .task {
            player.onEpisodeStateChange = { state in
                library.applyLocalEpisodeState(state)
            }
            player.savedEpisodeState = { episode in
                library.episodeState(for: episode)
            }
            player.onStationPlaybackStarted = { station in
                library.recordPlayedStation(station)
            }
            await library.loadIfNeeded()
            refreshPlayerArtwork()
        }
        .onChange(of: library.favoriteStations) { _, _ in
            refreshPlayerArtwork()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.checkpoint() }
            if phase == .active {
                library.refreshConnectionState()
                library.flushSync()
                library.requestFullSyncIfDue()
                Task { await entitlements.refresh() }
            }
        }
        .onChange(of: library.recentStations) { _, _ in
            refreshPlayerArtwork()
        }
        .onChange(of: library.podcastFeeds) { _, feeds in
            player.refreshFeedArtwork(from: feeds)
        }
        .onChange(of: library.bootstrapEpisodes) { _, episodes in
            podcasts.installSeedEpisodes(episodes)
            player.refreshEpisodeMetadata(from: episodes)
        }
        .task(id: library.selectedCountryCode) {
            await radioDirectory.adoptSyncedCountry(
                name: library.selectedCountryName,
                code: library.selectedCountryCode
            )
        }
    }

    private var initialSyncView: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text("Sync from iPhone")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(syncInstructions)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.75)
                .frame(maxHeight: .infinity)
            Button {
                library.refreshConnectionState()
                if library.canRequestInitialSync {
                    Task { await library.requestInitialSync() }
                } else {
                    showPhoneUnavailableAlert = true
                }
            } label: {
                if library.isLoading {
                    ProgressView()
                } else {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.borderedProminent)
            // Stays tappable while unreachable so the tap can explain why sync is unavailable.
            .tint(library.canRequestInitialSync ? Color.accentColor : Color.gray)
            .opacity(library.canRequestInitialSync ? 1 : 0.45)
            .disabled(library.isLoading)
            .accessibilityHint(library.canRequestInitialSync ? "" : "Unavailable until your iPhone is connected")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task {
            while !Task.isCancelled, !library.hasCompletedInitialSync {
                library.refreshConnectionState()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("iPhone Not Connected", isPresented: $showPhoneUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Make sure your iPhone is turned on and nearby with Bluetooth or Wi-Fi on. Sync becomes available once it's connected.")
        }
    }

    private var syncInstructions: String {
        if case .failed(let message) = library.syncState { return message }
        return library.canRequestInitialSync
            ? "iPhone connected. Tap Sync to copy your stations and podcasts."
            : "Turn on your iPhone and keep it nearby to sync."
    }

    private var librarySwitcher: some View {
        HStack(spacing: 2) {
            libraryTabButton(.radio, systemImage: "radio.fill", label: "Radio")
            libraryTabButton(.podcasts, systemImage: "mic.fill", label: "Podcast")
        }
        .padding(3)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func refreshPlayerArtwork() {
        player.refreshStationArtwork(from: library.favoriteStations + library.recentStations)
    }

    private func libraryTabButton(
        _ tab: LibraryTab,
        systemImage: String,
        label: String
    ) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(selectedTab == tab ? Color.black : Color.secondary)
                .background(
                    selectedTab == tab ? Color.mint : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    @ViewBuilder
    private var radioLibrary: some View {
        radioModeSwitcher

        switch radioMode {
        case .recent:
            stationRows(
                library.recentStations,
                emptyMessage: "Stations you play will appear here."
            )
        case .favorites:
            stationRows(
                Array(library.favoriteStations.prefix(Self.favoriteStationLimit)),
                emptyMessage: "Favorite stations on iPhone will appear here."
            )
            if library.favoriteStations.count > Self.favoriteStationLimit {
                Text("Showing up to 40 favorite stations. For more favorites, open StreamRadios on your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
            }
        case .all:
            NavigationLink {
                WatchCountryPickerView(directory: radioDirectory)
            } label: {
                HStack {
                    Label(radioDirectory.selectedCountry.name, systemImage: "globe")
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if radioDirectory.isLoading && radioDirectory.stations.isEmpty {
                ProgressView("Loading stations")
            } else if let message = radioDirectory.errorMessage,
                      radioDirectory.stations.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                stationRows(
                    radioDirectory.stations,
                    emptyMessage: "No stations found for this country."
                )
                if !radioDirectory.stations.isEmpty {
                    Text("Up to 20 stations per country. For more stations, open StreamRadios on your iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    private func stationWithSyncedArtwork(_ station: SRRadioStationRecord) -> SRRadioStationRecord {
        let identity = SRWatchMutation.stationIdentity(station.streamURL)
        var result = station
        if let synced = (library.favoriteStations + library.recentStations).first(where: {
            SRWatchMutation.stationIdentity($0.streamURL) == identity
        }) {
            result.artworkData = synced.artworkData ?? station.artworkData
            result.artworkURL = synced.artworkURL ?? station.artworkURL
        }
        return result
    }

    private func isCurrentStation(_ station: SRRadioStationRecord) -> Bool {
        guard case .radio(let current) = player.item else { return false }
        return SRWatchMutation.stationIdentity(current.streamURL) == SRWatchMutation.stationIdentity(station.streamURL)
    }

    private func liveArtworkURL(for station: SRRadioStationRecord) -> URL? {
        guard player.isPlaybackRequested, isCurrentStation(station) else { return nil }
        return player.radioArtworkURL
    }

    private var radioModeSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(RadioMode.allCases, id: \.self) { mode in
                Button {
                    radioMode = mode
                    if mode == .all {
                        Task { await radioDirectory.loadStations() }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: mode.systemImage)
                        Text(mode.title)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 35)
                    .foregroundStyle(radioMode == mode ? Color.white : Color.secondary)
                    .background(
                        radioMode == mode ? Color.red : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0))
    }

    @ViewBuilder
    private func stationRows(_ stations: [SRRadioStationRecord], emptyMessage: String) -> some View {
        if library.isLoading && stations.isEmpty && radioMode != .all {
            ProgressView()
        } else if stations.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("No stations", systemImage: "radio")
                Text(library.errorMessage ?? emptyMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(stations) { originalStation in
                let station = stationWithSyncedArtwork(originalStation)
                let isCurrent = isCurrentStation(station)
                HStack(spacing: 6) {
                    Button {
                        player.play(station)
                        showNowPlaying = true
                    } label: {
                        HStack(spacing: 9) {
                        WatchArtworkView(
                            url: liveArtworkURL(for: station) ?? station.artworkURL.flatMap(URL.init(string:)),
                            data: liveArtworkURL(for: station) == nil ? station.artworkData : nil,
                            systemImage: "radio.fill"
                        )
                        .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 2) {
                            if isCurrent {
                                Label(
                                    player.isPlaying ? "Playing" : player.isBuffering ? "Loading" : "Selected",
                                    systemImage: player.isPlaying ? "waveform" : player.isBuffering ? "hourglass" : "pause.fill"
                                )
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.mint)
                                .playingWaveEffect(player.isPlaying)
                            }
                            Text(station.name)
                                .font(.headline)
                                .lineLimit(2)
                            Text(station.country)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        library.toggleFavorite(station)
                    } label: {
                        Image(systemName: library.isStationFavorite(station) ? "heart.fill" : "heart")
                            .foregroundStyle(library.isStationFavorite(station) ? Color.red : Color.secondary)
                            .frame(width: 30, height: 38)
                    }
                    .buttonStyle(.plain)
                            .fixedSize()
                    .accessibilityLabel(library.isStationFavorite(station) ? "Remove favorite" : "Add favorite")
                }
                .listRowBackground(isCurrent ? Color.mint.opacity(0.16) : nil)
            }
        }
    }

    @ViewBuilder
    private var podcastLibrary: some View {
        if library.isLoading && library.podcastFeeds.isEmpty {
            ProgressView()
        } else if library.podcastFeeds.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("No subscriptions", systemImage: "mic")
                Text(library.errorMessage ?? "Podcast subscriptions on iPhone will appear here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(library.podcastFeeds) { feed in
                NavigationLink {
                    WatchPodcastEpisodesView(
                        feed: feed,
                        library: podcasts,
                        stateStore: library,
                        player: player,
                        showNowPlaying: $showNowPlaying
                    )
                } label: {
                    HStack(spacing: 9) {
                        WatchArtworkView(
                            url: feed.artworkURL.flatMap(URL.init(string:)),
                            data: feed.artworkData,
                            systemImage: "mic.fill"
                        )
                        .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(feed.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text("Podcast")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        Button {
            Task { await library.reload() }
        } label: {
            HStack(spacing: 6) {
                if library.isManualSyncing {
                    ProgressView()
                        .frame(width: 18, height: 18)
                    Text("Syncing…")
                } else {
                    Label("Sync Library", systemImage: "arrow.clockwise")
                }
            }
        }
        .disabled(library.isLoading || library.isManualSyncing)
    }

    private func syncResultBanner(_ result: WatchLibraryStore.ManualSyncResult) -> some View {
        let isFailure: Bool = if case .failed = result { true } else { false }
        return VStack {
            Label {
                Text(result.message)
                    .foregroundStyle(isFailure ? Color.black : Color.white)
            } icon: {
                Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isFailure ? Color.black : Color.mint)
            }
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isFailure ? Color.orange : Color(white: 0.2), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if !isFailure {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mint.opacity(0.6), lineWidth: 1)
                    }
                }
                .shadow(color: .black.opacity(0.6), radius: 6)
                .padding(.horizontal, 6)
            Spacer()
        }
        .padding(.top, 28)
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct WatchCountryPickerView: View {
    let directory: WatchRadioDirectory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(directory.countries) { country in
            Button {
                Task {
                    await directory.select(country)
                    dismiss()
                }
            } label: {
                HStack {
                    Text(country.name)
                        .lineLimit(1)
                    Spacer()
                    if country == directory.selectedCountry {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Country")
    }
}

private struct WatchPodcastEpisodesView: View {
    @State private var downloads = WatchEpisodeDownloads.shared
    @AppStorage("watchAutoDownload") private var autoDownload = false
    let feed: SRPodcastFeedRecord
    let library: WatchPodcastLibrary
    let stateStore: WatchLibraryStore
    let player: WatchAudioPlayer
    @Binding var showNowPlaying: Bool

    private var currentFeed: SRPodcastFeedRecord {
        stateStore.podcastFeeds.first { $0.id == feed.id } ?? feed
    }

    private func isCurrentEpisode(_ episode: SRPodcastEpisodeRecord) -> Bool {
        guard case .podcast(let current, _) = player.item else { return false }
        return current.feedID == episode.feedID
            && (current.id == episode.id || (!episode.audioURL.isEmpty && current.audioURL == episode.audioURL))
    }

    var body: some View {
        Group {
            if library.isLoading(feed), library.episodes(for: feed).isEmpty {
                ProgressView("Loading")
            } else if let message = library.errorMessage(for: feed), library.episodes(for: feed).isEmpty {
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            } else {
                List {
                    ForEach(library.episodes(for: feed)) { episode in
                        let state = stateStore.episodeState(for: episode)
                        let isCurrent = isCurrentEpisode(episode)
                        HStack(spacing: 6) {
                            Button {
                                player.play(episode, from: currentFeed, state: state)
                                showNowPlaying = true
                            } label: {
                                HStack(spacing: 9) {
                                WatchArtworkView(
                                    url: currentFeed.artworkURL.flatMap(URL.init(string:)),
                                    data: currentFeed.artworkData,
                                    systemImage: "mic.fill"
                                )
                                .frame(width: 40, height: 40)

                                VStack(alignment: .leading, spacing: 3) {
                                    if isCurrent {
                                        Label(
                                            player.isPlaying ? "Playing" : player.isBuffering ? "Loading" : "Selected",
                                            systemImage: player.isPlaying ? "waveform" : player.isBuffering ? "hourglass" : "pause.fill"
                                        )
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.mint)
                                        .playingWaveEffect(player.isPlaying)
                                    }
                                    Text(episode.title)
                                        .lineLimit(3)
                                    if downloads.localURL(for: episode) != nil {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .accessibilityLabel("Downloaded")
                                    }
                                    Text(episode.publicationDate, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if state?.isFinished == true {
                                        Label("Played", systemImage: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else if let progress = state?.progress, progress > 0 {
                                        ProgressView(value: progress)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                stateStore.toggleFavorite(episode)
                            } label: {
                                Image(systemName: state?.isFavorite == true ? "heart.fill" : "heart")
                                    .foregroundStyle(state?.isFavorite == true ? Color.red : Color.secondary)
                                    .frame(width: 30, height: 38)
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                            .accessibilityLabel(state?.isFavorite == true ? "Remove favorite" : "Add favorite")
                        }
                        .listRowBackground(isCurrent ? Color.mint.opacity(0.16) : nil)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if downloads.localURL(for: episode) != nil {
                                Button(role: .destructive) { downloads.remove(episode) } label: {
                                    Label("Remove Download", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .disabled(downloads.protectedURL == episode.audioURL)
                            } else if downloads.downloadingURL == episode.audioURL {
                                Button { downloads.cancel() } label: {
                                    Label("Cancel Download", systemImage: "xmark.circle")
                                        .labelStyle(.iconOnly)
                                }
                            } else {
                                Button { downloads.download(episode) } label: {
                                    Label("Download", systemImage: "arrow.down.circle")
                                        .labelStyle(.iconOnly)
                                }
                                .disabled(downloads.downloadingURL != nil || downloads.playbackIsActive)
                            }
                        }
                    }

                    if downloads.downloadingURL != nil { ProgressView("Downloading") }
                    if let error = downloads.errorMessage { Text(error).font(.caption2) }
                    Toggle("Download Recent While Charging", isOn: $autoDownload)
                        .onChange(of: autoDownload) { _, enabled in
                            if enabled { downloads.prefetch(library.episodes(for: feed)) }
                            else { downloads.cancel() }
                        }

                    Button {
                        Task { await library.loadEpisodes(for: feed, force: true) }
                    } label: {
                        Label("Refresh Episodes", systemImage: "arrow.clockwise")
                    }

                    Text("Up to 20 episodes per podcast. For more episodes, use StreamRadios on your iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle(feed.title)
        .task(id: feed.id) {
            await library.loadEpisodes(for: currentFeed, force: true)
            downloads.prefetch(library.episodes(for: feed))
        }
    }
}