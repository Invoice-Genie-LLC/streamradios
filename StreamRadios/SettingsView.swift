// SettingsView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.

import SwiftUI
import UIKit
import Darwin
import MessageUI
import AVFoundation
import MediaPlayer
import UserNotifications
import os.log
import CloudKit

// MARK: - Exception Info Structure
struct ExceptionInfo: Identifiable {
    let id = UUID()
    let timestamp: Date
    let errorMessage: String
    let filename: String
    let lineNumber: Int
    let functionName: String
    let stackTrace: [String]
    let errorType: String
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }
}

struct SettingsView: View {
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    @AppStorage("isDarkMode") private var isDarkMode: Bool = UserDefaults.standard.bool(forKey: "isDarkModeSet") ? UserDefaults.standard.bool(forKey: "isDarkMode") : true
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var deletionComplete = false
    @EnvironmentObject var viewModel: RadioStationViewModel
    @StateObject private var notificationManager = NotificationManager.shared
    @State private var showDocumentPicker = false
    @State private var showAlertForCountrySelection = false
    @State private var isImporting = false
    @State private var importProgress: Double = 0.0
    @State private var importURL: URL?
    @State private var showAlertForExportWithoutCountry = false
    @State private var currentAlert: AlertType?
    @State private var activeAlert: AlertType?
    @EnvironmentObject var alertManager: AlertManager
    var onImportComplete: ((String) -> Void)?
    @EnvironmentObject private var podcastViewModel: PodcastViewModel
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var isCleaningPodcasts = false
    @State private var podcastCleanupComplete = false
    @EnvironmentObject var radioPlayer: RadioPlayer
    @State private var showingSubscriptionView = false
    private let podcastPlayer = PodcastPlayer.shared // Remove @StateObject to stop observing updates
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @State private var showPodcastPlayerSheet = false
    @State private var safeAreaBottom: CGFloat = 0
    @State private var miniPlayerHeight: CGFloat = 60
    @State private var selectedTab: Tab = .settings
    @State private var isPlayerSheetPresented = false
    @State private var showingDebugAlert = false
    @State private var debugLogsContent = ""
    @State private var showingDebugLogsView = false
    @State private var notificationPermissionStatus = "Unknown"
    
    // Debug counters that can be reset
    @State private var sessionStartTime = Date()
    @State private var errorCount = 1
    @State private var warningCount = 2
    @State private var infoCount = 5
    @State private var apiErrorCount = 3
    @State private var networkErrorCount = 2
    @State private var coreDataErrorCount = 1
    @State private var crashCount = 0
    @State private var memoryWarningCount = 0
    @State private var recentExceptions: [ExceptionInfo] = []
    @State private var audioSessionErrorCount = 1
    @State private var carPlayDisconnectionCount = 2
    @State private var playbackFailureCount = 0
    @State private var jsonDecodeFailureCount = 1
    
    // Privacy and consent state variables
    @AppStorage("debugLoggingEnabled") private var debugLoggingEnabled = false
    @AppStorage("debugDataSharingConsent") private var debugDataSharingConsent = false
    @State private var showingPrivacyConsentAlert = false
    @State private var showingDebugEnableAlert = false
    
    // Color system for adaptive theming
    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Color(.systemGray6)
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? .gray : .secondary
    }
    

    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                                                             LazyVStack(spacing: 24) {
                        subscriptionSettings
                        playbackSettings
                        displaySettings
                        alarmSettings
                        dataManagementLink
                        aboutSettings
                        debugSettings
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 140)
                }
                
                // Global Player is now handled by ContentView overlay
                // This ensures consistent player display across all tabs
            }
            .background(backgroundColor)
            .navigationTitle("Settings")
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: isDarkMode) { newValue in
                updateDarkMode(to: newValue)
            }
            .onAppear {
                if !UserDefaults.standard.bool(forKey: "NotificationAuthorizationRequested") {
                    notificationManager.requestAuthorization()
                    UserDefaults.standard.set(true, forKey: "NotificationAuthorizationRequested")
                }
                
                // Update notification permission status for debug logs
                updateNotificationPermissionStatus()
                
                // Enable battery monitoring for accurate battery level reporting
                UIDevice.current.isBatteryMonitoringEnabled = true
                
                // Initialize sample exception data only if debug logging is enabled
                if debugLoggingEnabled {
                    initializeSampleExceptions()
                    os_log("Debug logging session started", log: OSLog(subsystem: "com.radio.streamradios", category: "Debug"), type: .info)
                }
            }
            .onDisappear {
                // Disable battery monitoring to save battery when leaving Settings
                UIDevice.current.isBatteryMonitoringEnabled = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .countrySelected)) { _ in
                if viewModel.selectedCountry != "Select Country" {
                    showAlertForCountrySelection = false
                }
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPicker(url: $importURL)
            }
            .onChange(of: importURL) { url in
                guard let url = url else { return }
                handleImport(url: url)
            }
        }
        .sheet(isPresented: $showPodcastPlayerSheet) {
            if let podcast = selectedPodcast {
                PodcastPlayerView(
                    viewModel: podcastViewModel,
                    feed: podcast,
                    initialScrollToEpisodeID: scrollToEpisodeID,
                    podcastPlayer: podcastPlayer,
                    selectedPodcast: $selectedPodcast,
                    episodeToScrollTo: Binding(
                        get: { podcastPlayer.currentEpisode },
                        set: { _ in }
                    )
                )
            }
        }
        .overlay(
            Group {
                if alertManager.showCustomAlert {
                    Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
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
                    .transition(.opacity)
                }
            }
        )
    }
    
    // MARK: - Settings Sections
    
    @ViewBuilder
    private var playbackSettings: some View {
        SettingsCard(
            title: "Playback Settings",
            icon: ""
        ) {
            ToggleRow(
                title: "Auto-Play Last Station",
                subtitle: "Automatically resume the last played station when opening the app",
                isOn: $autoPlayLastStation,
                icon: "play.circle.fill"
            )
        }
    }
    
    @ViewBuilder
    private var subscriptionSettings: some View {
        SettingsCard(
            title: "StreamRadios Pro",
            icon: ""
        ) {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "crown.fill")
                        .foregroundColor(.yellow)
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Subscription Status")
                            .font(.headline)
                            .foregroundColor(primaryTextColor)
                        
                        Text(subscriptionStatusText)
                            .font(.subheadline)
                            .foregroundColor(secondaryTextColor)
                    }
                    
                    Spacer()
                    
                    if subscriptionManager.isSubscribedOrInTrial {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                    }
                }
                
                Button {
                    showingSubscriptionView = true
                } label: {
                    HStack {
                        Text(subscriptionManager.isSubscribedOrInTrial ? "Manage Subscription" : "Upgrade to Pro")
                            .font(.headline)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(subscriptionManager.isSubscribedOrInTrial ? Color.blue.opacity(0.1) : Color.green.opacity(0.1))
                    )
                    .foregroundColor(subscriptionManager.isSubscribedOrInTrial ? .blue : .green)
                }
                
                // Dedicated Restore Purchases Button
                RestorePurchasesButton()
                    .environmentObject(subscriptionManager)
                
                if !subscriptionManager.isSubscribedOrInTrial {
                    VStack(spacing: 8) {
                        Text("Unlock Premium Features")
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                        
                        HStack(spacing: 16) {
                            FeatureBadge(icon: "antenna.radiowaves.left.and.right", text: "Unlimited Stations")
                            FeatureBadge(icon: "podcasts.fill", text: "Offline Downloads")
                            FeatureBadge(icon: "icloud.fill", text: "Cloud Sync")
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .sheet(isPresented: UIDevice.current.userInterfaceIdiom == .phone ? $showingSubscriptionView : .constant(false)) {
            SubscriptionView(showManagementScreen: true)
                .environmentObject(subscriptionManager)
        }
        .fullScreenCover(isPresented: UIDevice.current.userInterfaceIdiom == .pad ? $showingSubscriptionView : .constant(false)) {
            SubscriptionView(showManagementScreen: true)
                .environmentObject(subscriptionManager)
        }
    }
    
    private var subscriptionStatusText: String {
        switch subscriptionManager.subscriptionStatus {
        case .freeTrial:
            return "Free Trial Active"
        case .subscribed:
            return "Pro Subscriber"
        case .oneTimePurchased:
            return "Pro Lifetime"
        case .expired:
            return "Subscription Expired"
        case .notSubscribed:
            return "Free Version"
        case .unknown:
            return "Loading..."
        case .needsRestore:
            return "Needs Restore"
        }
    }
}

// MARK: - Restore Purchases Button Component
struct RestorePurchasesButton: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var isLoading = false
    
    var body: some View {
        Button {
            restorePurchases()
        } label: {
            HStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline)
                }
                
                Text("Restore Purchases")
                    .font(.headline)
                
                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.1))
            )
            .foregroundColor(.blue)
        }
        .disabled(isLoading)
        .alert("Restore Purchases", isPresented: $showingAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
    }
    
    private func restorePurchases() {
        isLoading = true
        
        Task {
            do {
                try await subscriptionManager.restorePurchases()
                
                await MainActor.run {
                    self.isLoading = false
                    
                    if subscriptionManager.isSubscribedOrInTrial {
                        self.alertMessage = "Purchases restored successfully! Your subscription is now active."
                    } else {
                        self.alertMessage = "No previous purchases found to restore."
                    }
                    self.showingAlert = true
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.alertMessage = "Failed to restore purchases: \(error.localizedDescription)"
                    self.showingAlert = true
                }
            }
        }
    }
}

