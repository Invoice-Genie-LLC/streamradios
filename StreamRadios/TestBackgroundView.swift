import SwiftUI
import BackgroundTasks

struct TestBackgroundView: View {
    @EnvironmentObject var podcastViewModel: PodcastViewModel
    @State private var testResults: [String] = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Background Notification Testing")
                    .font(.title2)
                    .bold()
                
                VStack(spacing: 15) {
                    Button("Test Manual Episode Check") {
                        testResults.append("🧪 Manual episode check started at \(Date().formatted(.dateTime))")
                        podcastViewModel.manuallyCheckForNewEpisodes()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Test Background Notification") {
                        testResults.append("🧪 Background notification test at \(Date().formatted(.dateTime))")
                        podcastViewModel.testBackgroundNotification()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Schedule Background Task") {
                        testResults.append("📅 Background task scheduled at \(Date().formatted(.dateTime))")
                        BackgroundTaskManager.shared.schedulePodcastEpisodeCheck()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Send Test Notification") {
                        testResults.append("📱 Test notification sent at \(Date().formatted(.dateTime))")
                        NotificationManager.shared.notifyUser(
                            title: "Test Notification", 
                            message: "This is a test notification to verify the system is working."
                        )
                    }
                    .buttonStyle(.bordered)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Test Results:")
                        .font(.headline)
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(testResults.enumerated()), id: \.offset) { _, result in
                                Text(result)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(height: 200)
                    .background(Color(.systemGroupedBackground))
                    .cornerRadius(8)
                }
                
                Button("Clear Results") {
                    testResults.removeAll()
                }
                .foregroundColor(.red)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Debug Tools")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
} 