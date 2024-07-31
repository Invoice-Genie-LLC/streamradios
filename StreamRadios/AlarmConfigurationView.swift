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
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @AppStorage("alarmTimeString") private var alarmTimeString = ""
    @AppStorage("isAlarmEnabled") private var isAlarmEnabled = false
    @AppStorage("selectedStationIndex") private var selectedStationIndex = 0
    @State private var favoriteStation: RadioStation?
    @State private var selectedFavoriteStationIndex = 0
    @State private var alarmTime: Date
    @State private var selectedDays: [Bool] // Array of 7 booleans, one for each day
    @State private var showSavedIndicator = false
    private let eventStore = EKEventStore()
    
    let daysOfWeek = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    
    init() {
        _alarmTime = State(initialValue: Self.loadAlarmTime())
        _selectedDays = State(initialValue: Self.loadSelectedDays())
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Enable Alarm", isOn: $isAlarmEnabled)
                        .onChange(of: isAlarmEnabled) { _ in
                            saveAlarm()
                        }
                }
                
                Section(header: Text("Alarm Time")) {
                    DatePicker("Wake Up Time", selection: $alarmTime, displayedComponents: .hourAndMinute)
                        .onChange(of: alarmTime) { _ in
                            saveAlarm()
                        }
                        .disabled(!isAlarmEnabled)
                }
                
                Section(header: Text("Repeat")) {
                    ForEach(0..<7) { index in
                        Toggle(daysOfWeek[index], isOn: $selectedDays[index])
                            .onChange(of: selectedDays[index]) { _ in
                                saveAlarm()
                            }
                            .disabled(!isAlarmEnabled)
                    }
                }
                
                Section(header: Text("Wake Up Station")) {
                    if isAlarmEnabled {
                        Picker("Favorite Station", selection: $selectedStationIndex) {
                            ForEach(viewModel.stations.filter { $0.isFavorite }.indices, id: \.self) { index in
                                Text(viewModel.stations.filter { $0.isFavorite }[index].name).tag(index)
                            }
                        }
                        .onChange(of: selectedStationIndex) { _ in
                            saveAlarm()
                        }
                    } else {
                        Text("Enable alarm to select a station")
                            .foregroundColor(.gray)
                    }
                }
                
                if showSavedIndicator {
                    HStack {
                        Spacer()
                        Text("Changes saved")
                            .foregroundColor(.green)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Set Alarm")
            .opacity(isAlarmEnabled ? 1.0 : 0.5)
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
        
        let alarmDetails = AlarmDetails(
            time: alarmTime,
            days: selectedDays,
            isEnabled: isAlarmEnabled,
            stationIndex: selectedStationIndex
        )
        
        // Save alarm details to UserDefaults
        let favoriteStations = viewModel.stations.filter { $0.isFavorite }
        if selectedStationIndex < favoriteStations.count {
            let selectedStation = favoriteStations[selectedStationIndex]
            // Save the station's ID instead of its index
            UserDefaults.standard.set(selectedStation.id, forKey: "FavoriteStationID")
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
                    if granted {
                        completion(true)
                    } else {
                        self.presentCalendarAccessAlert()
                        completion(false)
                    }
                }
            }
        case .authorized:
            completion(true)
        case .restricted, .denied:
            presentCalendarAccessAlert()
            completion(false)
        @unknown default:
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
        scheduleLocalNotification(for: alarm)
        scheduleBackgroundTask(for: alarm)
        scheduleSilentPushNotification(for: alarm)
    }
    
    private func scheduleLocalNotification(for alarm: AlarmDetails) {
        let center = UNUserNotificationCenter.current()
        
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else { return }
            
            for (index, isSelected) in alarm.days.enumerated() where isSelected {
                var dateComponents = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
                dateComponents.weekday = index + 1 // weekday is 1-7
                
                let content = UNMutableNotificationContent()
                content.title = "Wake Up!"
                content.body = "Time to listen to your favorite station"
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
            message: "This app requires access to the calendar to schedule alarms. Please enable calendar access in Settings.",
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
        // You would also need to cancel any scheduled silent push notifications here
        // This would typically involve sending a request to your server
        print("Alarm cancelled")
    }
}

struct AlarmDetails: Codable {
    let time: Date
    let days: [Bool]
    let isEnabled: Bool
    let stationIndex: Int
}

struct AlarmConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        AlarmConfigurationView()
            .environmentObject(RadioStationViewModel())
    }
}