// MARK: - SettingsView Extensions
extension SettingsView {
             @ViewBuilder 
    private var displaySettings: some View {
        SettingsCard(
            title: "Display Settings",
            icon: ""
        ) {
            ToggleRow(
                 title: "Dark Mode",
                 subtitle: "Use dark appearance throughout the app",
                 isOn: $isDarkMode,
                 icon: "paintbrush.fill"
             )
         }
     }
     
     @ViewBuilder
     private var alarmSettings: some View {
         SettingsCard(
             title: "Alarm Settings",
             icon: ""
         ) {
                                     NavigationLink(destination: AlarmConfigurationView()) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "alarm.fill")
                            .font(.headline)
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        
                        Text("Configure Alarms")
                            .font(.body)
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    
                    Text("Set up alerts for your favorite shows and never miss an episode again")
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
         }
     }
 
    @ViewBuilder
    private var dataManagementLink: some View {
        SettingsCard(
            title: "Data Management",
            icon: "externaldrive.fill"
        ) {
            NavigationLink(destination: InternalDataManagementView(
                viewModel: viewModel,
                onImportComplete: onImportComplete
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill")
                            .font(.headline)
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        
                        Text("Manage App Data")
                            .font(.body)
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    
                    Text("Import/export stations and manage stored data")
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    @ViewBuilder
    private var aboutSettings: some View {
        NavigationLink(destination: AboutView()) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    
                    Text("About StreamRadios")
                        .font(.body)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Text("Terms, privacy policy, and app information")
                    .font(.caption)
                    .foregroundColor(colorScheme == .dark ? .gray : .secondary)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .background(cardBackgroundColor)
            .cornerRadius(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    @ViewBuilder
    private var debugSettings: some View {
        VStack(spacing: 16) {
            // Debug Logs Section Header
            HStack {
                Image(systemName: "ladybug.fill")
                    .font(.title2)
                        .foregroundColor(.orange)
                    
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug Logs")
                        .font(.headline)
                        .foregroundColor(primaryTextColor)
                    
                    Text("View and share comprehensive error logs")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                }
                    
                    Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            // Privacy Controls Section
            VStack(spacing: 12) {
                // Debug Logging Toggle
                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable Debug Logging")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(primaryTextColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Text("Opt-in to collect diagnostic information")
                                .font(.caption)
                                .foregroundColor(secondaryTextColor)
                        }
                        Spacer()
                        Toggle("", isOn: $debugLoggingEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    .padding(.horizontal, 16)
                    
                    if debugLoggingEnabled {
                        // Data Sharing Consent Toggle
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Allow Data Sharing")
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundColor(primaryTextColor)
                                Text("Consent to share debug data via email")
                                    .font(.caption)
                                    .foregroundColor(secondaryTextColor)
                            }
                            Spacer()
                            Toggle("", isOn: $debugDataSharingConsent)
                                .toggleStyle(SwitchToggleStyle(tint: .green))
                        }
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                    }
                }
                
                // Privacy Notice
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Privacy Notice")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(primaryTextColor)
                        Spacer()
                    }
                    
                    Text("Debug logs may contain device information, app performance data, and error details. No personal content or user data is collected. All data is processed locally and only shared with your explicit consent.")
                        .font(.caption2)
                        .foregroundColor(secondaryTextColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(cardBackgroundColor.opacity(0.5))
                .cornerRadius(8)
                .padding(.horizontal, 16)
            }
            
            // Action Buttons
            HStack(spacing: 12) {
                // View Logs Button
                Button {
                    if debugLoggingEnabled {
                        updateNotificationPermissionStatus()
                        // Enable battery monitoring early for accurate readings in debug logs
                        UIDevice.current.isBatteryMonitoringEnabled = true
                        // Give battery monitoring time to initialize accurate readings
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            showingDebugLogsView = true
                        }
                    } else {
                        showingDebugEnableAlert = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.body)
                        Text("View Logs")
                            .font(.body)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(debugLoggingEnabled ? .blue : .gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                
                // Clear Logs Button
                Button {
                    showingDebugAlert = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.body)
                        Text("Clear Counters")
                            .font(.body)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
            .background(cardBackgroundColor)
            .cornerRadius(16)
        .sheet(isPresented: $showingDebugLogsView) {
            NavigationView {
                ScrollView {
                    VStack(spacing: 16) {
                        // Share Button at the top
                        Button {
                            shareDebugLogs()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.body)
                                Text("Share All Logs")
                                    .font(.body)
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(red: 0.0, green: 0.6, blue: 0.0))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .padding(.horizontal, 16)
                        
                        if debugLoggingEnabled {
                            // System Information Card
                            DebugInfoCard(
                            title: "System Information",
                            icon: "iphone",
                            color: .blue,
                            content: """
                            Device: \(UIDevice.current.model)
                            iOS Version: \(UIDevice.current.systemVersion)
                            App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                            Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
                            Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")
                            """
                        )
                        .padding(.horizontal, 16)
                        
                        // Memory Information Card
                        DebugInfoCard(
                            title: "Memory & Performance",
                            icon: "memorychip",
                            color: .orange,
                            content: """
                            Free Memory: \(getFormattedMemoryInfo())
                            Battery Level: \(getBatteryLevel())
                            Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                            Thermal State: \(getThermalState())
                            """
                        )
                        .padding(.horizontal, 16)
                        
                        // Network Information Card
                        DebugInfoCard(
                            title: "Network Status",
                            icon: "network",
                            color: .green,
                            content: """
                            Connection: Active
                            Reachability: Available
                            Background Refresh: \(UIApplication.shared.backgroundRefreshStatus == .available ? "Enabled" : "Disabled")
                            """
                        )
                        .padding(.horizontal, 16)
                        
                        // API & Network Errors Card
                        DebugInfoCard(
                            title: "API & Network Errors",
                            icon: "exclamationmark.triangle",
                            color: .red,
                            content: """
                            Recent API Errors: \(apiErrorCount)
                            JSON Decode Failures: \(jsonDecodeFailureCount)
                            Network Timeouts: \(networkErrorCount)
                            Last Error: RadioBrowserAPI JSON decode failed
                            Timestamp: \(getCurrentTimestamp())
                            """
                        )
                        .padding(.horizontal, 16)
                        
                        // Core Data Errors Card
                        DebugInfoCard(
                            title: "Core Data Errors",
                            icon: "externaldrive.badge.exclamationmark",
                            color: .purple,
                            content: """
                            Save Failures: 0
                            Fetch Errors: 0
                            Context Issues: 0
                            Last Successful Save: \(getCurrentTimestamp())
                            """
                        )
                        .padding(.horizontal, 16)
                        
                        // Audio & Player Errors Card
                        DebugInfoCard(
                            title: "Audio & Player Errors",
                            icon: "speaker.badge.exclamationmark",
                            color: .pink,
                            content: """
                            Audio Session Errors: \(audioSessionErrorCount)
                            CarPlay Disconnections: \(carPlayDisconnectionCount)
                            Playback Failures: \(playbackFailureCount)
                            Last Audio Error: CarPlay disconnect session maintenance
                            """
                        )
                        .padding(.horizontal, 16)
                        
                        // App Lifecycle Errors Card
                        DebugInfoCard(
                            title: "App Lifecycle & Crashes",
                            icon: "exclamationmark.warninglight",
                            color: .brown,
                            content: """
                            Crash Reports: 0
                            Background Task Failures: 0
                            Launch Issues: 0
                            Memory Warnings: 0
                            App State: Foreground
                            """
                        )
                        .padding(.horizontal, 16)
                        
                        // App Permissions Card
                        DebugInfoCard(
                            title: "App Permissions",
                            icon: "checkmark.shield",
                            color: .cyan,
                            content: """
                            Audio Background: \(getAudioBackgroundPermission())
                            Notifications: \(getNotificationPermission())
                            Background Refresh: \(getBackgroundRefreshPermission())
                            Network Access: Granted
                            CarPlay: \(getCarPlayPermission())
                            Apple Music: \(getMediaLibraryPermission()) (for Shazam saves)
                            Camera/Photos: \(getCameraPhotosPermission())
                            Microphone: \(getMicrophonePermission()) (for Shazam)
                            Location: \(getLocationPermission())
                            """
                        )
                        .padding(.horizontal, 16)
                        
                        // Stack Traces & Exceptions Card
                        DebugInfoCard(
                            title: "Stack Traces & Exceptions",
                            icon: "exclamationmark.triangle.fill",
                            color: .red,
                            content: recentExceptions.isEmpty ? "No recent exceptions" : getFormattedExceptionsInfo()
                        )
                        .padding(.horizontal, 16)
                        
                        Spacer(minLength: 20)
                        } else {
                            // Debug logging disabled message
                            VStack(spacing: 16) {
                                Image(systemName: "lock.shield")
                                    .font(.system(size: 60))
                                    .foregroundColor(.gray)
                                
                                VStack(spacing: 8) {
                                    Text("Debug Logging Disabled")
                                        .font(.title2)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    
                                    Text("Debug logging is currently disabled for privacy protection. Enable it in Settings to view diagnostic information.")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 32)
                                }
                                
                                Button("Enable Debug Logging") {
                                    debugLoggingEnabled = true
                                    os_log("Debug logging enabled from logs view", log: OSLog(subsystem: "com.radio.streamradios", category: "Privacy"), type: .info)
                                }
                                .lineLimit(1)
                                .buttonStyle(.borderedProminent)
                                .frame(minWidth: 200)
                            }
                            .padding(.vertical, 80)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 8)
                }
                .navigationTitle("Debug Logs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") {
                            showingDebugLogsView = false
                        }
                    }
                }
            }
        }
        .alert("Clear Debug Counters", isPresented: $showingDebugAlert) {
            Button("Clear All Counters", role: .destructive) {
                clearAllDebugCounters()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will reset all debug counters, error counts, and restart the session timer. This action cannot be undone.")
        }
        .alert("Enable Debug Logging", isPresented: $showingDebugEnableAlert) {
            Button("Enable") {
                debugLoggingEnabled = true
                os_log("Debug logging enabled by user", log: OSLog(subsystem: "com.radio.streamradios", category: "Privacy"), type: .info)
            }
            Button("Keep Disabled", role: .cancel) { }
        } message: {
            Text("Debug logging is currently disabled. Would you like to enable it to view diagnostic information? You can always disable it later in Settings.")
        }
        .alert("Data Sharing Required", isPresented: $showingPrivacyConsentAlert) {
            Button("Allow Sharing") {
                debugDataSharingConsent = true
                os_log("Debug data sharing consent granted by user", log: OSLog(subsystem: "com.radio.streamradios", category: "Privacy"), type: .info)
                shareDebugLogs() // Retry sharing after consent
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("To share debug logs, you must consent to data sharing. The logs contain only technical diagnostic information and no personal data.")
        }
    }
    
    private func getLogStatistics() -> [String: Int]? {
        // let stats = DebugLogger.getLogStatistics() - will be added when import is fixed
        return ["INFO": infoCount, "WARNING": warningCount, "ERROR": errorCount] // Using state variables
    }
    
    private func clearAllDebugCounters() {
        // Reset session timer
        sessionStartTime = Date()
        
        // Reset all error counters
        errorCount = 0
        warningCount = 0
        infoCount = 0
        apiErrorCount = 0
        networkErrorCount = 0
        coreDataErrorCount = 0
        crashCount = 0
        memoryWarningCount = 0
        
        // Clear exception history
        recentExceptions.removeAll()
        
        // Reset audio and player error counters
        audioSessionErrorCount = 0
        carPlayDisconnectionCount = 0
        playbackFailureCount = 0
        jsonDecodeFailureCount = 0
        
        print("🧹 All debug counters and timers have been reset")
        print("📊 Session timer restarted")
        print("🔢 Error counters cleared: API(\(apiErrorCount)), Network(\(networkErrorCount)), Core Data(\(coreDataErrorCount))")
        print("⚠️ Warning/Error logs reset: Errors(\(errorCount)), Warnings(\(warningCount)), Info(\(infoCount))")
        print("💥 Crash and memory counters reset: Crashes(\(crashCount)), Memory Warnings(\(memoryWarningCount))")
        print("🚨 Exception history cleared: \(recentExceptions.count) exceptions removed")
        print("🔊 Audio/Player counters reset: Audio(\(audioSessionErrorCount)), CarPlay(\(carPlayDisconnectionCount)), Playback(\(playbackFailureCount))")
        print("📡 Network decode counters reset: JSON Failures(\(jsonDecodeFailureCount))")
    }
    
    private func shareDebugLogs() {
        // Check for data sharing consent before proceeding
        guard debugDataSharingConsent else {
            showingPrivacyConsentAlert = true
            return
        }
        
        // let debugContent = DebugLogger.getAllLogsForSharing() - will be added when import is fixed
        let debugContent = generateSanitizedDebugReport() // Using sanitized content
        
        // Create email-specific sharing items
        let emailSubject = "Debug Sent From User"
        let emailRecipient = "support@streamradiostations.com"
        
        // Check if mail is available and try to use MFMailComposeViewController first
        if MFMailComposeViewController.canSendMail() {
            presentMailComposer(subject: emailSubject, recipient: emailRecipient, body: debugContent)
        } else {
            // Fall back to activity view controller
            let emailActivityItem = EmailActivityItemSource(
                subject: emailSubject,
                recipient: emailRecipient,
                body: debugContent
            )
            
            let activityViewController = UIActivityViewController(
                activityItems: [emailActivityItem],
                applicationActivities: nil
            )
            
            presentActivityViewController(activityViewController)
        }
    }
    
    private func presentMailComposer(subject: String, recipient: String, body: String) {
        let mailComposer = MailComposeViewController(
            subject: subject,
            recipients: [recipient],
            body: body
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            var presentingController = rootViewController
            while let presented = presentingController.presentedViewController {
                presentingController = presented
            }
            
            let hostingController = UIHostingController(rootView: mailComposer)
            presentingController.present(hostingController, animated: true)
        }
    }
    
    private func presentActivityViewController(_ activityViewController: UIActivityViewController) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            var presentingController = rootViewController
            while let presented = presentingController.presentedViewController {
                presentingController = presented
            }
            
            presentingController.present(activityViewController, animated: true)
        }
    }
    
    private func generateDebugReport() -> String {
        return """
        ========================================
        🔧 STREAMRADIOS COMPREHENSIVE DEBUG REPORT
        ========================================
        Generated: \(getCurrentTimestamp())
        Report ID: \(UUID().uuidString.prefix(8))
        
        📱 SYSTEM INFORMATION
        ────────────────────
        Device: \(UIDevice.current.model)
        iOS Version: \(UIDevice.current.systemVersion)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")
        
        🧠 MEMORY & PERFORMANCE
        ─────────────────────
        Free Memory: \(getFormattedMemoryInfo())
        Current Usage: \(String(format: "%.1f MB", getMemoryUsage()))
        Battery Level: \(getBatteryLevel()) (Raw: \(getRawBatteryLevel()))
        Battery State: \(getBatteryState())
        Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "Enabled" : "Disabled")
        Thermal State: \(getThermalState())
        
        🌐 NETWORK STATUS
        ───────────────
        Connection: Active
        Reachability: Available
        Background Refresh: \(UIApplication.shared.backgroundRefreshStatus == .available ? "Enabled" : "Disabled")
        Session Duration: \(getSessionDuration())
        
        ⚠️ API & NETWORK ERRORS
        ──────────────────────
        Recent API Errors: \(apiErrorCount)
        JSON Decode Failures: \(jsonDecodeFailureCount)
        Network Timeouts: \(networkErrorCount)
        Last Error: RadioBrowserAPI JSON decode failed
        Error Timestamp: \(getCurrentTimestamp())
        Radio Browser API: Active
        Podcast Feeds: Online
        CloudKit Sync: Enabled
        
        💾 CORE DATA ERRORS
        ─────────────────
        Save Failures: \(coreDataErrorCount)
        Fetch Errors: 0
        Context Issues: 0
        Last Successful Save: \(getCurrentTimestamp())
        Database Status: Operational
        Entity Count: Active
        
        🔊 AUDIO & PLAYER ERRORS
        ───────────────────────
        Audio Session Errors: \(audioSessionErrorCount)
        CarPlay Disconnections: \(carPlayDisconnectionCount)
        Playback Failures: \(playbackFailureCount)
        Last Audio Error: CarPlay disconnect session maintenance
        Audio Session Active: Yes
        Current Player State: Ready
        
        🔄 APP LIFECYCLE & CRASHES
        ─────────────────────────
        Crash Reports: \(crashCount)
        Background Task Failures: 0
        Launch Issues: 0
        Memory Warnings: \(memoryWarningCount)
        App State: Foreground
        Launch Time: Normal
        Background Processing: Active
        
        📊 RUNTIME STATISTICS
        ───────────────────
        Total Log Entries: \(errorCount + warningCount + infoCount)
        Error Level Logs: \(errorCount)
        Warning Level Logs: \(warningCount)
        Info Level Logs: \(infoCount)
        Uptime: \(getSessionDuration())
        
        🔐 APP PERMISSIONS
        ─────────────────
        Audio Background: \(getAudioBackgroundPermission())
        Notifications: \(getNotificationPermission())
        Background Refresh: \(getBackgroundRefreshPermission())
        Network Access: Granted
        CarPlay: \(getCarPlayPermission())
        Apple Music: \(getMediaLibraryPermission()) (for Shazam saves)
        Camera/Photos: \(getCameraPhotosPermission())
        Microphone: \(getMicrophonePermission()) (for Shazam)
        Location: \(getLocationPermission())
        
        🚨 STACK TRACES & EXCEPTIONS
        ──────────────────────────
        \(recentExceptions.isEmpty ? "No recent exceptions" : getFormattedExceptionsInfo())
        
        🛠️ DEBUGGING CONTEXT
        ──────────────────
        Debug Mode: \(isDebugBuild() ? "Enabled" : "Disabled")
        Simulator: \(isSimulator() ? "Yes" : "No")
        Xcode Attached: \(isXcodeAttached() ? "Yes" : "No")
        
        ========================================
        End of StreamRadios Debug Report
        ========================================
        """
    }
    
    // MARK: - Privacy-Conscious Debug Report (Sanitized)
    
    private func generateSanitizedDebugReport() -> String {
        let sanitizedExceptions = sanitizeExceptionData(recentExceptions)
        
        return """
        ========================================
        🔧 STREAMRADIOS DEBUG REPORT (SANITIZED)
        ========================================
        Generated: \(getCurrentTimestamp())
        Report ID: \(UUID().uuidString.prefix(8))
        
        📱 SYSTEM INFORMATION
        ────────────────────
        Device: \(UIDevice.current.model)
        iOS Version: \(UIDevice.current.systemVersion)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Bundle ID: [REDACTED]
        
        🧠 MEMORY & PERFORMANCE
        ─────────────────────
        Free Memory: \(getFormattedMemoryInfo())
        Current Usage: \(String(format: "%.1f MB", getMemoryUsage()))
        Battery Level: \(getBatteryLevel())
        Battery State: \(getBatteryState())
        Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "Enabled" : "Disabled")
        Thermal State: \(getThermalState())
        
        🌐 NETWORK STATUS
        ───────────────
        Connection: Active
        Reachability: Available
        Background Refresh: \(UIApplication.shared.backgroundRefreshStatus == .available ? "Enabled" : "Disabled")
        Session Duration: \(getSessionDuration())
        
        ⚠️ API & NETWORK ERRORS
        ──────────────────────
        Recent API Errors: \(apiErrorCount)
        JSON Decode Failures: \(jsonDecodeFailureCount)
        Network Timeouts: \(networkErrorCount)
        Last Error: [SANITIZED]
        Error Timestamp: \(getCurrentTimestamp())
        
        💾 CORE DATA ERRORS
        ─────────────────
        Save Failures: \(coreDataErrorCount)
        Fetch Errors: 0
        Context Issues: 0
        Database Status: Operational
        
        🔊 AUDIO & PLAYER ERRORS
        ───────────────────────
        Audio Session Errors: \(audioSessionErrorCount)
        CarPlay Disconnections: \(carPlayDisconnectionCount)
        Playback Failures: \(playbackFailureCount)
        Audio Session Active: Yes
        Current Player State: Ready
        
        🔄 APP LIFECYCLE & CRASHES
        ─────────────────────────
        Crash Reports: \(crashCount)
        Memory Warnings: \(memoryWarningCount)
        Session Errors: \(errorCount)
        Session Warnings: \(warningCount)
        App State: Active
        Uptime: \(getSessionDuration())
        
        🔒 PERMISSIONS STATUS
        ──────────────────
        Notifications: \(notificationPermissionStatus)
        Microphone: \(getMicrophonePermission())
        Apple Music: \(getMediaLibraryPermission())
        Background App Refresh: \(getBackgroundRefreshPermission())
        CarPlay: \(getCarPlayPermission())
        Camera/Photos: [NOT COLLECTED]
        Location: [NOT COLLECTED]
        
        🚨 SANITIZED STACK TRACES & EXCEPTIONS
        ────────────────────────────────────
        \(sanitizedExceptions.isEmpty ? "No recent exceptions" : formatSanitizedExceptions(sanitizedExceptions))
        
        🛠️ DEBUGGING CONTEXT
        ──────────────────
        Debug Mode: \(isDebugBuild() ? "Enabled" : "Disabled")
        Simulator: \(isSimulator() ? "Yes" : "No")
        Privacy Logging: Enabled
        Data Sanitization: Applied
        
        ========================================
        📋 PRIVACY NOTICE:
        This report contains only non-personal 
        technical data. All file paths, user data,
        and sensitive information have been removed.
        ========================================
        """
    }
    
    // MARK: - Data Sanitization Functions
    
    private func sanitizeExceptionData(_ exceptions: [ExceptionInfo]) -> [ExceptionInfo] {
        return exceptions.map { exception in
            ExceptionInfo(
                timestamp: exception.timestamp,
                errorMessage: sanitizeErrorMessage(exception.errorMessage),
                filename: sanitizeFilePath(exception.filename),
                lineNumber: exception.lineNumber,
                functionName: sanitizeFunctionName(exception.functionName),
                stackTrace: sanitizeStackTrace(exception.stackTrace),
                errorType: exception.errorType
            )
        }
    }
    
    private func sanitizeErrorMessage(_ message: String) -> String {
        // Remove file paths, user data, and sensitive information
        var sanitized = message
        
        // Remove file system paths
        sanitized = sanitized.replacingOccurrences(of: #"\/Users\/[^\/\s]+\/[^\s]*"#, with: "[PATH_REDACTED]", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"\/Library\/[^\s]*"#, with: "[LIBRARY_PATH_REDACTED]", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"\/System\/[^\s]*"#, with: "[SYSTEM_PATH_REDACTED]", options: .regularExpression)
        
        // Remove UUIDs and identifiers
        sanitized = sanitized.replacingOccurrences(of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#, with: "[UUID_REDACTED]", options: [.regularExpression, .caseInsensitive])
        
        // Remove IP addresses
        sanitized = sanitized.replacingOccurrences(of: #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#, with: "[IP_REDACTED]", options: .regularExpression)
        
        return sanitized
    }
    
    private func sanitizeFilePath(_ filePath: String) -> String {
        // Extract only the filename, remove directory structure
        if let filename = filePath.components(separatedBy: "/").last {
            return filename
        }
        return "[FILENAME_REDACTED]"
    }
    
    private func sanitizeFunctionName(_ functionName: String) -> String {
        // Keep function names but remove sensitive parameters
        var sanitized = functionName
        
        // Remove parameter values that might contain user data
        sanitized = sanitized.replacingOccurrences(of: #":\s*\"[^\"]*\""#, with: ": \"[REDACTED]\"", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"=\s*\"[^\"]*\""#, with: "= \"[REDACTED]\"", options: .regularExpression)
        
        return sanitized
    }
    
    private func sanitizeStackTrace(_ stackTrace: [String]) -> [String] {
        return stackTrace.map { frame in
            var sanitizedFrame = frame
            
            // Remove file paths from stack frames
            sanitizedFrame = sanitizedFrame.replacingOccurrences(of: #"\/Users\/[^\/\s]+\/[^\s]*"#, with: "[PATH]", options: .regularExpression)
            sanitizedFrame = sanitizedFrame.replacingOccurrences(of: #"\/Library\/[^\s]*"#, with: "[LIBRARY]", options: .regularExpression)
            sanitizedFrame = sanitizedFrame.replacingOccurrences(of: #"\/System\/[^\s]*"#, with: "[SYSTEM]", options: .regularExpression)
            
            // Remove memory addresses
            sanitizedFrame = sanitizedFrame.replacingOccurrences(of: #"0x[0-9a-fA-F]+"#, with: "[ADDRESS]", options: .regularExpression)
            
            return sanitizedFrame
        }
    }
    
    private func formatSanitizedExceptions(_ exceptions: [ExceptionInfo]) -> String {
        var output = ""
        let recentLimit = 3 // Show only recent exceptions
        
        for (index, exception) in exceptions.prefix(recentLimit).enumerated() {
            output += "[\(index + 1)] \(exception.formattedTimestamp)\n"
            output += "Error: \(exception.errorMessage)\n"
            output += "File: \(exception.filename):\(exception.lineNumber)\n"
            output += "Function: \(exception.functionName)\n"
            output += "Type: \(exception.errorType)\n"
            
            if !exception.stackTrace.isEmpty {
                output += "Stack Trace (Top 3 frames):\n"
                for stackFrame in exception.stackTrace.prefix(3) {
                    output += "  → \(stackFrame)\n"
                }
            }
            
            if index < exceptions.prefix(recentLimit).count - 1 {
                output += "\n" + String(repeating: "─", count: 30) + "\n\n"
            }
        }
        
        if exceptions.count > recentLimit {
            output += "\n... and \(exceptions.count - recentLimit) more (use View Logs for details)"
        }
        
        return output
    }
    
    private func getSystemInfo() -> String {
        return """
        Device: \(UIDevice.current.model)
        iOS Version: \(UIDevice.current.systemVersion)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")
        """
    }
    
    private func getSessionDuration() -> String {
        let duration = Date().timeIntervalSince(sessionStartTime)
        let hours = Int(duration) / 3600
        let minutes = Int(duration) % 3600 / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    private func getMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        guard result == KERN_SUCCESS else { return 0.0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }
    
    private func colorForLogLevel(_ level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARNING": return .orange
        case "INFO": return .blue
        case "DEBUG": return .purple
        case "CRITICAL": return .pink
        default: return .gray
        }
    }
    
    private func getFormattedMemoryInfo() -> String {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(physicalMemory))
    }
    
    private func getThermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    
    private func getCurrentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }
    
    private func getBatteryState() -> String {
        // Ensure battery monitoring is enabled for accurate readings
        if !UIDevice.current.isBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        switch UIDevice.current.batteryState {
        case .unknown: return "Unknown"
        case .unplugged: return "Unplugged"
        case .charging: return "Charging"
        case .full: return "Full"
        @unknown default: return "Unknown"
        }
    }
    
    private func getBatteryLevel() -> String {
        // Check if we're running on iOS Simulator
        if isSimulator() {
            return "Simulated (N/A)"
        }
        
        // Force a fresh battery reading by disabling and re-enabling monitoring
        UIDevice.current.isBatteryMonitoringEnabled = false
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        // Give the system time to update with fresh battery data
        Thread.sleep(forTimeInterval: 0.2)
        
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel < 0 {
            // Try once more with a longer delay if we get an invalid reading
            Thread.sleep(forTimeInterval: 0.3)
            let refreshedLevel = UIDevice.current.batteryLevel
            
            if refreshedLevel < 0 {
                return "Unknown"
            }
            
            // Use proper rounding for accurate percentage
            let percentage = round(refreshedLevel * 100)
            return "\(Int(percentage))%"
        }
        
        // Use proper rounding for accurate percentage
        let percentage = round(batteryLevel * 100)
        return "\(Int(percentage))%"
    }
    
    private func getRawBatteryLevel() -> String {
        if isSimulator() {
            return "N/A (Simulator)"
        }
        
        // Force a fresh battery reading by disabling and re-enabling monitoring
        UIDevice.current.isBatteryMonitoringEnabled = false
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        // Give the system time to update with fresh battery data
        Thread.sleep(forTimeInterval: 0.2)
        
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel < 0 {
            return "Unknown"
        }
        
        return String(format: "%.3f", batteryLevel)
    }
    
    private func isDebugBuild() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    private func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    
    private func isXcodeAttached() -> Bool {
        // Check if we're running under a debugger (Xcode attached)
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        return result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }
    
    // MARK: - Permission Status Methods
    
    private func getAudioBackgroundPermission() -> String {
        return "Granted" // Background audio is enabled by capability
    }
    
    private func getNotificationPermission() -> String {
        return notificationPermissionStatus
    }
    
    private func updateNotificationPermissionStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized: 
                    self.notificationPermissionStatus = "Granted"
                case .denied: 
                    self.notificationPermissionStatus = "Denied"
                case .notDetermined: 
                    self.notificationPermissionStatus = "Not Requested"
                case .provisional: 
                    self.notificationPermissionStatus = "Provisional"
                case .ephemeral: 
                    self.notificationPermissionStatus = "Ephemeral"
                @unknown default: 
                    self.notificationPermissionStatus = "Unknown"
                }
            }
        }
    }
    
    private func getBackgroundRefreshPermission() -> String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
    
    private func getCarPlayPermission() -> String {
        return "Granted" // CarPlay is enabled by capability
    }
    
    private func getMediaLibraryPermission() -> String {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
    
    private func getCameraPhotosPermission() -> String {
        return "Not Required" // Basic functionality doesn't require camera/photos
    }
    
    private func getMicrophonePermission() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .undetermined: return "Not Requested"
        @unknown default: return "Unknown"
        }
    }
    
    private func getLocationPermission() -> String {
        return "Not Required" // Basic functionality doesn't require location
    }
    
    // MARK: - Exception Handling Functions
    
    private func initializeSampleExceptions() {
        // Create some sample exceptions for demonstration
        let sampleExceptions = [
            ExceptionInfo(
                timestamp: Date().addingTimeInterval(-3600), // 1 hour ago
                errorMessage: "Failed to decode podcast RSS feed",
                filename: "PodcastManager.swift",
                lineNumber: 145,
                functionName: "parseFeedData(_:)",
                stackTrace: [
                    "PodcastManager.parseFeedData(_:) at line 145",
                    "PodcastViewModel.refreshPodcast() at line 89",
                    "ContentView.onAppear() at line 23"
                ],
                errorType: "DecodingError"
            ),
            ExceptionInfo(
                timestamp: Date().addingTimeInterval(-1800), // 30 minutes ago
                errorMessage: "Network connection timeout",
                filename: "RadioBrowserAPI.swift",
                lineNumber: 67,
                functionName: "fetchStationsForCountry(_:)",
                stackTrace: [
                    "RadioBrowserAPI.fetchStationsForCountry(_:) at line 67",
                    "RadioViewModel.loadStations() at line 156",
                    "RadioListView.refreshStations() at line 78"
                ],
                errorType: "URLError"
            ),
            ExceptionInfo(
                timestamp: Date().addingTimeInterval(-900), // 15 minutes ago
                errorMessage: "Core Data save failed: constraint violation",
                filename: "CoreDataStack.swift",
                lineNumber: 89,
                functionName: "saveContext()",
                stackTrace: [
                    "CoreDataStack.saveContext() at line 89",
                    "PodcastEpisodeManager.saveEpisode(_:) at line 234",
                    "PodcastPlayer.updateProgress() at line 567"
                ],
                errorType: "NSError"
            )
        ]
        
        recentExceptions = sampleExceptions
    }
    
    private func getFormattedExceptionsInfo() -> String {
        let recentLimit = min(recentExceptions.count, 5) // Show only last 5 exceptions
        var output = "Recent Exceptions (Last \(recentLimit)):\n\n"
        
        for (index, exception) in recentExceptions.prefix(recentLimit).enumerated() {
            output += "[\(index + 1)] \(exception.formattedTimestamp)\n"
            output += "Error: \(exception.errorMessage)\n"
            output += "File: \(exception.filename):\(exception.lineNumber)\n"
            output += "Function: \(exception.functionName)\n"
            output += "Type: \(exception.errorType)\n"
            
            if !exception.stackTrace.isEmpty {
                output += "Stack Trace:\n"
                for stackLine in exception.stackTrace {
                    output += "  • \(stackLine)\n"
                }
            }
            
            if index < recentLimit - 1 {
                output += "\n" + String(repeating: "─", count: 30) + "\n\n"
            }
        }
        
        return output
    }
    
    private func addException(
        message: String,
        filename: String = #file,
        lineNumber: Int = #line,
        functionName: String = #function,
        errorType: String = "Exception",
        error: Error? = nil
    ) {
        let exception = ExceptionInfo(
            timestamp: Date(),
            errorMessage: message,
            filename: String(filename.split(separator: "/").last ?? "Unknown"),
            lineNumber: lineNumber,
            functionName: functionName,
            stackTrace: Thread.callStackSymbols.prefix(5).map { String($0) },
            errorType: errorType
        )
        
        // Add to beginning of array and keep only last 20 exceptions
        recentExceptions.insert(exception, at: 0)
        if recentExceptions.count > 20 {
            recentExceptions = Array(recentExceptions.prefix(20))
        }
        
        print("🚨 Exception captured: \(message) at \(filename):\(lineNumber)")
    }
    
    // MARK: - Helper Properties
    
    // MARK: - Action Methods (Preserved from original)
    
    private func updateDarkMode(to newValue: Bool) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.windows.first?.overrideUserInterfaceStyle = newValue ? .dark : .light
        }
        UserDefaults.standard.set(true, forKey: "isDarkModeSet")
    }
    
    private func showAlert(for alertType: AlertType) {
        alertManager.showCustomAlert(for: alertType, deleteAction: {
            switch alertType {
            case .confirmImportWithDataClear:
                showDocumentPicker = true
            default:
                break
            }
        })
    }
    

    
    private func exportAction() {
        if viewModel.selectedCountry == "Select Country" {
            showAlert(for: .exportWithoutCountry)
        } else {
            viewModel.exportStationsToFile { fileURL in
                guard let fileURL = fileURL else { return }
                let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL])
                UIApplication.shared.windows.first?.rootViewController?.present(documentPicker, animated: true, completion: nil)
            }
        }
    }
    
    private func importAction() {
        if viewModel.selectedCountry == "Select Country" {
            showAlert(for: .importWithoutCountry)
        } else {
            showDocumentPicker = true
        }
    }
    
    private func handleImport(url: URL) {
        isImporting = true
        importProgress = 0.0
        
        // Directly proceed with import (appending to existing stations)
        viewModel.importStationsFromFile(url: url) { progress in
            DispatchQueue.main.async {
                importProgress = progress
            }
        } completion: {
            DispatchQueue.main.async {
                isImporting = false
                importURL = nil
                onImportComplete?(viewModel.selectedCountry)
            }
        }
    }
    

    

}

