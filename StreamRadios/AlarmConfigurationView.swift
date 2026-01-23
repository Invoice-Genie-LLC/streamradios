//
//  AlarmConfigurationView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/29/24.
//

import SwiftUI
import UserNotifications
import EventKit
import UIKit
import BackgroundTasks

struct AlarmConfigurationView: View {
    // Scroll detection bindings for TabView hide functionality
    @Binding var isScrolling: Bool
    @Binding var isFooterMenuHidden: Bool
    
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("alarmTimeString") private var alarmTimeString = ""
    @AppStorage("isAlarmEnabled") private var isAlarmEnabled = false
    @AppStorage("selectedStationIndex") private var selectedStationIndex = 0
    @AppStorage("showName") private var showName = ""
    @State private var alarmTime: Date
    @State private var selectedDays: [Bool] // Array of 7 booleans, one for each day
    @State private var showSavedIndicator = false
    private let eventStore = EKEventStore()
    @State private var showCalendarAccessAlert = false
    @State private var shouldRequestCalendarAccess = false
    @State private var calendarAccessStatus = "Not requested"
    @AppStorage("isSingleTimeAlert") private var isSingleTimeAlert = false
    
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @StateObject private var radioPlayer = RadioPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @State private var showPodcastPlayerSheet = false
    @State private var selectedTab: Tab = .settings // Alarm is part of settings
    @State private var isPlayerSheetPresented = false
    
    private let miniPlayerHeight: CGFloat = 60
    
    let daysOfWeek = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    
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
    
    // Default initializer for backward compatibility
    init() {
        self._isScrolling = .constant(false)
        self._isFooterMenuHidden = .constant(false)
        _alarmTime = State(initialValue: Self.loadAlarmTime())
        _selectedDays = State(initialValue: Self.loadSelectedDays())
    }
    
    // Main initializer with scroll detection bindings
    init(isScrolling: Binding<Bool>, isFooterMenuHidden: Binding<Bool>) {
        self._isScrolling = isScrolling
        self._isFooterMenuHidden = isFooterMenuHidden
        _alarmTime = State(initialValue: Self.loadAlarmTime())
        _selectedDays = State(initialValue: Self.loadSelectedDays())
    }
    
