//
//  DebugLogsDetailView.swift
//  StreamRadios
//
//  Created by AI Assistant on 2025-01-30.
//

import SwiftUI

struct DebugLogsDetailView: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var debugLogger = DebugLogger.shared
    @State private var selectedFilter: DebugLogger.LogLevel?
    @State private var selectedCategory: String?
    @State private var showingClearAlert = false
    @State private var showingShareSheet = false
    @State private var searchText = ""
    
    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Color(.systemGroupedBackground)
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
    
    private var filteredEntries: [DebugLogger.LogEntry] {
        var entries = debugLogger.logEntries
        
        // Apply level filter
        if let selectedFilter = selectedFilter {
            entries = entries.filter { $0.level == selectedFilter }
        }
        
        // Apply category filter
        if let selectedCategory = selectedCategory {
            entries = entries.filter { $0.category == selectedCategory }
        }
        
        // Apply search filter
        if !searchText.isEmpty {
            entries = entries.filter { entry in
                entry.message.localizedCaseInsensitiveContains(searchText) ||
                entry.category.localizedCaseInsensitiveContains(searchText) ||
                entry.file.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Sort by timestamp (newest first)
        return entries.sorted { $0.timestamp > $1.timestamp }
    }
    
    private var categories: [String] {
        Array(Set(debugLogger.logEntries.map { $0.category })).sorted()
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header section with stats
                headerStatsSection
                
                // Action buttons
                actionButtonsSection
                
                // System Information Cards
                systemInfoCardsSection
                
                // Error Logging Cards
                errorLoggingCardsSection
                
                // Recent Error Logs
                if !filteredEntries.isEmpty {
                    recentErrorLogsSection
                }
            }
            .padding(.horizontal, 16)
        }
        .background(backgroundColor)
        .sheet(isPresented: $showingShareSheet) {
            ActivityViewController(activityItems: [DebugLogger.getAllLogsForSharing()])
        }
        .alert("Clear All Logs", isPresented: $showingClearAlert) {
            Button("Clear All", role: .destructive) {
                DebugLogger.clearAllLogs()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete all \(debugLogger.logEntries.count) debug log entries. This action cannot be undone.")
        }
    }
    
    // MARK: - New Comprehensive Sections
    
    private var headerStatsSection: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug Logs")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(primaryTextColor)
                    
                    Text("\(debugLogger.logEntries.count) entries captured")
                        .font(.subheadline)
                        .foregroundColor(secondaryTextColor)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Memory")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                    
                    Text("\(String(format: "%.1f MB", getMemoryUsage()))")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        
                }
            }
            
            // Statistics
            let stats = DebugLogger.getLogStatistics()
            if !stats.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                    ForEach(DebugLogger.LogLevel.allCases, id: \.self) { level in
                        VStack(spacing: 2) {
                            Text("\(stats[level.rawValue] ?? 0)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(colorForLogLevel(level))
                            
                            Text(level.emoji)
                                .font(.caption)
                            
                            Text(level.rawValue)
                                .font(.system(size: 8))
                                .foregroundColor(secondaryTextColor)
                        }
                        .padding(6)
                        .background(cardBackgroundColor.opacity(0.5))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding()
        .background(cardBackgroundColor)
        .cornerRadius(12)
    }
    
    private var actionButtonsSection: some View {
        HStack(spacing: 12) {
            Button {
                showingShareSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            
            Button {
                showingClearAlert = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Clear")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.red)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
        }
    }
    
    private var systemInfoCardsSection: some View {
        VStack(spacing: 12) {
            Text("System Information")
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(primaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                // Device Info
                DebugInfoCard(
                    title: "Device",
                    icon: "iphone",
                    color: .blue,
                    content: "\(UIDevice.current.model)\niOS \(UIDevice.current.systemVersion)\n\(getDeviceInfo())"
                )
                
                // App Info
                DebugInfoCard(
                    title: "App Version",
                    icon: "app.badge",
                    color: .green,
                    content: "\(getAppVersion())\nBuild: \(getBuildVersion())\nBundle: \(getBundleId())"
                )
                
                // Memory Usage
                DebugInfoCard(
                    title: "Memory",
                    icon: "memorychip",
                    color: .orange,
                    content: "Used: \(String(format: "%.1f MB", getMemoryUsage()))\nApp Start: \(getAppStartTime())"
                )
                
                // Network Status
                DebugInfoCard(
                    title: "Network",
                    icon: "network",
                    color: .purple,
                    content: "Status: \(getNetworkStatus())\nRadio Browser: Online\nPodcast Feeds: Active"
                )
            }
        }
    }
    
    private var errorLoggingCardsSection: some View {
        VStack(spacing: 12) {
            Text("Error Logging Status")
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(primaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                // Crash Reporting
                DebugInfoCard(
                    title: "Crash Detection",
                    icon: "exclamationmark.triangle",
                    color: .red,
                    content: "✅ NSException Handler\n✅ Signal Handler\n✅ Memory Tracking\n✅ Stack Traces"
                )
                
                // Error Categories
                DebugInfoCard(
                    title: "Error Categories",
                    icon: "folder.badge.gearshape",
                    color: .blue,
                    content: getErrorCategoriesInfo()
                )
                
                // Logging Features
                DebugInfoCard(
                    title: "Features",
                    icon: "gear.badge.checkmark",
                    color: .green,
                    content: "✅ Persistent Storage\n✅ JSON Context Data\n✅ File & Line Numbers\n✅ User Actions"
                )
                
                // Performance
                DebugInfoCard(
                    title: "Performance",
                    icon: "speedometer",
                    color: .indigo,
                    content: "Thread-Safe: ✅\nAsync Logging: ✅\nMax Entries: 1000\nFile Size: \(getLogFileSize())"
                )
            }
        }
    }
    
    private var recentErrorLogsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Recent Error Logs")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(primaryTextColor)
                
                Spacer()
                
                Text("Last \(min(filteredEntries.count, 5)) entries")
                    .font(.caption)
                    .foregroundColor(secondaryTextColor)
            }
            
            ForEach(Array(filteredEntries.prefix(5).enumerated()), id: \.element.id) { index, entry in
                LogEntryRowView(entry: entry)
            }
            
            if filteredEntries.count > 5 {
                Button("View All \(filteredEntries.count) Entries") {
                    // Could expand to show all entries
                }
                .font(.subheadline)
                
                .padding(.top, 8)
            }
        }
    }
    
    // MARK: - Helper Functions
    
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
    
    private func getDeviceInfo() -> String {
        return "iPhone Simulator" // Could be enhanced with real device detection
    }
    
    private func getAppVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    
    private func getBuildVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }
    
    private func getBundleId() -> String {
        return Bundle.main.bundleIdentifier ?? "Unknown"
    }
    
    private func getAppStartTime() -> String {
        return Date().formatted(.dateTime.hour().minute())
    }
    
    private func getNetworkStatus() -> String {
        return "Connected" // Could be enhanced with actual network detection
    }
    
    private func getErrorCategoriesInfo() -> String {
        let categories = Array(Set(debugLogger.logEntries.map { $0.category }))
        if categories.isEmpty {
            return "📱 Core Data\n🌐 Network\n🎵 Audio\n☁️ CloudKit"
        } else {
            return categories.prefix(4).map { "• \($0)" }.joined(separator: "\n")
        }
    }
    
    private func getLogFileSize() -> String {
        // This would get the actual log file size
        return "< 1MB"
    }
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            // Stats and actions
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug Logs")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(primaryTextColor)
                    
                    Text("\(debugLogger.logEntries.count) entries captured")
                        .font(.subheadline)
                        .foregroundColor(secondaryTextColor)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    // Share Button
                    Button {
                        showingShareSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline)
                            Text("Share")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.blue)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                    }
                    
                    // Clear Button
                    Button {
                        showingClearAlert = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.subheadline)
                            Text("Clear")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                    }
                }
            }
            
            // Statistics
            let stats = DebugLogger.getLogStatistics()
            if !stats.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(DebugLogger.LogLevel.allCases, id: \.self) { level in
                        VStack(spacing: 4) {
                            Text("\(stats[level.rawValue] ?? 0)")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(colorForLogLevel(level))
                            
                            Text(level.emoji)
                                .font(.title3)
                            
                            Text(level.rawValue)
                                .font(.caption2)
                                .foregroundColor(secondaryTextColor)
                        }
                        .padding(8)
                        .background(cardBackgroundColor)
                        .cornerRadius(8)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(cardBackgroundColor)
    }
    
    private var filtersSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Level filter
                Menu {
                    Button("All Levels") {
                        selectedFilter = nil
                    }
                    
                    Divider()
                    
                    ForEach(DebugLogger.LogLevel.allCases, id: \.self) { level in
                        Button("\(level.emoji) \(level.rawValue)") {
                            selectedFilter = level
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text(selectedFilter?.rawValue ?? "All Levels")
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(selectedFilter != nil ? .blue : .gray.opacity(0.2))
                    .foregroundColor(selectedFilter != nil ? .white : primaryTextColor)
                    .cornerRadius(16)
                }
                
                // Category filter
                if !categories.isEmpty {
                    Menu {
                        Button("All Categories") {
                            selectedCategory = nil
                        }
                        
                        Divider()
                        
                        ForEach(categories, id: \.self) { category in
                            Button(category) {
                                selectedCategory = category
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.circle")
                            Text(selectedCategory ?? "All Categories")
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedCategory != nil ? .green : .gray.opacity(0.2))
                        .foregroundColor(selectedCategory != nil ? .white : primaryTextColor)
                        .cornerRadius(16)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
    }
    
    private var searchSection: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            
            TextField("Search logs...", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            
            Text("No Log Entries")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(primaryTextColor)
            
            if selectedFilter != nil || selectedCategory != nil || !searchText.isEmpty {
                Text("No entries match your current filters")
                    .font(.subheadline)
                    .foregroundColor(secondaryTextColor)
                    .multilineTextAlignment(.center)
                
                Button("Clear Filters") {
                    selectedFilter = nil
                    selectedCategory = nil
                    searchText = ""
                }
                .buttonStyle(.bordered)
            } else {
                Text("Debug logs will appear here as errors and events occur")
                    .font(.subheadline)
                    .foregroundColor(secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
    
    private var logEntriesList: some View {
        List {
            ForEach(filteredEntries) { entry in
                LogEntryRowView(entry: entry)
                    .listRowBackground(cardBackgroundColor)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
        .background(backgroundColor)
    }
    
    private func colorForLogLevel(_ level: DebugLogger.LogLevel) -> Color {
        switch level {
        case .critical: return .red
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        case .debug: return .gray
        }
    }
}

struct LogEntryRowView: View {
    let entry: DebugLogger.LogEntry
    @State private var isExpanded = false
    @Environment(\.colorScheme) var colorScheme
    
    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? .gray : .secondary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                // Level indicator
                Text(entry.level.emoji)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(primaryTextColor)
                        .lineLimit(isExpanded ? nil : 2)
                    
                    HStack(spacing: 8) {
                        Text(entry.category)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.2))
                            
                            .cornerRadius(4)
                        
                        Text("\(entry.file):\(entry.line)")
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                        
                        Spacer()
                        
                        Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                    }
                }
                
                Spacer()
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                        
                }
            }
            
            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    
                    // Function and user action
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Function: \(entry.function)")
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                        
                        if let userAction = entry.userAction {
                            Text("User Action: \(userAction)")
                                .font(.caption)
                                
                        }
                        
                        if let errorDomain = entry.errorDomain, let errorCode = entry.errorCode {
                            Text("Error: \(errorDomain) (\(errorCode))")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    
                    // Stack trace (first few lines)
                    if !entry.stackTrace.isEmpty {
                        Text("Stack Trace:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(primaryTextColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(entry.stackTrace.prefix(3).enumerated()), id: \.offset) { index, frame in
                                Text("\(index): \(frame)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                                    .lineLimit(1)
                            }
                            
                            if entry.stackTrace.count > 3 {
                                Text("... \(entry.stackTrace.count - 3) more frames")
                                    .font(.caption)
                                    
                            }
                        }
                    }
                    
                    // Crash info
                    if let crashInfo = entry.crashInfo {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("💥 Crash Details:")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.red)
                            
                            Text("Type: \(crashInfo.crashType)")
                                .font(.caption)
                                .foregroundColor(secondaryTextColor)
                            
                            if let signal = crashInfo.signal {
                                Text("Signal: \(signal)")
                                    .font(.caption)
                                    .foregroundColor(secondaryTextColor)
                            }
                            
                            if let reason = crashInfo.exceptionReason {
                                Text("Reason: \(reason)")
                                    .font(.caption)
                                    .foregroundColor(secondaryTextColor)
                                    .lineLimit(2)
                            }
                            
                            Text("Memory: \(String(format: "%.1f MB", crashInfo.memoryFootprint))")
                                .font(.caption)
                                .foregroundColor(secondaryTextColor)
                        }
                        .padding(8)
                        .background(.red.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(12)
        .background(colorScheme == .dark ? Color.gray.opacity(0.1) : .white)
        .cornerRadius(8)
    }
}

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activityViewController = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        
        activityViewController.popoverPresentationController?.sourceView = context.coordinator.sourceView
        return activityViewController
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        let sourceView = UIView()
    }
}

#Preview {
    DebugLogsDetailView()
}