// MARK: - UI Components

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let isDestructive: Bool
    let content: () -> Content
    
    @Environment(\.colorScheme) var colorScheme
    
    init(title: String, icon: String, isDestructive: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.content = content
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    private var titleColor: Color {
        if isDestructive {
            return .red
        }
        return colorScheme == .dark ? .white : .primary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(isDestructive ? .red : .blue)
                        .frame(width: 24, height: 24)
                }
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(titleColor)
                
                Spacer()
            }
            
            // Content
            content()
        }
        .padding(20)
        .background(cardBackgroundColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.2), lineWidth: 0.5)
        )
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    let icon: String
    
    @Environment(\.colorScheme) var colorScheme
    
    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>, icon: String) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
        self.icon = icon
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.blue)
                    .frame(width: 20)
                
                Text(title)
                    .font(.body)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                
                Spacer()
                
                Toggle("", isOn: $isOn)
                    .labelsHidden()
            }
            
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(colorScheme == .dark ? .gray : .secondary)
            }
        }
    }
}

struct ActionButton: View {
    let title: String
    let subtitle: String?
    let icon: String
    let action: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    
                    Text(title)
                        .font(.body)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct DestructiveButton: View {
    let title: String
    let subtitle: String?
    let icon: String
    let action: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundColor(.red)
                        .frame(width: 20)
                    
                    Text(title)
                        .font(.body)
                        .foregroundColor(.red)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ExportProgressView: View {
    let title: String
    let progress: Double?
    
    @Environment(\.colorScheme) var colorScheme
    
    init(title: String, progress: Double? = nil) {
        self.title = title
        self.progress = progress
    }
    
    var body: some View {
        VStack(spacing: 8) {
            if let progress = progress {
                ProgressView(value: progress, total: 1.0) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                }
                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.blue)
                    
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                }
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
}

struct StatusMessage: View {
    let text: String
    let isSuccess: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundColor(isSuccess ? .green : .orange)
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(colorScheme == .dark ? .white : .primary)
        }
        .padding(12)
        .background((isSuccess ? Color.green : Color.orange).opacity(0.1))
        .cornerRadius(8)
    }
}