    private var hasFavoriteStations: Bool {
        !viewModel.stations.filter { $0.isFavorite }.isEmpty
    }
    

    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 24) {
                        alarmToggleSection
                        stationSelectionSection
                        alarmTypeSection
                        timeSection
                        daysSection
                        showNameSection
                        savedIndicator
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 140)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10) // Set minimum distance to 10 to avoid interfering with button taps
                        .onChanged { _ in
                            // IMMEDIATE update - no conditions, just set it
                            DispatchQueue.main.async {
                                if !isScrolling {
                                    print("🏠 DEBUG: Setting isScrolling = true in AlarmConfigurationView")
                                    isScrolling = true
                                    // REMOVED: isFooterMenuHidden = true - let ContentView shouldHideFooterMenu logic handle this
                                }
                            }
                        }
                        .onEnded { _ in
                            // Debounce the scroll end to prevent rapid state changes
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                print("🏠 DEBUG: Setting isScrolling = false in AlarmConfigurationView")
                                isScrolling = false
                                // Note: Don't reset isFooterMenuHidden here - let home button control it
                            }
                        }
                )
                
                // Global Player is now handled by ContentView overlay
                // This ensures consistent player display across all tabs
            }
            .background(backgroundColor)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { _ in
                    // Dismiss keyboard when tapping outside input fields
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            )
        }
        .navigationTitle("Set Program Alert")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $showCalendarAccessAlert) {
            Alert(
                title: Text("Calendar Access Required"),
                message: Text("This app requires access to the calendar to schedule radio station program alerts. Please enable calendar access in Settings."),
                primaryButton: .default(Text("Settings"), action: openSettings),
                secondaryButton: .cancel()
            )
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
    }
    
    // MARK: - UI Sections
    
    @ViewBuilder
    private var alarmToggleSection: some View {
        AlarmCard(
            title: "Alert Configuration",
            icon: ""
        ) {
            AlarmToggleRow(
                title: "Enable Alert",
                subtitle: hasFavoriteStations ? "Turn on to receive radio program alerts" : "Add favorite stations first to enable alerts",
                isOn: $isAlarmEnabled,
                icon: "bell.badge",
                isEnabled: hasFavoriteStations
            )
            .onChange(of: isAlarmEnabled) { newValue in
                if newValue {
                    if hasFavoriteStations {
                        requestCalendarAccess()
                    } else {
                        isAlarmEnabled = false
                    }
                } else {
                    cancelAlarm()
                }
            }
        }
    }
    
    @ViewBuilder
    private var stationSelectionSection: some View {
        if hasFavoriteStations {
            AlarmCard(
                title: "Station Selection",
                icon: ""
            ) {
                if isAlarmEnabled {
                    let favoriteStations = viewModel.stations.filter { $0.isFavorite }
                    if favoriteStations.indices.contains(selectedStationIndex) {
                        StationPicker(
                            stations: favoriteStations,
                            selectedIndex: $selectedStationIndex
                        )
                        .onChange(of: selectedStationIndex) { _ in
                            saveAlarm()
                        }
                    } else {
                        ErrorMessage(
                            text: "Please select a favorite station",
                            icon: "exclamationmark.triangle.fill"
                        )
                    }
                } else {
                    DisabledMessage(
                        text: "Enable alert to select a station",
                        icon: "radio"
                    )
                }
            }
        } else {
            AlarmCard(
                title: "Station Selection",
                icon: "",
                isWarning: true
            ) {
                NoStationsMessage(
                    onNavigateToStations: {
                        presentationMode.wrappedValue.dismiss()
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .switchToAllTab, object: nil)
                        }
                    }
                )
            }
        }
    }
    
    @ViewBuilder
    private var alarmTypeSection: some View {
        AlarmCard(
            title: "Alert Type",
            icon: ""
        ) {
            SegmentedControl(
                title: "Choose alert frequency",
                options: ["Repeating", "Single Time"],
                selection: Binding(
                    get: { isSingleTimeAlert ? 1 : 0 },
                    set: { isSingleTimeAlert = $0 == 1 }
                ),
                isEnabled: isAlarmEnabled && hasFavoriteStations
            )
            .onChange(of: isSingleTimeAlert) { _ in
                saveAlarm()
            }
        }
    }
    
    @ViewBuilder
    private var timeSection: some View {
        AlarmCard(
            title: "Alert Time",
            icon: ""
        ) {
            TimePicker(
                time: $alarmTime,
                isEnabled: isAlarmEnabled && hasFavoriteStations
            )
            .onChange(of: alarmTime) { _ in
                saveAlarm()
            }
        }
    }
    
    @ViewBuilder
    private var daysSection: some View {
        if !isSingleTimeAlert {
            AlarmCard(
                title: "Repeat Days",
                icon: ""
            ) {
                DaySelector(
                    selectedDays: $selectedDays,
                    daysOfWeek: daysOfWeek,
                    isEnabled: isAlarmEnabled && hasFavoriteStations
                )
                .onChange(of: selectedDays) { _ in
                    saveAlarm()
                }
            }
        }
    }
    
    @ViewBuilder
    private var showNameSection: some View {
        AlarmCard(
            title: "Show Name",
            icon: ""
        ) {
            if isAlarmEnabled && hasFavoriteStations {
                ShowNameField(
                    showName: $showName,
                    placeholder: "Enter Show Name (Optional)"
                )
                .onChange(of: showName) { _ in
                    saveAlarm()
                }
                .onAppear {
                    updateSelectedStationIndex()
                }
                .onChange(of: viewModel.stations) { _ in
                    updateSelectedStationIndex()
                }
                .onChange(of: shouldRequestCalendarAccess) { newValue in
                    if newValue {
                        requestCalendarAccess { granted in
                            if granted {
                                saveAlarm()
                            } else {
                                isAlarmEnabled = false
                            }
                            shouldRequestCalendarAccess = false
                        }
                    }
                }
            } else {
                DisabledMessage(
                    text: "Enable alert to enter show name",
                    icon: "text.bubble"
                )
            }
        }
    }
    
    @ViewBuilder
    private var savedIndicator: some View {
        if showSavedIndicator {
            SavedIndicator()
        }
    }
    

    
    // MARK: - Helper Methods (Preserved from original)
    
    private func updateSelectedStationIndex() {
        let favoriteStations = viewModel.stations.filter { $0.isFavorite }
        if !favoriteStations.indices.contains(selectedStationIndex) {
            selectedStationIndex = favoriteStations.indices.first ?? 0
        }
    }
    
    private func handleAccessResult(granted: Bool) {
        if granted {
            calendarAccessStatus = "Granted"
            saveAlarm()
        } else {
            calendarAccessStatus = "Denied"
            isAlarmEnabled = false
            showCalendarAccessAlert = true
        }
    }
    
    private func requestCalendarAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        
        switch status {
        case .notDetermined:
            if #available(iOS 17.0, *) {
                Task {
                    do {
                        let granted = try await eventStore.requestFullAccessToEvents()
                        await MainActor.run {
                            handleAccessResult(granted: granted)
                        }
                    } catch {
                        await MainActor.run {
                            calendarAccessStatus = "Error"
                            isAlarmEnabled = false
                            showCalendarAccessAlert = true
                        }
                    }
                }
            } else {
                eventStore.requestAccess(to: .event) { granted, error in
                    DispatchQueue.main.async {
                        self.handleAccessResult(granted: granted)
                    }
                }
            }
        case .authorized, .fullAccess:
            calendarAccessStatus = "Already Granted"
            saveAlarm()
        case .restricted, .denied, .writeOnly:
            calendarAccessStatus = "Restricted or Denied"
            isAlarmEnabled = false
            showCalendarAccessAlert = true
        @unknown default:
            calendarAccessStatus = "Unknown"
            isAlarmEnabled = false
            showCalendarAccessAlert = true
        }
    }
    
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    
    private static func loadAlarmTime() -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if let timeString = UserDefaults.standard.string(forKey: "alarmTimeString"),
           let date = formatter.date(from: timeString) {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.hour, .minute], from: date)
            return calendar.date(bySettingHour: components.hour ?? 0, minute: components.minute ?? 0, second: 0, of: Date()) ?? Date()
        } else {
            return Date()
        }
    }
    
    private static func loadSelectedDays() -> [Bool] {
        if let savedDays = UserDefaults.standard.array(forKey: "selectedDays") as? [Bool], savedDays.count == 7 {
            return savedDays
        }
        return Array(repeating: false, count: 7) // Default to all days unselected
    }
    
    private func saveAlarm() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        alarmTimeString = formatter.string(from: alarmTime)
        
        UserDefaults.standard.set(selectedDays, forKey: "selectedDays")
        UserDefaults.standard.set(showName, forKey: "showName")
        UserDefaults.standard.set(isSingleTimeAlert, forKey: "isSingleTimeAlert")
        
        let alarmDetails = AlarmDetails(
            time: alarmTime,
            days: selectedDays,
            isEnabled: isAlarmEnabled,
            stationIndex: selectedStationIndex,
            showName: showName,
            isSingleTimeAlert: isSingleTimeAlert
        )
        
        // Save alarm details to UserDefaults
        let favoriteStations = viewModel.stations.filter { $0.isFavorite }
        if selectedStationIndex < favoriteStations.count {
            let selectedStation = favoriteStations[selectedStationIndex]
            UserDefaults.standard.set(selectedStation.id, forKey: "FavoriteStationID")
            print("Saved FavoriteStationID: \(selectedStation.id)")
        }
        
        if isAlarmEnabled {
            scheduleAlarm(for: alarmDetails)
        } else {
            cancelAlarm()
        }
        
        // Show the saved indicator
        withAnimation {
            showSavedIndicator = true
        }
        
        // Hide the indicator after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showSavedIndicator = false
            }
        }
    }
    
    private func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .event)
        
        switch status {
        case .notDetermined:
            eventStore.requestAccess(to: .event) { granted, error in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .authorized, .fullAccess:
            completion(true)
        case .restricted, .denied, .writeOnly:
            completion(false)
        @unknown default:
            print("Unknown calendar authorization status")
            completion(false)
        }
    }
    
    private func requestNotificationAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("Notification authorization granted")
                    completion(true)
                } else {
                    print("Notification authorization denied")
                    if let error = error {
                        print("Authorization error: \(error.localizedDescription)")
                    }
                    completion(false)
                }
            }
        }
    }
    
    private func scheduleAlarm(for alarm: AlarmDetails) {
        if alarm.isSingleTimeAlert {
            scheduleSingleTimeAlarm(for: alarm)
        } else {
            scheduleRepeatingAlarm(for: alarm)
        }
        scheduleBackgroundTask(for: alarm)
        scheduleSilentPushNotification(for: alarm)
    }
    
    private func scheduleRepeatingAlarm(for alarm: AlarmDetails) {
        print("Scheduling repeating alarm for \(alarm.time)")
        
        let center = UNUserNotificationCenter.current()
        
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else { return }
            
            // Load the favorite station using the saved station ID
            let favoriteStations = viewModel.stations.filter { $0.isFavorite }
            var stationName = "your favorite station"
            if let favoriteStationID = UserDefaults.standard.string(forKey: "FavoriteStationID"),
               let favoriteStation = favoriteStations.first(where: { $0.id == favoriteStationID }) {
                stationName = favoriteStation.name
            }
            
            for (index, isSelected) in alarm.days.enumerated() where isSelected {
                var dateComponents = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
                dateComponents.weekday = index + 1 // weekday is 1-7
                
                let content = UNMutableNotificationContent()
                content.title = "Attention!"
                if alarm.showName.isEmpty {
                    content.body = "Time to listen to \(stationName)"
                } else {
                    content.body = "Time to listen to \(alarm.showName) on \(stationName)"
                }
                content.sound = UNNotificationSound.default
                content.userInfo = ["stationIndex": alarm.stationIndex, "alarmType": "streamRadiosAlarm"]
                
                let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
                let request = UNNotificationRequest(identifier: "wakeUpAlarm\(index)", content: content, trigger: trigger)
                
                center.add(request) { error in
                    if let error = error {
                        print("Error scheduling repeating notification: \(error)")
                    } else {
                        print("Successfully scheduled repeating notification for day \(index + 1)")
                    }
                }
            }
        }
    }
    
    private func scheduleSingleTimeAlarm(for alarm: AlarmDetails) {
        print("Scheduling single time alarm for \(alarm.time)")
        
        let center = UNUserNotificationCenter.current()
        
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else { return }
            
            let favoriteStations = viewModel.stations.filter { $0.isFavorite }
            var stationName = "your favorite station"
            if let favoriteStationID = UserDefaults.standard.string(forKey: "FavoriteStationID"),
               let favoriteStation = favoriteStations.first(where: { $0.id == favoriteStationID }) {
                stationName = favoriteStation.name
            }
            
            let content = UNMutableNotificationContent()
            content.title = "Attention!"
            if alarm.showName.isEmpty {
                content.body = "Time to listen to \(stationName)"
            } else {
                content.body = "Time to listen to \(alarm.showName) on \(stationName)"
            }
            content.sound = UNNotificationSound.default
            content.userInfo = ["stationIndex": alarm.stationIndex, "alarmType": "streamRadiosAlarm"]
            
            let triggerDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alarm.time)
            let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)
            let request = UNNotificationRequest(identifier: "singleTimeAlarm", content: content, trigger: trigger)
            
            center.add(request) { error in
                if let error = error {
                    print("Error scheduling single time notification: \(error)")
                }
            }
        }
    }
    
    private func scheduleLocalNotification(for alarm: AlarmDetails) {
        let center = UNUserNotificationCenter.current()
        
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else { return }
            
            // Load the favorite station using the saved station ID
            let favoriteStations = viewModel.stations.filter { $0.isFavorite }
            var stationName = "your favorite station"
            if let favoriteStationID = UserDefaults.standard.string(forKey: "FavoriteStationID"),
               let favoriteStation = favoriteStations.first(where: { $0.id == favoriteStationID }) {
                stationName = favoriteStation.name
            }
            
            for (index, isSelected) in alarm.days.enumerated() where isSelected {
                var dateComponents = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
                dateComponents.weekday = index + 1 // weekday is 1-7
                
                let content = UNMutableNotificationContent()
                content.title = "Attention!"
                if alarm.showName.isEmpty {
                    content.body = "Time to listen to \(stationName)"
                } else {
                    content.body = "Time to listen to \(alarm.showName) on \(stationName)"
                }
                content.sound = UNNotificationSound.default
                content.userInfo = ["stationIndex": alarm.stationIndex]
                
                let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
                let request = UNNotificationRequest(identifier: "wakeUpAlarm\(index)", content: content, trigger: trigger)
                
                center.add(request) { error in
                    if let error = error {
                        print("Error scheduling notification: \(error)")
                    }
                }
            }
        }
    }
    
    private func scheduleBackgroundTask(for alarm: AlarmDetails) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "com.streamradios.playalarm")
        for (index, isSelected) in alarm.days.enumerated() where isSelected {
            var dateComponents = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
            dateComponents.weekday = index + 1 // weekday is 1-7
            
            let nextAlarmDate = Calendar.current.nextDate(after: Date(), matching: dateComponents, matchingPolicy: .nextTime) ?? Date()
            
            let request = BGProcessingTaskRequest(identifier: "com.streamradios.playalarm")
            request.earliestBeginDate = nextAlarmDate
            request.requiresNetworkConnectivity = false
            request.requiresExternalPower = false
            
            do {
                try BGTaskScheduler.shared.submit(request)
                print("Background task scheduled for \(nextAlarmDate)")
            } catch {
                if let bgError = error as? BGTaskScheduler.Error {
                    switch bgError.code {
                    case .unavailable:
                        print("Background tasks are unavailable. Ensure background fetch is enabled in capabilities.")
                    case .tooManyPendingTaskRequests:
                        print("Too many pending task requests. Consider consolidating tasks.")
                    case .notPermitted:
                        print("Background tasks are not permitted. Check if the user has disabled background refresh.")
                    @unknown default:
                        print("Unknown BGTaskScheduler error: \(error.localizedDescription)")
                    }
                } else {
                    print("Could not schedule background task: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func scheduleSilentPushNotification(for alarm: AlarmDetails) {
        // ToDo
        // This would typically involve sending a request to the server
        // to schedule a silent push notification for the alarm time.
        // As this requires server-side implementation, we'll just print a placeholder message.
        print("Silent push notification would be scheduled for \(alarm.time)")
    }
    
    private func presentCalendarAccessAlert() {
        let alert = UIAlertController(
            title: "Calendar Access Required",
            message: "This app requires access to the calendar to schedule radio station program alerts. Please enable calendar access in Settings.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
            if let appSettings = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(appSettings, options: [:], completionHandler: nil)
            }
        })
        
        if let viewController = UIApplication.shared.keyWindow?.rootViewController {
            viewController.present(alert, animated: true, completion: nil)
        }
    }
    
    private func cancelAlarm() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "com.streamradios.playalarm")
        print("All alarms cancelled")
    }
}

