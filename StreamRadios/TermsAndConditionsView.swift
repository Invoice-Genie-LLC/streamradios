import SwiftUI

struct TermsAndConditionsView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    
    let showDragIndicator: Bool
    
    init(showDragIndicator: Bool = false) {
        self.showDragIndicator = showDragIndicator
    }
    
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
        VStack(spacing: 0) {
            // Drag indicator - only show when accessed from StationSubmissionView
            if showDragIndicator {
                VStack(spacing: 8) {
                    // Drag handle
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 40, height: 5)
                        .padding(.top, 8)
                    
                    // Title
                    Text("Terms and Conditions")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(primaryTextColor)
                        .padding(.bottom, 4)
                }
                
                // Header Divider
                Divider()
                    .background(Color.gray.opacity(0.3))
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Platform Access Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Platform Access and User Responsibilities")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("StreamRadios provides audio streaming services exclusively for individual, personal entertainment. The app is designed for personal use only and may not be used for commercial purposes or public broadcasting. Users must comply with all applicable laws while using the service - any attempts to circumvent security measures, reverse engineer the software, or interfere with the app's functionality may violate terms of service and applicable laws.\n\nAll user data, including favorites, downloads, and preferences, is stored securely in the user's personal iCloud account. StreamRadios does not collect, store, or have access to personal user information, ensuring complete privacy and data ownership remains with the individual user.\n\nMobile users are responsible for all carrier fees, data usage charges, and related telecommunications costs incurred while using StreamRadios. Streaming audio content may consume significant data, so users should monitor their data usage according to their mobile plan.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                    
                    // Third-Party Content Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Third-Party Audio Content")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("Content Sources and Types")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("StreamRadios aggregates audio content from various sources including:\n\n• Live radio stations, podcasts, and streaming audio programming\n• User-submitted media including images, text, audio files, artwork, and multimedia content\n• External website links and internet resources")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                        
                        Text("Copyright and Legal Protections")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("Audio content available through StreamRadios belongs to the original creators and broadcasters. This material is protected under copyright law and international treaties. Users cannot copy, redistribute, create derivatives, or publicly broadcast any content without explicit permission from the rights holders, except where fair use applies.\n\nContent providers may implement digital rights management (DRM) and other technological protection measures. These systems can limit or block content playback, and StreamRadios has no control over these restrictions. We cannot guarantee uninterrupted access to any particular audio stream or content.\n\nUsers who attempt to circumvent, disable, or tamper with content protection systems violate these terms and may face legal action and account deletion.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                        
                        Text("Content Availability and Quality")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("StreamRadios acts as a content aggregator and does not create or control the audio programming available on our platform. We make no guarantees about:\n\n• Continuous availability of specific stations or programs\n• Audio quality or streaming reliability\n• Content accuracy, appropriateness, or legal compliance\n• Broadcasting schedules or program changes\n\nContent providers may modify, remove, or restrict their programming without notice to StreamRadios or our users.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                    
                    // Software Rights Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Software Rights and Usage Restrictions")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("The StreamRadios application contains proprietary code and intellectual property owned by StreamRadios and our licensors. Users receive a personal, non-transferable license to use our software for accessing audio content only. This license does not permit:\n\n• Reverse engineering, decompiling, or extracting source code\n• Automated data collection, scraping, or systematic downloading\n• Creating competing services or derivative applications\n• Removing copyright notices or proprietary markings\n\nStreamRadios actively protects intellectual property rights and expects users to do the same. We will investigate reported copyright violations and remove infringing content when notified by rights holders. Repeat offenders will have their accounts permanently suspended.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                    
                    // Copyright Reporting Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Copyright Violation Reporting")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("Rights holders who believe their content is being used without authorization on StreamRadios should submit a formal takedown request to support@streamradios.app. Valid notices must include:\n\n• Clear identification of the copyrighted work\n• Location of the allegedly infringing content on our platform\n• Contact information for the rights holder or authorized representative\n• A statement of good faith belief that the use is unauthorized\n• Declaration that the information provided is accurate\n\nUpon receiving valid takedown notices, StreamRadios will promptly remove the disputed content and notify the user who posted it.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                    
                    // App Store Compliance Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Mobile App Store Compliance")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("Apple App Store Terms")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("StreamRadios available through Apple's App Store is governed by this agreement between you and StreamRadios only. Apple is not a party to these terms and has no responsibility for our application or its content.\n\nApple provides no technical support, maintenance, or warranties for StreamRadios. If you experience technical issues, contact StreamRadios directly. Apple's only obligation is to refund purchase prices for defective applications when notified.\n\nApple is not liable for any claims related to StreamRadios including:\n\n• Product defects or consumer protection violations\n• Failure to meet local regulatory requirements\n• Intellectual property disputes\n\nUsers must comply with Apple's App Store terms of service when using StreamRadios on iOS devices.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                        
                        Text("General Mobile Platform Requirements")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("Regardless of your mobile platform, users agree to:\n\n• Follow all applicable app store guidelines and policies\n• Respect platform-specific content restrictions\n• Maintain appropriate device security and software updates\n• Report technical issues through proper channels\n\nStreamRadios reserves the right to modify these terms as needed to maintain compliance with evolving mobile platform requirements.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 120) // Extra bottom padding for player
            }
        }
        .background(backgroundColor)
        .navigationTitle("Terms and Conditions")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") {
                    dismiss()
                }
                .foregroundColor(.blue)
            }
        }
    }
}

struct TermsAndConditionsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationView {
                TermsAndConditionsView(showDragIndicator: false)
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode - Navigation")
            
            NavigationView {
                TermsAndConditionsView(showDragIndicator: false)
            }
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode - Navigation")
            
            TermsAndConditionsView(showDragIndicator: true)
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark Mode - Sheet with Drag")
            
            TermsAndConditionsView(showDragIndicator: true)
                .preferredColorScheme(.light)
                .previewDisplayName("Light Mode - Sheet with Drag")
        }
    }
} 