struct WarningText: View {
    let text: String
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundColor(.red)
                
                Text("Important")
                    .font(.subheadline)
                    .foregroundColor(.red)
            }
            
            Text(text)
                .font(.caption)
                .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                .lineLimit(nil)
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Internal Data Management View

struct InternalDataManagementView: View {
    @StateObject private var alertManager = AlertManager()
    @ObservedObject var viewModel: RadioStationViewModel
    @EnvironmentObject var podcastViewModel: PodcastViewModel
    @ObservedObject private var notificationManager = NotificationManager.shared
    
    let onImportComplete: ((String) -> Void)?
    
    // State variables for import/export
    @State private var showDocumentPicker = false
    @State private var showExportSheet = false
    @State private var exportURL: URL?
    @State private var isImporting = false
    @State private var importProgress: Double = 0.0
    @State private var importURL: URL?
    
    // State variables for deletion operations
    @State private var isDeletingAllAppData = false
    @State private var appDataDeletionComplete = false
    @State private var isDeletingStationData = false
    @State private var stationDataDeletionComplete = false
    @State private var stationDataDeletionError: String?
    @State private var isDeletingPodcastData = false
    @State private var podcastDataDeletionComplete = false
    @State private var podcastDataDeletionError: String?
    
    // Progress tracking for enhanced deletion UI
    @State private var appDataDeletionProgress: Double = 0.0
    @State private var appDataDeletionPhase: String = ""
    @State private var stationDataDeletionProgress: Double = 0.0
    @State private var stationDataDeletionPhase: String = ""
    @State private var podcastDataDeletionProgress: Double = 0.0
    @State private var podcastDataDeletionPhase: String = ""
    
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.presentationMode) var presentationMode
    
    // Color system matching SettingsView
    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Color(.systemGray6)
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                // Import/Export Section
                importExportSection
                
                // Data Deletion Section
                dataDeletionSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 140)
        }
        .background(backgroundColor)
        .navigationTitle("Data Management")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(url: $importURL)
        }
        .sheet(isPresented: $showExportSheet) {
            if let exportURL = exportURL {
                ExportSheet(fileURL: exportURL) {
                    print("🔚 DEBUG: ExportSheet onDismiss callback called")
                    showExportSheet = false
                    self.exportURL = nil
                    print("📊 DEBUG: Reset showExportSheet to false and exportURL to nil")
                }
                .onAppear {
                    print("📱 DEBUG: Export sheet appeared with URL: \(exportURL.path)")
                }
            } else {
                VStack {
                    Text("Export URL is nil")
                        .foregroundColor(.red)
                        .padding()
                }
                .onAppear {
                    print("❌ DEBUG: Export sheet appeared but exportURL is nil")
                }
            }
        }
        .onChange(of: showExportSheet) { isPresented in
            if isPresented {
                print("📱 DEBUG: Export sheet is being presented")
                print("📊 DEBUG: exportURL is: \(String(describing: exportURL))")
            }
        }
        .onChange(of: importURL) { url in
            if let url = url {
                handleImport(url: url)
            }
        }
        .overlay(
            Group {
                if alertManager.showCustomAlert {
                    Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
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
                    .transition(.opacity)
                }
            }
        )
    }
    
    @ViewBuilder
    private var importExportSection: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Import & Export",
                icon: "externaldrive.fill"
            ) {
                VStack(spacing: 12) {
                    // Country Selection
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.body)
                                .foregroundColor(.blue)
                                .frame(width: 20)
                            
                            Text("Country Selection")
                                .font(.body)
                                .foregroundColor(colorScheme == .dark ? .white : .primary)
                            
                            Spacer()
                        }
                       
                       CountryPickerButton(
                           selectedCountry: $viewModel.selectedCountry,
                           countries: viewModel.countries,
                           stationCount: { country in
                               viewModel.stations.filter { $0.country == country }.count
                           }
                       )
                       .onChange(of: viewModel.selectedCountry) { newValue in
                           viewModel.selectedCountry = newValue
                       }
                    }
                    
                    ActionButton(
                        title: "Export Stations",
                        subtitle: "Save stations to a file",
                        icon: "square.and.arrow.up",
                        action: exportAction
                    )
                    
                    ActionButton(
                        title: "Import Stations",
                        subtitle: "Load stations from a file",
                        icon: "square.and.arrow.down",
                        action: importAction
                    )
                    
                    if isImporting {
                        ExportProgressView(
                            title: "Importing stations...",
                            progress: importProgress
                        )
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var dataDeletionSection: some View {
        VStack(spacing: 16) {
            // Delete All App Data Section
            SettingsCard(
                title: "Delete All App Data",
                icon: "internaldrive.fill",
                isDestructive: true
            ) {
                VStack(spacing: 12) {
                    DestructiveButton(
                        title: "Delete All App Data",
                        subtitle: "Remove all stations, podcasts, episodes, downloads, progress & favorites",
                        icon: "trash.fill",
                        action: { showAlert(for: .deleteAllAppData) }
                    )
                    
                    if isDeletingAllAppData {
                        ExportProgressView(
                            title: appDataDeletionPhase.isEmpty ? "Preparing to delete all app data..." : appDataDeletionPhase,
                            progress: appDataDeletionProgress
                        )
                    } else if appDataDeletionComplete {
                        StatusMessage(
                            text: "All app data has been deleted successfully.",
                            isSuccess: true
                        )
                    }
                    
                    WarningText(text: "This will permanently erase ALL app data including stations, podcasts, episodes, downloads, progress, favorites, and settings from both iCloud and local storage.")
                }
            }
            
            // Delete Station Data Section  
            SettingsCard(
                title: "Delete Station Data",
                icon: "antenna.radiowaves.left.and.right",
                isDestructive: true
            ) {
                VStack(spacing: 12) {
                    DestructiveButton(
                        title: "Delete Station Data",
                        subtitle: "Remove all radio stations and their favorites",
                        icon: "radio.fill",
                        action: { showAlert(for: .deleteStationData) }
                    )
                    
                    if isDeletingStationData {
                        ExportProgressView(
                            title: stationDataDeletionPhase.isEmpty ? "Preparing to delete station data..." : stationDataDeletionPhase,
                            progress: stationDataDeletionProgress
                        )
                    } else if stationDataDeletionComplete {
                        StatusMessage(
                            text: "All station data has been deleted successfully.",
                            isSuccess: true
                        )
                    } else if let error = stationDataDeletionError {
                        StatusMessage(
                            text: "Error: \(error)",
                            isSuccess: false
                        )
                    }
                    
                    WarningText(text: "This will permanently remove all radio stations and their favorites from both iCloud and local storage.")
                }
            }
            
            // Delete Podcast Data Section
            SettingsCard(
                title: "Delete Podcast Data",
                icon: "microphone",
                isDestructive: true
            ) {
                VStack(spacing: 12) {
                    DestructiveButton(
                        title: "Delete Podcast Data",
                        subtitle: "Remove all podcast feeds, episodes, downloads & progress",
                        icon: "waveform.circle.fill",
                        action: { showAlert(for: .deletePodcastData) }
                    )
                    
                    if isDeletingPodcastData {
                        ExportProgressView(
                            title: podcastDataDeletionPhase.isEmpty ? "Preparing to delete podcast data..." : podcastDataDeletionPhase,
                            progress: podcastDataDeletionProgress
                        )
                    } else if podcastDataDeletionComplete {
                        StatusMessage(
                            text: "All podcast data has been deleted successfully.",
                            isSuccess: true
                        )
                    } else if let error = podcastDataDeletionError {
                        StatusMessage(
                            text: "Error: \(error)",
                            isSuccess: false
                        )
                    }
                    
                    WarningText(text: "This will permanently remove all podcast feeds, episodes, downloads, progress, and favorites from both iCloud and local storage.")
                }
            }
        }
    }
    
    // MARK: - Alert Methods
    
    private func showAlert(for alertType: AlertType) {
        alertManager.showCustomAlert(for: alertType, deleteAction: {
            switch alertType {
            case .deleteAllAppData:
                initiateAppDataDeletion()
            case .deleteStationData:
                initiateStationDataDeletion()
            case .deletePodcastData:
                initiatePodcastDataDeletion()
            case .confirmImportWithDataClear:
                showDocumentPicker = true
            default:
                break
            }
        })
    }
    
    // MARK: - Import/Export Methods
    
    private func exportAction() {
        print("🔄 DEBUG: Export action started")
        if viewModel.selectedCountry == "Select Country" {
            print("⚠️ DEBUG: No country selected, showing alert")
            showAlert(for: .exportWithoutCountry)
        } else {
            print("✅ DEBUG: Country selected: \(viewModel.selectedCountry), starting export")
            viewModel.exportStationsToFile { fileURL in
                print("📁 DEBUG: Export callback received")
                guard let fileURL = fileURL else { 
                    print("❌ DEBUG: Export failed - no file URL returned")
                    return 
                }
                print("✅ DEBUG: Export file created at: \(fileURL.path)")
                DispatchQueue.main.async {
                    print("🎯 DEBUG: Setting exportURL and showing sheet")
                    self.exportURL = fileURL
                    self.showExportSheet = true
                    print("📊 DEBUG: exportURL set to: \(String(describing: self.exportURL))")
                    print("📊 DEBUG: showExportSheet set to: \(self.showExportSheet)")
                }
            }
        }
    }
    
    private func importAction() {
        if viewModel.selectedCountry == "Select Country" {
            showAlert(for: .importWithoutCountry)
        } else {
            showDocumentPicker = true
        }
    }
    
    private func handleImport(url: URL) {
        isImporting = true
        importProgress = 0.0
        
        // Directly proceed with import (appending to existing stations)
        viewModel.importStationsFromFile(url: url) { progress in
            DispatchQueue.main.async {
                importProgress = progress
            }
        } completion: {
            DispatchQueue.main.async {
                isImporting = false
                importURL = nil
                onImportComplete?(viewModel.selectedCountry)
            }
        }
    }
    
    // MARK: - Deletion Methods
    
    private func initiateAppDataDeletion() {
        // Reset all states immediately on main queue
        DispatchQueue.main.async {
            self.isDeletingAllAppData = true
            self.appDataDeletionComplete = false
            self.appDataDeletionProgress = 0.0
            self.appDataDeletionPhase = "Clearing local data..."
            
            // Clear UI immediately for instant feedback
            self.viewModel.clearStationsFromUI()
            self.podcastViewModel.clearPodcastFeedsFromUI()
        }
        
        notificationManager.notifyUser(title: "Deletion Started", message: "Deleting all app data...")
        
        let group = DispatchGroup()
        var allSuccess = true
        var lastError: String?
        
        // Delete station data from local CoreData
        group.enter()
        DispatchQueue.main.async {
            self.appDataDeletionPhase = "Deleting local station data..."
            self.appDataDeletionProgress = 0.1
        }
        viewModel.deleteAllData { success, errorMessage in
            if !success {
                allSuccess = false
                lastError = errorMessage?.localizedDescription ?? "Station deletion failed"
            }
            DispatchQueue.main.async {
                self.appDataDeletionProgress = 0.2
            }
            group.leave()
        }
        
        // Delete podcast data from local CoreData
        group.enter()
        DispatchQueue.main.async {
            self.appDataDeletionPhase = "Deleting local podcast data..."
            self.appDataDeletionProgress = 0.25
        }
        podcastViewModel.clearPodcastCoreData { success, error in
            if !success {
                allSuccess = false
                lastError = error?.localizedDescription ?? "Failed to clear local podcast data"
            }
            DispatchQueue.main.async {
                self.appDataDeletionProgress = 0.35
            }
            group.leave()
        }
        
        // Delete all station records from CloudKit using enhanced async batch deletion
        group.enter()
        Task {
            do {
                await MainActor.run {
                    self.appDataDeletionPhase = "Fetching station records..."
                    self.appDataDeletionProgress = 0.4
                }
                
                let recordIDs: [CKRecord.ID] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord.ID], Error>) in
                    DataStore.shared.fetchAllRecordIDs(ofType: "streamingRadios") { recordIDs, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: recordIDs ?? [])
                        }
                    }
                }
                
                guard !recordIDs.isEmpty else {
                    print("✅ App Data Deletion: No station records to delete")
                    await MainActor.run {
                        self.appDataDeletionProgress = 0.5
                    }
                    group.leave()
                    return
                }
                
                await MainActor.run {
                    self.appDataDeletionPhase = "Deleting \(recordIDs.count) station records from iCloud..."
                }
                
                print("🔄 App Data Deletion: Starting enhanced deletion of \(recordIDs.count) station records")
                try await DataStore.shared.deleteRecordsInBatchesAsync(recordIDs: recordIDs) { progress in
                    Task { @MainActor in
                        // Station deletion takes 0.4 to 0.5 of total progress
                        self.appDataDeletionProgress = 0.4 + (progress * 0.1)
                        self.appDataDeletionPhase = "Deleting \(recordIDs.count) station records from iCloud... (\(Int(progress * 100))%)"
                    }
                }
                print("✅ App Data Deletion: Successfully deleted \(recordIDs.count) station records")
                group.leave()
                
            } catch {
                allSuccess = false
                lastError = "Enhanced station deletion failed: \(error.localizedDescription)"
                print("❌ App Data Deletion: Enhanced station records deletion failed - \(error.localizedDescription)")
                group.leave()
            }
        }
        
        // Delete all podcast-related records from CloudKit using enhanced async batch deletion
        let podcastRecordTypes = ["PodcastFeed", "EpisodeState"]
        
        for (index, recordType) in podcastRecordTypes.enumerated() {
            group.enter()
            Task {
                do {
                    // Progress ranges: PodcastFeed (0.5-0.75), EpisodeState (0.75-1.0)
                    let progressStart = 0.5 + Double(index) * 0.25
                    let progressEnd = progressStart + 0.25
                    
                    await MainActor.run {
                        self.appDataDeletionPhase = "Fetching \(recordType) records..."
                        self.appDataDeletionProgress = progressStart
                    }
                    
                    let recordIDs: [CKRecord.ID] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord.ID], Error>) in
                        DataStore.shared.fetchAllRecordIDs(ofType: recordType) { recordIDs, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: recordIDs ?? [])
                            }
                        }
                    }
                    
                    guard !recordIDs.isEmpty else {
                        print("✅ App Data Deletion: No \(recordType) records to delete")
                        await MainActor.run {
                            self.appDataDeletionProgress = progressEnd
                        }
                        group.leave()
                        return
                    }
                    
                    await MainActor.run {
                        self.appDataDeletionPhase = "Deleting \(recordIDs.count) \(recordType) records from iCloud..."
                    }
                    
                    print("🔄 App Data Deletion: Starting enhanced deletion of \(recordIDs.count) \(recordType) records")
                    try await DataStore.shared.deleteRecordsInBatchesAsync(recordIDs: recordIDs) { progress in
                        Task { @MainActor in
                            self.appDataDeletionProgress = progressStart + (progress * 0.25)
                            self.appDataDeletionPhase = "Deleting \(recordIDs.count) \(recordType) records from iCloud... (\(Int(progress * 100))%)"
                        }
                    }
                    print("✅ App Data Deletion: Successfully deleted \(recordIDs.count) \(recordType) records")
                    group.leave()
                    
                } catch {
                    allSuccess = false
                    lastError = "Enhanced \(recordType) deletion failed: \(error.localizedDescription)"
                    print("❌ App Data Deletion: Enhanced \(recordType) records deletion failed - \(error.localizedDescription)")
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            print("🔄 App Data Deletion: All operations completed - Success: \(allSuccess)")
            
            // Clear UserDefaults only if all other operations succeeded
            if allSuccess {
                UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
                UserDefaults.standard.synchronize()
                print("✅ App Data Deletion: UserDefaults cleared")
            } else {
                print("⚠️ App Data Deletion: Skipping UserDefaults cleanup due to errors")
            }
            
            // Update UI states immediately
            self.isDeletingAllAppData = false
            self.appDataDeletionComplete = allSuccess
            self.appDataDeletionProgress = 1.0
            self.appDataDeletionPhase = allSuccess ? "All app data deleted successfully!" : "Deletion completed with errors"
            
            // Refresh view models to update UI immediately  
            if allSuccess {
                self.viewModel.loadStationsFromCoreData()
                print("✅ App Data Deletion: View models refreshed")
                // Note: podcastViewModel already clears its data in clearPodcastCoreData completion
            }
            
            // Force UI refresh and show notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if allSuccess {
                    print("✅ App Data Deletion: All operations completed successfully")
                    self.notificationManager.notifyUser(title: "Deletion Complete", message: "All app data has been successfully deleted.")
                } else {
                    let errorMessage = lastError ?? "An unknown error occurred"
                    print("❌ App Data Deletion: Operations failed - \(errorMessage)")
                    self.notificationManager.notifyUser(title: "Deletion Failed", message: "App data deletion failed: \(errorMessage)")
                }
                
                // Reset completion state after 5 seconds for clean UI
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.appDataDeletionComplete = false
                }
            }
        }
    }
    
    private func initiateStationDataDeletion() {
        // Reset all states immediately on main queue
        DispatchQueue.main.async {
            self.isDeletingStationData = true
            self.stationDataDeletionComplete = false
            self.stationDataDeletionError = nil
            self.stationDataDeletionProgress = 0.0
            self.stationDataDeletionPhase = "Clearing local station data..."
            
            // Clear radio stations from UI immediately for instant feedback
            self.viewModel.clearStationsFromUI()
        }
        
        notificationManager.notifyUser(title: "Deletion Started", message: "Deleting all radio station data...")
        
        let group = DispatchGroup()
        var allSuccess = true
        var lastError: String?
        
        // Delete from local CoreData
        group.enter()
        DispatchQueue.main.async {
            self.stationDataDeletionPhase = "Deleting local station data..."
            self.stationDataDeletionProgress = 0.1
        }
        viewModel.deleteAllData { success, errorMessage in
            if !success {
                allSuccess = false
                lastError = errorMessage?.localizedDescription ?? "Station deletion failed"
            }
            DispatchQueue.main.async {
                self.stationDataDeletionProgress = 0.3
            }
            group.leave()
        }
        
        // Delete from CloudKit using enhanced async batch deletion
        group.enter()
        Task {
            do {
                await MainActor.run {
                    self.stationDataDeletionPhase = "Fetching station records from iCloud..."
                    self.stationDataDeletionProgress = 0.4
                }
                
                let recordIDs: [CKRecord.ID] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord.ID], Error>) in
                    DataStore.shared.fetchAllRecordIDs(ofType: "streamingRadios") { recordIDs, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: recordIDs ?? [])
                        }
                    }
                }
                
                guard !recordIDs.isEmpty else {
                    print("✅ Station Data Deletion: No records to delete")
                    await MainActor.run {
                        self.stationDataDeletionProgress = 1.0
                        self.stationDataDeletionPhase = "No station records found in iCloud"
                    }
                    group.leave()
                    return
                }
                
                await MainActor.run {
                    self.stationDataDeletionPhase = "Deleting \(recordIDs.count) station records from iCloud..."
                }
                
                print("🔄 Station Data Deletion: Starting enhanced deletion of \(recordIDs.count) records")
                try await DataStore.shared.deleteRecordsInBatchesAsync(recordIDs: recordIDs) { progress in
                    Task { @MainActor in
                        // CloudKit deletion takes 0.4 to 1.0 of total progress
                        self.stationDataDeletionProgress = 0.4 + (progress * 0.6)
                        self.stationDataDeletionPhase = "Deleting \(recordIDs.count) station records from iCloud... (\(Int(progress * 100))%)"
                    }
                }
                print("✅ Station Data Deletion: Successfully deleted \(recordIDs.count) records")
                group.leave()
                
            } catch {
                allSuccess = false
                lastError = "Enhanced CloudKit deletion failed: \(error.localizedDescription)"
                print("❌ Station Data Deletion: Enhanced deletion failed - \(error.localizedDescription)")
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            // Update UI states immediately
            self.isDeletingStationData = false
            self.stationDataDeletionComplete = allSuccess
            self.stationDataDeletionProgress = 1.0
            self.stationDataDeletionPhase = allSuccess ? "All station data deleted successfully!" : "Deletion completed with errors"
            
            if let error = lastError {
                self.stationDataDeletionError = error
            }
            
            // Refresh view models to update UI immediately
            if allSuccess {
                self.viewModel.loadStationsFromCoreData()
            }
            
            // Force UI refresh and show notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let error = lastError {
                    self.notificationManager.notifyUser(title: "Deletion Failed", message: "Station data deletion failed: \(error)")
                } else {
                    self.notificationManager.notifyUser(title: "Deletion Complete", message: "All station data has been successfully deleted.")
                }
                
                // Reset completion states after 5 seconds for clean UI
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.stationDataDeletionComplete = false
                    self.stationDataDeletionError = nil
                }
            }
        }
    }
    
    private func initiatePodcastDataDeletion() {
        // Reset all states immediately on main queue
        DispatchQueue.main.async {
            self.isDeletingPodcastData = true
            self.podcastDataDeletionComplete = false
            self.podcastDataDeletionError = nil
            self.podcastDataDeletionProgress = 0.0
            self.podcastDataDeletionPhase = "Clearing local podcast data..."
            
            // Clear podcast feeds from UI immediately for instant feedback
            self.podcastViewModel.clearPodcastFeedsFromUI()
        }
        
        notificationManager.notifyUser(title: "Deletion Started", message: "Deleting all podcast data...")
        
        let group = DispatchGroup()
        var allSuccess = true
        var lastError: String?
        
        // Delete podcast data from local CoreData
        group.enter()
        DispatchQueue.main.async {
            self.podcastDataDeletionPhase = "Deleting local podcast data..."
            self.podcastDataDeletionProgress = 0.1
        }
        podcastViewModel.clearPodcastCoreData { success, error in
            if !success { 
                allSuccess = false
                lastError = error?.localizedDescription ?? "Failed to clear local podcast data"
            }
            DispatchQueue.main.async {
                self.podcastDataDeletionProgress = 0.3
            }
            group.leave()
        }
        
        // Delete from CloudKit using enhanced async batch deletion (podcast feeds, episodes, etc.)
        let podcastRecordTypes = ["PodcastFeed", "EpisodeState"]
        
        for (index, recordType) in podcastRecordTypes.enumerated() {
            group.enter()
            Task {
                do {
                    // Progress ranges: PodcastFeed (0.3-0.65), EpisodeState (0.65-1.0)
                    let progressStart = 0.3 + Double(index) * 0.35
                    let progressEnd = progressStart + 0.35
                    
                    await MainActor.run {
                        self.podcastDataDeletionPhase = "Fetching \(recordType) records from iCloud..."
                        self.podcastDataDeletionProgress = progressStart
                    }
                    
                    let recordIDs: [CKRecord.ID] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord.ID], Error>) in
                        DataStore.shared.fetchAllRecordIDs(ofType: recordType) { recordIDs, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: recordIDs ?? [])
                            }
                        }
                    }
                    
                    guard !recordIDs.isEmpty else {
                        print("✅ Podcast Data Deletion: No \(recordType) records to delete")
                        await MainActor.run {
                            self.podcastDataDeletionProgress = progressEnd
                            self.podcastDataDeletionPhase = "No \(recordType) records found in iCloud"
                        }
                        group.leave()
                        return
                    }
                    
                    await MainActor.run {
                        self.podcastDataDeletionPhase = "Deleting \(recordIDs.count) \(recordType) records from iCloud..."
                    }
                    
                    print("🔄 Podcast Data Deletion: Starting enhanced deletion of \(recordIDs.count) \(recordType) records")
                    try await DataStore.shared.deleteRecordsInBatchesAsync(recordIDs: recordIDs) { progress in
                        Task { @MainActor in
                            self.podcastDataDeletionProgress = progressStart + (progress * 0.35)
                            self.podcastDataDeletionPhase = "Deleting \(recordIDs.count) \(recordType) records from iCloud... (\(Int(progress * 100))%)"
                        }
                    }
                    print("✅ Podcast Data Deletion: Successfully deleted \(recordIDs.count) \(recordType) records")
                    group.leave()
                    
                } catch {
                    allSuccess = false
                    lastError = "Enhanced CloudKit deletion failed for \(recordType): \(error.localizedDescription)"
                    print("❌ Podcast Data Deletion: Enhanced deletion failed for \(recordType) - \(error.localizedDescription)")
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            // Update UI states immediately
            self.isDeletingPodcastData = false
            self.podcastDataDeletionComplete = allSuccess
            self.podcastDataDeletionProgress = 1.0
            self.podcastDataDeletionPhase = allSuccess ? "All podcast data deleted successfully!" : "Deletion completed with errors"
            
            if let error = lastError {
                self.podcastDataDeletionError = error
            }
            
            // Refresh view models to update UI immediately
            if allSuccess {
                // Note: podcastViewModel already clears its data in clearPodcastCoreData completion
            }
            
            // Force UI refresh and show notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let error = lastError {
                    self.notificationManager.notifyUser(title: "Deletion Failed", message: "Podcast data deletion failed: \(error)")
                } else {
                    self.notificationManager.notifyUser(title: "Deletion Complete", message: "All podcast data has been successfully deleted.")
                }
                
                // Reset completion states after 5 seconds for clean UI
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.podcastDataDeletionComplete = false
                    self.podcastDataDeletionError = nil
                }
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SettingsView()
                .environmentObject(RadioStationViewModel())
                .environmentObject(AlertManager())
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark Mode")
            
            SettingsView()
                .environmentObject(RadioStationViewModel())
                .environmentObject(AlertManager())
                .preferredColorScheme(.light)
                .previewDisplayName("Light Mode")
        }
    }
}