// MARK: - UI Components for Alarm Configuration

struct AlarmCard<Content: View>: View {
    let title: String
    let icon: String
    let isWarning: Bool
    let content: () -> Content
    
    @Environment(\.colorScheme) var colorScheme
    
    init(title: String, icon: String, isWarning: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.isWarning = isWarning
        self.content = content
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    private var titleColor: Color {
        if isWarning {
            return .orange
        }
        return colorScheme == .dark ? .white : .primary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
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

struct AlarmToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let icon: String
    let isEnabled: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(isEnabled ? .blue : .gray)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(isEnabled ? (colorScheme == .dark ? .gray : .secondary) : .red)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .disabled(!isEnabled)
        }
    }
}

struct StationPicker: View {
    let stations: [RadioStation]
    @Binding var selectedIndex: Int
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "radio")
                    .font(.body)
                    
                    .frame(width: 20)
                
                Text("Selected Station")
                    .font(.body)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                
                Spacer()
            }
            
            Picker("Favorite Station", selection: $selectedIndex) {
                ForEach(stations.indices, id: \.self) { index in
                    Text(stations[index].name).tag(index)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

struct SegmentedControl: View {
    let title: String
    let options: [String]
    @Binding var selection: Int
    let isEnabled: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(colorScheme == .dark ? .gray : .secondary)
            
            Picker(title, selection: $selection) {
                ForEach(0..<options.count, id: \.self) { index in
                    Text(options[index]).tag(index)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1.0 : 0.6)
        }
    }
}

struct TimePicker: View {
    @Binding var time: Date
    let isEnabled: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.body)
                    
                    .frame(width: 20)
                
                Text("Alert Time")
                    .font(.body)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                
                Spacer()
            }
            
            DatePicker("Setup Alert Time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(WheelDatePickerStyle())
                .labelsHidden()
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1.0 : 0.6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
        }
    }
}

