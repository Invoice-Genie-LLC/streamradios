import SwiftUI

struct AboutView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var showTerms = false
    @State private var showPrivacy = false
    
    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Color(.systemGray6)
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    private var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return "\(version) (\(build))"
        } else if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "Unknown"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Content
            VStack(spacing: 0) {
                // Terms and Conditions Row
                Button(action: {
                    showTerms = true
                }) {
                    HStack {
                        Text("Terms and Conditions")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(cardBackgroundColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                
                // Separator
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 0.5)
                    .padding(.leading, 16)
                
                // Privacy Policy Row
                Button(action: {
                    showPrivacy = true
                }) {
                    HStack {
                        Text("Privacy policy")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(cardBackgroundColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                
                // Separator
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 0.5)
                    .padding(.leading, 16)
                
                // Version Row
                HStack {
                    Text("Version")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                    
                    Spacer()
                    
                    Text(appVersion)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(cardBackgroundColor)
            }
            .background(cardBackgroundColor)
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            
            Spacer()
        }
        .background(backgroundColor)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTerms) {
            NavigationView {
                TermsAndConditionsView()
            }
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationView {
                PrivacyPolicyView()
            }
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationView {
                AboutView()
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")
            
            NavigationView {
                AboutView()
            }
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode")
        }
    }
} 