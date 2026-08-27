import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Our Commitment Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Our Commitment to Privacy")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("At StreamRadios, we respect your privacy and are committed to protecting it. This Privacy Policy explains our practices regarding the handling of your information and how we ensure your privacy is maintained.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                    
                    // Information We Do Not Collect Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Information We Do Not Collect")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("StreamRadios does not collect or store any personal information from our users. We do not track your activities, nor do we gather any personal data such as names, email addresses, or location data.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                    
                    // Data Storage Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Data Storage and Security")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("iCloud Account: All data related to your radio stations and favorites is stored locally on your device and backed up to your personal iCloud account. This data is governed by Apple's iCloud privacy and security measures and is not accessible by StreamRadios or any third parties.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                    
                    // Changes Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Changes to This Privacy Policy")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("We may update this Privacy Policy from time to time. Any changes will be posted on this page with an updated revision date.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                    
                    // Contact Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Contact Us")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("If you have any questions or concerns about our privacy practices, please contact us at:\n\nEmail: support@streamradios.app")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                    }
                    
                    // Closing Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Thank you for choosing StreamRadios. Enjoy your personalized radio experience with peace of mind.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(4)
                            .italic()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 120) // Extra bottom padding for player
            }
        }
        .background(backgroundColor)
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Back")
            }
        }
    }
}

struct PrivacyPolicyView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationView {
                PrivacyPolicyView()
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")
            
            NavigationView {
                PrivacyPolicyView()
            }
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode")
        }
    }
} 