struct DaySelector: View {
    @Binding var selectedDays: [Bool]
    let daysOfWeek: [String]
    let isEnabled: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.body)
                    
                    .frame(width: 20)
                
                Text("Repeat on these days")
                    .font(.body)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                
                Spacer()
            }
            
            VStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: selectedDays[index] ? "checkmark.circle.fill" : "circle")
                            .font(.headline)
                            .foregroundColor(selectedDays[index] ? .blue : .gray)
                        
                        Text(daysOfWeek[index])
                            .font(.body)
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                        
                        Spacer()
                        
                        Toggle("", isOn: $selectedDays[index])
                            .labelsHidden()
                            .disabled(!isEnabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(selectedDays[index] ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .onTapGesture {
                        if isEnabled {
                            selectedDays[index].toggle()
                        }
                    }
                }
            }
        }
    }
}

struct ShowNameField: View {
    @Binding var showName: String
    let placeholder: String
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.body)
                    
                    .frame(width: 20)
                
                Text("Show Name")
                    .font(.body)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                
                Spacer()
            }
            
            HStack {
                TextField(placeholder, text: $showName)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(.leading, 4)
                
                if !showName.isEmpty {
                    Button(action: {
                        showName = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

struct ErrorMessage: View {
    let text: String
    let icon: String
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.red)
            
            Text(text)
                .font(.body)
                .foregroundColor(.red)
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
}

struct DisabledMessage: View {
    let text: String
    let icon: String
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.gray)
            
            Text(text)
                .font(.body)
                .foregroundColor(.gray)
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct NoStationsMessage: View {
    let onNavigateToStations: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundColor(.orange)
                
                Text("No Favorite Stations")
                    .font(.body)
                    .foregroundColor(.orange)
            }
            
            Text("No favorite stations yet. Click \"Go to All Stations\" to add one or more favorites before scheduling alerts.")
                .font(.body)
                .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                .lineLimit(nil)
            
            Button(action: onNavigateToStations) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.body)
                    Text("Go to All Stations")
                        .font(.body)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
    }
}

struct SavedIndicator: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundColor(.green)
            
            Text("Changes saved")
                .font(.body)
                .foregroundColor(colorScheme == .dark ? .white : .primary)
        }
        .padding(12)
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
    }
}

struct AlarmDetails: Codable {
    let time: Date
    let days: [Bool]
    let isEnabled: Bool
    let stationIndex: Int
    let showName: String
    let isSingleTimeAlert: Bool
}

struct AlarmConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AlarmConfigurationView()
                .environmentObject(RadioStationViewModel())
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark Mode")
            
            AlarmConfigurationView()
                .environmentObject(RadioStationViewModel())
                .preferredColorScheme(.light)
                .previewDisplayName("Light Mode")
        }
    }
}

extension Notification.Name {
    static let switchToAllTab = Notification.Name("switchToAllTab")
}