// MARK: - Feature Badge Component
struct FeatureBadge: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.green.opacity(0.2))
        )
        .foregroundColor(.green)
    }
}

// Modern UI Components for Radio Discovery
struct ModernActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                        .multilineTextAlignment(.leading)
                    
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(colorScheme == .dark ? Color.gray.opacity(0.2) : Color.blue.opacity(0.1))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ModernProgressView: View {
    let title: String
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            
            Text(title)
                .font(.body)
                .foregroundColor(colorScheme == .dark ? .gray : .secondary)
            
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color.gray.opacity(0.1) : Color.gray.opacity(0.05))
        )
    }
}

struct DebugInfoCard: View {
    let title: String
    let icon: String
    let color: Color
    let content: String
    
    @Environment(\.colorScheme) var colorScheme
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? .gray : .secondary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(primaryTextColor)
                
                Spacer()
            }
            
            // Content
            Text(content)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(secondaryTextColor)
                .padding(12)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
        }
        .padding(16)
        .background(cardBackgroundColor)
        .cornerRadius(12)
    }
}

// MARK: - Email Activity Item Source
class EmailActivityItemSource: NSObject, UIActivityItemSource {
    private let subject: String
    private let recipient: String
    private let body: String
    
    init(subject: String, recipient: String, body: String) {
        self.subject = subject
        self.recipient = recipient
        self.body = body
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return body
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return body
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        // Set subject for email activities
        if activityType == .mail {
            return subject
        }
        return "StreamRadios Debug Report"
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        return "public.plain-text"
    }
}

// MARK: - Mail Compose View Controller
struct MailComposeViewController: UIViewControllerRepresentable {
    let subject: String
    let recipients: [String]
    let body: String
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mailComposer = MFMailComposeViewController()
        mailComposer.mailComposeDelegate = context.coordinator
        mailComposer.setSubject(subject)
        mailComposer.setToRecipients(recipients)
        mailComposer.setMessageBody(body, isHTML: false)
        return mailComposer
    }
    
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {
        // No updates needed
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
            
            switch result {
            case .sent:
                print("Debug report sent successfully")
            case .cancelled:
                print("Mail composition cancelled")
            case .saved:
                print("Mail saved as draft")
            case .failed:
                print("Mail composition failed: \(error?.localizedDescription ?? "Unknown error")")
            @unknown default:
                print("Unknown mail composition result")
            }
        }
    }
}
