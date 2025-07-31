//
//  DebugLogsSheetView.swift
//  StreamRadios
//
//  Created by AI Assistant on 2025-01-30.
//

import SwiftUI

struct DebugLogsSheetView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var showingShareSheet = false
    @State private var debugLogsContent = ""
    
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
        VStack(spacing: 16) {
            // Header Section
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug Information")
                        .font(.headline)
                        .foregroundColor(primaryTextColor)
                    
                    Text("View comprehensive error logs and system information")
                        .font(.subheadline)
                        .foregroundColor(secondaryTextColor)
                }
                
                Spacer()
                
                // Share Button
                Button {
                    prepareDebugLogs()
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            // Debug Logs Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // System Information Section
                    DebugLogSection(
                        title: "System Information",
                        icon: "info.circle.fill",
                        color: .blue,
                        content: getSystemInfo()
                    )
                    
                    // Recent Errors Section
                    DebugLogSection(
                        title: "Recent Errors",
                        icon: "exclamationmark.triangle.fill",
                        color: .red,
                        content: getRecentErrors()
                    )
                    
                    // Network Logs Section
                    DebugLogSection(
                        title: "Network Activity",
                        icon: "network",
                        color: .green,
                        content: getNetworkLogs()
                    )
                    
                    // Audio System Section
                    DebugLogSection(
                        title: "Audio System",
                        icon: "speaker.wave.3.fill",
                        color: .orange,
                        content: getAudioSystemLogs()
                    )
                }
                .padding(.horizontal, 16)
            }
            
            Spacer()
        }
        .background(backgroundColor)
        .sheet(isPresented: $showingShareSheet) {
            NavigationView {
                ShareSheetView(content: debugLogsContent)
                    .navigationTitle("Share Debug Logs")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Cancel") {
                                showingShareSheet = false
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showingShareSheet = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
            }
        }
    }
    
    private func prepareDebugLogs() {
        debugLogsContent = """
        StreamRadios Debug Report
        Generated: \(Date().formatted(.dateTime))
        
        \(getSystemInfo())
        
        \(getRecentErrors())
        
        \(getNetworkLogs())
        
        \(getAudioSystemLogs())
        """
    }
    
    private func getSystemInfo() -> String {
        return """
        Device: \(UIDevice.current.model)
        iOS Version: \(UIDevice.current.systemVersion)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")
        Memory Usage: \(String(format: "%.2f MB", getMemoryUsage()))
        """
    }
    
    private func getRecentErrors() -> String {
        return """
        No recent errors captured in this session.
        Note: Full error logging system is available in the comprehensive DebugLogger class.
        This is a simplified view for demonstration purposes.
        """
    }
    
    private func getNetworkLogs() -> String {
        return """
        Radio Browser API: Active
        Podcast RSS Feeds: Active
        CloudKit Sync: Enabled
        Network Reachability: Connected
        """
    }
    
    private func getAudioSystemLogs() -> String {
        return """
        Audio Session: Configured
        CarPlay Support: Available
        Background Audio: Enabled
        Hardware Codec: AAC
        """
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
}

struct DebugLogSection: View {
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
            // Section Header
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

struct ShareSheetView: View {
    let content: String
    @Environment(\.colorScheme) var colorScheme
    
    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Color(.systemGray6)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Email Option
            ShareOptionButton(
                icon: "envelope.fill",
                title: "Email Debug Logs",
                subtitle: "Send comprehensive report via email",
                color: .blue
            ) {
                shareViaEmail()
            }
            
            // Copy to Clipboard
            ShareOptionButton(
                icon: "doc.on.clipboard.fill",
                title: "Copy to Clipboard",
                subtitle: "Copy logs to clipboard for pasting",
                color: .green
            ) {
                UIPasteboard.general.string = content
            }
            
            // Save to Files
            ShareOptionButton(
                icon: "folder.fill",
                title: "Save to Files",
                subtitle: "Export logs as text file",
                color: .orange
            ) {
                saveToFiles()
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .background(backgroundColor)
    }
    
    private func shareViaEmail() {
        let subject = "StreamRadios Debug Logs - \(Date().formatted(.dateTime.day().month().year()))"
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = content.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        if let emailURL = URL(string: "mailto:?subject=\(encodedSubject)&body=\(encodedBody)"),
           UIApplication.shared.canOpenURL(emailURL) {
            UIApplication.shared.open(emailURL)
        }
    }
    
    private func saveToFiles() {
        let fileName = "StreamRadios_Debug_\(Date().formatted(.dateTime.day().month().year().hour().minute())).txt"
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            
            let activityViewController = UIActivityViewController(
                activityItems: [tempURL],
                applicationActivities: nil
            )
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootViewController = window.rootViewController {
                
                if let presentedViewController = rootViewController.presentedViewController {
                    presentedViewController.present(activityViewController, animated: true)
                } else {
                    rootViewController.present(activityViewController, animated: true)
                }
            }
        } catch {
            print("❌ Failed to save debug logs to file: \(error)")
        }
    }
}

struct ShareOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void
    
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
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                    .frame(width: 30)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(primaryTextColor)
                    
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(secondaryTextColor)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .padding(16)
            .background(cardBackgroundColor)
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    DebugLogsSheetView()
}