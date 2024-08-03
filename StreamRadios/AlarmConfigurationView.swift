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
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Environment(\.presentationMode) var presentationMode
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
    
    let daysOfWeek = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    
    init() {
        _alarmTime = State(initialValue: Self.loadAlarmTime())
        _selectedDays = State(initialValue: Self.loadSelectedDays())
    }
    
    private var hasFavoriteStations: Bool {
        !viewModel.stations.filter { $0.isFavorite }.isEmpty
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Setup Station")) {
                    if isAlarmEnabled && hasFavoriteStations {
                        let favoriteStations = viewModel.stations.filter { $0.isFavorite }
                        if favoriteStations.indices.contains(selectedStationIndex) {
                            Picker("Favorite Station", selection: $selectedStationIndex) {
                                ForEach(favoriteStations.indices, id: \.self) { index in
                                    Text(favoriteStations[index].name).tag(index)
                                }
                            }
                            .onChange(of: selectedStationIndex) { _ in
                                saveAlarm()
                            }
                        } else {
                            Text("Please select a favorite station")
                                .foregroundColor(.red)
                        }
                    } else if !hasFavoriteStations {
                        ButtonWithNonClickableText(
                            text: "No favorite stations have been configured. Please add a station to your favorites in the 'Favorites' tab before scheduling an alert.",
                            buttonText: "Go to All Stations"
                        ) {
                            self.presentationMode.wrappedValue.dismiss()
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: .switchToAllTab, object: nil)
                            }
                            
                        }
                        
                    } else {
                        Text("Enable alert to select a station")
                            .foregroundColor(.gray)
                    }
                }
                Section {
                    Toggle("Enable Alert", isOn: $isAlarmEnabled)
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
                        .disabled(!hasFavoriteStations)
                    
                }
                Section(header: Text("Alert Type")) {
                    Picker("Alert Type", selection: $isSingleTimeAlert) {
                        Text("Repeating").tag(false)
                        Text("Single Time").tag(true)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .disabled(!isAlarmEnabled || !hasFavoriteStations)
                    .onChange(of: isSingleTimeAlert) { newValue in
                        saveAlarm()
                    }
                }
                Section(header: Text("Radio Program Alert Time")) {
                    DatePicker("Setup Alert Time", selection: $alarmTime, displayedComponents: .hourAndMinute)
                        .onChange(of: alarmTime) { _ in
                            saveAlarm()
                        }
                        .disabled(!isAlarmEnabled || !hasFavoriteStations)
                }
                if !isSingleTimeAlert {
                    Section(header: Text("Select day of the week to repeat alert")) {
                        ForEach(0..<7) { index in
                            Toggle(daysOfWeek[index], isOn: $selectedDays[index])
                                .onChange(of: selectedDays[index]) { _ in
                                    saveAlarm()
                                }
                                .disabled(!isAlarmEnabled || !hasFavoriteStations)
                        }
                    }
                }
                
                Section(header: Text("Show Name")) {
                    if isAlarmEnabled {
                        HStack {
                            TextField("Enter Show Name", text: $showName)
                                .padding(.trailing, 30)
                            
                            if !showName.isEmpty {
                                Button(action: {
                                    showName = ""
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.gray)
                                }
                                .padding(.trailing, 8)
                            }
                        }
                        .onAppear {
                            updateSelectedStationIndex()
                        }
                        .onChange(of: viewModel.stations) { _ in
                            updateSelectedStationIndex()
                        }
                        .onChange(of: showName) { _ in
                            saveAlarm()
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
                        Text("Enable alert to enter show name")
                            .foregroundColor(.gray)
                    }
                }
                .disabled(!isAlarmEnabled || !hasFavoriteStations)
                
                if showSavedIndicator {
                    HStack {
                        Spacer()
                        Text("Changes saved")
                            .foregroundColor(.green)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Set Program Alert")
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert(isPresented: $showCalendarAccessAlert) {
            Alert(
                title: Text("Calendar Access Required"),
                message: Text("This app requires access to the calendar to schedule radio station program alerts. Please enable calendar access in Settings."),
                primaryButton: .default(Text("Settings"), action: openSettings),
                secondaryButton: .cancel()
            )
        }
    }
    
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
        AlarmConfigurationView()
            .environmentObject(RadioStationViewModel())
    }
}

extension Notification.Name {
    static let switchToAllTab = Notification.Name("switchToAllTab")
}

struct ButtonWithNonClickableText: View {
    let text: String
    let buttonText: String
    let action: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .foregroundColor(.red)
                .font(.callout)
            
            Button(action: action) {
                HStack {
                    Image(systemName: "list.bullet")
                    Text(buttonText)
                }
                .padding(8)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle()) // This ensures only the button itself is clickable
        }
        .contentShape(Rectangle()) // This makes the whole VStack tappable
        .onTapGesture {} // This consumes taps on the VStack, preventing row highlight
    }
}
