import SwiftUI
import StoreKit

struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showTerms = false
    @State private var showPrivacy = false
    
    // Parameter to track if view was opened from Settings (to show "You're all set!" screen)
    let showManagementScreen: Bool
    
    init(showManagementScreen: Bool = false) {
        self.showManagementScreen = showManagementScreen
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // Improved gradient background that works in both light and dark themes
                LinearGradient(
                    gradient: Gradient(colors: gradientColors),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 32) {
                        headerSection
                        
                        switch subscriptionManager.subscriptionStatus {
                        case .subscribed, .oneTimePurchased:
                            // Only show "You're all set!" screen if opened from Settings
                            if showManagementScreen {
                                subscribedSection
                            } else {
                                // Auto-dismiss if user is subscribed but view wasn't opened from Settings
                                EmptyView()
                            }
                        case .freeTrial(let daysRemaining):
                            if showManagementScreen {
                                trialSection(daysRemaining: daysRemaining)
                            } else {
                                // Auto-dismiss if user is in trial but view wasn't opened from Settings
                                EmptyView()
                            }
                        case .needsRestore:
                            restoreNeededSection
                        default:
                            featuresSection
                            pricingSection
                        }
                        
                        footerSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Only show close button if user is already subscribed
                if subscriptionManager.isSubscribedOrInTrial {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") {
                            dismiss()
                        }
                        .foregroundColor(colorScheme == .dark ? .white : Color(red: 0.2, green: 0.2, blue: 0.2))
                        .fontWeight(.semibold)
                    }
                }
            }
        }
        .alert("Subscription", isPresented: $showingAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
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
        .onAppear {
            // Check subscription status when view appears to update trial expiration
            Task {
                await subscriptionManager.updateSubscriptionStatus()
                
                // Auto-dismiss if user is subscribed/in trial but view wasn't opened from Settings
                if !showManagementScreen && subscriptionManager.isSubscribedOrInTrial {
                    print("✅ User is subscribed/in trial - auto-dismissing subscription view")
                    dismiss()
                }
            }
        }
        .onChange(of: subscriptionManager.subscriptionStatus) { oldStatus, newStatus in
            // Auto-dismiss if subscription status changes to subscribed/trial and not opened from Settings
            if !showManagementScreen && subscriptionManager.isSubscribedOrInTrial {
                print("✅ Subscription status changed to \(newStatus) - auto-dismissing subscription view")
                dismiss()
            }
        }
    }
    
    // MARK: - Color Scheme Helpers
    private var gradientColors: [Color] {
        if colorScheme == .dark {
            // Original dark theme - sophisticated and elegant
            return [
                Color.blue.opacity(0.9),
                Color.purple.opacity(0.8),
                Color.indigo.opacity(0.7),
                Color.black.opacity(0.3)
            ]
        } else {
            // Light theme replica - elegant pastels that mirror dark theme sophistication
            return [
                Color(red: 0.9, green: 0.95, blue: 1.0),      // Very light blue
                Color(red: 0.95, green: 0.9, blue: 1.0),      // Very light purple
                Color(red: 0.92, green: 0.92, blue: 0.98),    // Light lavender
                Color(red: 0.98, green: 0.98, blue: 0.98)     // Almost white
            ]
        }
    }
    
    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Color(red: 0.2, green: 0.2, blue: 0.2)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.9) : Color(red: 0.3, green: 0.3, blue: 0.3)
    }
    
    private var tertiaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.8) : Color(red: 0.5, green: 0.5, blue: 0.5)
    }
    
    private var cardBackgroundMaterial: Material {
        colorScheme == .dark ? .ultraThinMaterial : .ultraThinMaterial
    }
    
    private var cardShadow: Color {
        colorScheme == .dark ? .black.opacity(0.3) : .clear
    }
    
    private var cardShadowRadius: CGFloat {
        colorScheme == .dark ? 4 : 0
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "crown.fill")
                .font(.system(size: 60))
                .foregroundColor(.yellow)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.4) : .clear, 
                       radius: colorScheme == .dark ? 6 : 0)
            
            VStack(spacing: 8) {
                Text("StreamRadios Pro")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(primaryTextColor)
                    .shadow(color: colorScheme == .dark ? .clear : .clear, 
                           radius: 0)
                
                Text("Unlock the full potential of StreamRadios")
                    .font(.title3)
                    .foregroundColor(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .shadow(color: colorScheme == .dark ? .clear : .clear, 
                           radius: 0)
            }
        }
    }
    
    // MARK: - Subscribed Section
    private var subscribedSection: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
                .shadow(color: cardShadow, radius: cardShadowRadius)
            
            VStack(spacing: 12) {
                Text("You're all set!")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(primaryTextColor)
                
                Text(subscriptionManager.subscriptionStatus.displayText)
                    .font(.headline)
                    .foregroundColor(secondaryTextColor)
                
                Text("Thank you for supporting StreamRadios")
                    .font(.subheadline)
                    .foregroundColor(tertiaryTextColor)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 12) {
                // Show conversion option only for yearly subscribers
                if subscriptionManager.isYearlySubscriber {
                    Button("Upgrade to Lifetime Access") {
                        convertToLifetime()
                    }
                    .buttonStyle(PrimaryButtonStyle(colorScheme: colorScheme))
                    
                    Text("Upgrade to lifetime access for $29.99")
                        .font(.caption)
                        .foregroundColor(tertiaryTextColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                
                Button("Manage Subscription") {
                    openManageSubscription()
                }
                .buttonStyle(SecondaryButtonStyle(colorScheme: colorScheme))
                
                Button("Restore Purchases") {
                    restorePurchases()
                }
                .buttonStyle(TertiaryButtonStyle(colorScheme: colorScheme))
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(cardBackgroundMaterial)
                .shadow(color: cardShadow, radius: cardShadowRadius, x: 0, y: 4)
        )
    }
    
    // MARK: - Trial Section
    private func trialSection(daysRemaining: Int) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "clock.fill")
                .font(.system(size: 80))
                .foregroundColor(.yellow)
                .shadow(color: cardShadow, radius: cardShadowRadius)
            
            VStack(spacing: 12) {
                Text("Free Trial Active")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(primaryTextColor)
                
                Text("\(daysRemaining) days remaining")
                    .font(.headline)
                    .foregroundColor(.yellow)
                
                Text("Your trial will automatically convert to a paid subscription unless you cancel.")
                    .font(.subheadline)
                    .foregroundColor(tertiaryTextColor)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 12) {
                Button("Upgrade to Full Subscription") {
                    // This would upgrade trial to paid subscription immediately
                    upgradeToFullSubscription()
                }
                .buttonStyle(PrimaryButtonStyle(colorScheme: colorScheme))
                
                Button("Manage Subscription") {
                    openManageSubscription()
                }
                .buttonStyle(SecondaryButtonStyle(colorScheme: colorScheme))
                
                Button("Restore Purchases") {
                    restorePurchases()
                }
                .buttonStyle(TertiaryButtonStyle(colorScheme: colorScheme))
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(cardBackgroundMaterial)
                .shadow(color: cardShadow, radius: cardShadowRadius, x: 0, y: 4)
        )
    }
    
    // MARK: - Restore Needed Section
    private var restoreNeededSection: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.blue)
                .shadow(color: cardShadow, radius: cardShadowRadius)
            
            VStack(spacing: 12) {
                Text("You're all set!")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(primaryTextColor)
                
                Text("StreamRadios Pro")
                    .font(.headline)
                    .foregroundColor(secondaryTextColor)
                
                Text("You already have an active subscription. Click on \"Restore Purchases\" to reactivate subscription.")
                    .font(.subheadline)
                    .foregroundColor(tertiaryTextColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            
            VStack(spacing: 12) {
                Button("Restore Purchases") {
                    restorePurchases()
                }
                .buttonStyle(PrimaryButtonStyle(colorScheme: colorScheme))
                
                Button("Start New Trial") {
                    purchaseSubscription()
                }
                .buttonStyle(SecondaryButtonStyle(colorScheme: colorScheme))
                
                Button("Manage Subscription") {
                    openManageSubscription()
                }
                .buttonStyle(TertiaryButtonStyle(colorScheme: colorScheme))
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(cardBackgroundMaterial)
                .shadow(color: cardShadow, radius: cardShadowRadius, x: 0, y: 4)
        )
    }
    
    // MARK: - Features Section
    private var featuresSection: some View {
        VStack(spacing: 16) {
            Text("Premium Features")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(primaryTextColor)
            
            VStack(spacing: 12) {
                FeatureRow(
                    icon: "globe",
                    title: "Experience global radio stations around the world",
                    colorScheme: colorScheme
                )
                
                FeatureRow(
                    icon: "plus.circle",
                    title: "Add your own radio station stream",
                    colorScheme: colorScheme
                )
                
                FeatureRow(
                    icon: "shazam.logo",
                    title: "Shazam any song playing on the radio",
                    colorScheme: colorScheme
                )
                
                FeatureRow(
                    icon: "car",
                    title: "CarPlay support",
                    colorScheme: colorScheme
                )
                
                FeatureRow(
                    icon: "bell",
                    title: "Set reminders for your favorite radio show",
                    colorScheme: colorScheme
                )
                
                FeatureRow(
                    icon: "square.and.arrow.up",
                    title: "Import/Export radio station playlists",
                    colorScheme: colorScheme
                )
                
                FeatureRow(
                    icon: "heart.fill",
                    title: "Unlimited favorites for both radio stations and podcasts",
                    colorScheme: colorScheme
                )
                
                
                FeatureRow(
                    icon: "arrow.down.circle",
                    title: "Podcast episode download to listen offline",
                    colorScheme: colorScheme
                )
                
                FeatureRow(
                    icon: "mic",
                    title: "Millions of podcasts at your fingertips",
                    colorScheme: colorScheme
                )
                
            }
        }
    }
    
    // MARK: - Pricing Section
    private var pricingSection: some View {
        VStack(spacing: 16) {
            Text("Choose Your Plan")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(primaryTextColor)
            
            VStack(spacing: 12) {
                // Subscription Option
                subscriptionPricingCard
                
                // One-Time Purchase Option
                oneTimePricingCard
            }
            
            // Restore Purchases Button
            Button("Restore Purchases") {
                restorePurchases()
            }
            .buttonStyle(TertiaryButtonStyle(colorScheme: colorScheme))
            .padding(.top, 8)
        }
    }
    
    private var subscriptionPricingCard: some View {
        Button(action: {
            purchaseSubscription()
        }) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Annual Subscription")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("7-Day Free Trial")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$9.99/year")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.yellow)
                        
                        Text("Cancel anytime")
                            .font(.caption)
                            .foregroundColor(tertiaryTextColor)
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(cardBackgroundMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.yellow.opacity(colorScheme == .dark ? 0.5 : 0.7), lineWidth: 2)
                    )
                    .shadow(color: cardShadow, radius: cardShadowRadius, x: 0, y: 4)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var oneTimePricingCard: some View {
        Button(action: {
            purchaseOneTime()
        }) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lifetime Access")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(primaryTextColor)
                        
                        Text("One-time purchase")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$29.99")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                        
                        Text("Pay once, use forever")
                            .font(.caption)
                            .foregroundColor(tertiaryTextColor)
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(cardBackgroundMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.blue.opacity(colorScheme == .dark ? 0.5 : 0.7), lineWidth: 1)
                    )
                    .shadow(color: cardShadow, radius: cardShadowRadius, x: 0, y: 4)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    

    
    // MARK: - Footer Section
    private var footerSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Button("Terms of Service") {
                    showTerms = true
                }
                .buttonStyle(TertiaryButtonStyle(colorScheme: colorScheme))
                
                Button("Privacy Policy") {
                    showPrivacy = true
                }
                .buttonStyle(TertiaryButtonStyle(colorScheme: colorScheme))
            }
            
            Text("Subscription automatically renews unless canceled at least 24 hours before the end of the current period.")
                .font(.caption)
                .foregroundColor(tertiaryTextColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
    
    // MARK: - Actions
    private func purchaseSubscription() {
        Task {
            do {
                try await subscriptionManager.purchaseSubscription()
                if subscriptionManager.subscriptionStatus.isSubscribed {
                    alertMessage = "Subscription activated! Welcome to StreamRadios Pro!"
                    showingAlert = true
                    // Auto-dismiss after successful purchase
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
            } catch {
                alertMessage = "Purchase failed: \(error.localizedDescription)"
                showingAlert = true
            }
        }
    }
    
    private func purchaseOneTime() {
        Task {
            do {
                try await subscriptionManager.purchaseOneTime()
                if subscriptionManager.subscriptionStatus.isSubscribed {
                    alertMessage = "One-time purchase successful! Welcome to StreamRadios Pro!"
                    showingAlert = true
                    // Auto-dismiss after successful purchase
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
            } catch {
                alertMessage = "One-time purchase failed: \(error.localizedDescription)"
                showingAlert = true
            }
        }
    }
    
    private func upgradeToFullSubscription() {
        Task {
            do {
                try await subscriptionManager.upgradeTrialToFullSubscription()
                if subscriptionManager.subscriptionStatus.isSubscribed {
                    alertMessage = "Trial upgraded to full subscription! Welcome to StreamRadios Pro!"
                    showingAlert = true
                    // Auto-dismiss after successful upgrade
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
            } catch {
                alertMessage = "Upgrade failed: \(error.localizedDescription)"
                showingAlert = true
            }
        }
    }
    
    private func convertToLifetime() {
        Task {
            do {
                try await subscriptionManager.convertYearlyToLifetime()
                if subscriptionManager.subscriptionStatus == .oneTimePurchased {
                    alertMessage = "Successfully upgraded to lifetime access! Welcome to StreamRadios Pro Lifetime!"
                    showingAlert = true
                    // Auto-dismiss after successful conversion
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
            } catch {
                alertMessage = "Upgrade to lifetime failed: \(error.localizedDescription)"
                showingAlert = true
            }
        }
    }
    
    private func restorePurchases() {
        Task {
            do {
                try await subscriptionManager.restorePurchases()
                if subscriptionManager.subscriptionStatus.isSubscribed {
                    alertMessage = "Purchases restored successfully!"
                    showingAlert = true
                    // Auto-dismiss after successful restore
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                } else {
                    alertMessage = "No purchases found to restore."
                    showingAlert = true
                }
            } catch {
                alertMessage = "Failed to restore purchases: \(error.localizedDescription)"
                showingAlert = true
            }
        }
    }
    
    private func openManageSubscription() {
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Feature Row
struct FeatureRow: View {
    let icon: String
    let title: String
    let colorScheme: ColorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(colorScheme == .dark ? .yellow : .blue)
                .frame(width: 20)
            
            Text(title)
                .font(.subheadline)
                .foregroundColor(colorScheme == .dark ? .white : Color(red: 0.2, green: 0.2, blue: 0.2))
                .multilineTextAlignment(.leading)
            
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Feature Card
struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String
    let colorScheme: ColorScheme
    
    private var cardShadow: Color {
        colorScheme == .dark ? .black.opacity(0.3) : .clear
    }
    
    private var cardShadowRadius: CGFloat {
        colorScheme == .dark ? 2 : 0
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.yellow)
                .shadow(color: cardShadow, radius: cardShadowRadius)
            
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(colorScheme == .dark ? .white : Color(red: 0.2, green: 0.2, blue: 0.2))
                    .multilineTextAlignment(.center)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(colorScheme == .dark ? .white.opacity(0.8) : Color(red: 0.5, green: 0.5, blue: 0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(height: 140)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? .ultraThinMaterial : .ultraThinMaterial)
                .shadow(color: cardShadow, radius: cardShadowRadius, x: 0, y: 2)
        )
    }
}

// MARK: - Button Styles
struct PrimaryButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    
    private var buttonShadow: Color {
        colorScheme == .dark ? .black.opacity(0.3) : .clear
    }
    
    private var buttonShadowRadius: CGFloat {
        colorScheme == .dark ? 4 : 0
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: gradientColors),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: buttonShadow, radius: buttonShadowRadius, x: 0, y: 4)
            )
            .foregroundColor(textColor)
            .font(.headline)
            .fontWeight(.semibold)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
    
    private var gradientColors: [Color] {
        if colorScheme == .dark {
            return [.yellow.opacity(0.9), .orange.opacity(0.8)]
        } else {
            return [.yellow, .orange]
        }
    }
    
    private var textColor: Color {
        colorScheme == .dark ? .black : .black
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    
    private var buttonShadowRadius: CGFloat {
        colorScheme == .dark ? 4 : 0
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(backgroundMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(strokeColor, lineWidth: 1)
                    )
                    .shadow(color: buttonShadow, radius: buttonShadowRadius, x: 0, y: 2)
            )
            .foregroundColor(textColor)
            .font(.subheadline)
            .fontWeight(.medium)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
    
    private var backgroundMaterial: Material {
        colorScheme == .dark ? .ultraThinMaterial : .ultraThinMaterial
    }
    
    private var strokeColor: Color {
        colorScheme == .dark ? .white.opacity(0.3) : Color(red: 0.5, green: 0.5, blue: 0.5).opacity(0.3)
    }
    
    private var textColor: Color {
        colorScheme == .dark ? .white : Color(red: 0.2, green: 0.2, blue: 0.2)
    }
    
    private var buttonShadow: Color {
        colorScheme == .dark ? .black.opacity(0.3) : .clear
    }
}

struct TertiaryButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(textColor)
            .font(.subheadline)
            .underline()
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
    
    private var textColor: Color {
        colorScheme == .dark ? .white.opacity(0.8) : Color(red: 0.5, green: 0.5, blue: 0.5)
    }
}

#Preview("Subscription Flow") {
    SubscriptionView()
}

#Preview("Management Screen") {
    SubscriptionView(showManagementScreen: true)
}
