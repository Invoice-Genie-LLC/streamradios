import Foundation
import StoreKit
import SwiftUI

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    @Published var subscriptionStatus: SubscriptionStatus = .unknown
    @Published var products: [Product] = []
    @Published var purchasedSubscriptions: [Product] = []
    // @Published var subscriptionGroupStatus: RenewalState? // Not available in simulation mode
    @Published var isInitialized = false
    @Published var isLoading = false
    
    // Product IDs
    private let subscriptionProductId = "StreamRadiosPro"  // $9.99/year subscription
    private let oneTimeProductId = "STR12RA"              // $29.99 one-time purchase
    private var allProductIds: [String] {
        return [subscriptionProductId, oneTimeProductId]
    }
    
    private var updates: Task<Void, Never>?
    
    // MARK: - Simulation Mode (for testing without App Store Connect)
    private var isSimulationMode: Bool {
        // Real StoreKit mode enabled - connects to App Store Connect
        return false
    }
    
    // Simulation mode trial tracking
    private let simulatedTrialStartKey = "SimulatedTrialStartDate"
    private let hasEverPurchasedKey = "HasEverPurchasedSubscription"
    private let lastKnownSubscriptionKey = "LastKnownSubscriptionStatus"
    private let oneTimePurchaseKey = "HasOneTimePurchase"
    
    enum SubscriptionStatus: Equatable {
        case unknown
        case notSubscribed
        case freeTrial(daysRemaining: Int)
        case subscribed
        case oneTimePurchased  // New: User has made one-time purchase
        case expired
        case needsRestore // User likely has existing subscription but needs to restore
        
        var isSubscribed: Bool {
            switch self {
            case .subscribed, .freeTrial, .oneTimePurchased:
                return true
            default:
                return false
            }
        }
        
        var displayText: String {
            switch self {
            case .unknown:
                return "Loading..."
            case .notSubscribed:
                return "Not Subscribed"
            case .freeTrial(let daysRemaining):
                return "Free Trial (\(daysRemaining) days left)"
            case .subscribed:
                return "StreamRadios Pro"
            case .oneTimePurchased:
                return "StreamRadios Pro (Lifetime)"
            case .expired:
                return "Expired"
            case .needsRestore:
                return "StreamRadios Pro"
            }
        }
    }
    
    private init() {
        // Start listening for transaction updates
        updates = listenForTransactions()
    }
    
    deinit {
        updates?.cancel()
    }
    
    // MARK: - Initialization
    
    /// Validates that the subscription product has the correct 7-day trial configuration
    private func validateSubscriptionConfiguration() async {
        guard let subscriptionProduct = products.first(where: { $0.id == subscriptionProductId }) else {
            print("❌ Subscription product '\(subscriptionProductId)' not found")
            return
        }
        
        print("🔍 Validating subscription configuration for: \(subscriptionProduct.displayName)")
        
        guard let subscription = subscriptionProduct.subscription else {
            print("❌ Product is not a subscription type - check App Store Connect configuration")
            return
        }
        
        if let introductoryOffer = subscription.introductoryOffer {
            print("✅ Introductory offer found:")
            print("   - Type: \(introductoryOffer.type)")
            print("   - Period: \(introductoryOffer.period)")
            print("   - Period Count: \(introductoryOffer.periodCount)")
            print("   - Price: \(introductoryOffer.displayPrice)")
            
            // Check if it's configured as expected (7-day free trial)
            if introductoryOffer.paymentMode == .freeTrial && 
               introductoryOffer.period.unit == .day && 
               introductoryOffer.periodCount == 7 {
                print("✅ Perfect! 7-day free trial is correctly configured")
            } else {
                print("⚠️ Trial configuration doesn't match expected 7-day free trial:")
                print("   - Expected: 7-day free trial")
                print("   - Current: \(introductoryOffer.periodCount) \(introductoryOffer.period.unit) \(introductoryOffer.paymentMode)")
            }
        } else {
            print("❌ CRITICAL: NO INTRODUCTORY OFFER CONFIGURED!")
            print("🔧 To fix this issue in App Store Connect:")
            print("   1. Go to App Store Connect → My Apps → StreamRadios")
            print("   2. Navigate to Subscriptions → \(subscriptionProductId)")
            print("   3. Add Introductory Offer:")
            print("      - Type: Free Trial")
            print("      - Duration: 7 days")
            print("      - Price: $0.00")
            print("   4. Submit for review if needed")
            print("   ⚠️ Until fixed, recent subscriptions will be treated as trials automatically")
        }
    }
    
    func initialize() async {
        guard !isInitialized else { return }
        
        if isSimulationMode {
            // Simulation mode - for testing without real App Store Connect
            await MainActor.run {
                self.products = [] // Mock empty products
                self.subscriptionStatus = .notSubscribed
                self.isInitialized = true
                print("🧪 SubscriptionManager initialized in simulation mode")
            }
            return
        }
        
        do {
            // Load products from the App Store
            let products = try await Product.products(for: allProductIds)
            
            await MainActor.run {
                self.products = products
                print("📦 Loaded \(products.count) products")
            }
            
            // Validate subscription product configuration
            await validateSubscriptionConfiguration()
            
            // Check current subscription status
            await updateSubscriptionStatus()
            
            await MainActor.run {
                self.isInitialized = true
                print("✅ SubscriptionManager initialized")
            }
            
        } catch {
            print("❌ Failed to load products: \(error)")
            await MainActor.run {
                self.isInitialized = true
            }
        }
    }
    
    // MARK: - Subscription Status
    
    func updateSubscriptionStatus() async {
        if isSimulationMode {
            // Check for one-time purchase first
            let hasOneTimePurchase = UserDefaults.standard.bool(forKey: oneTimePurchaseKey)
            if hasOneTimePurchase {
                await MainActor.run {
                    self.subscriptionStatus = .oneTimePurchased
                    print("🧪 Simulation: One-time purchase detected")
                }
                return
            }
            
            // In simulation mode, check if trial has expired
            if let trialStartDate = UserDefaults.standard.object(forKey: simulatedTrialStartKey) as? Date {
                let daysRemaining = calculateSimulatedTrialDaysRemaining(from: trialStartDate)
                await MainActor.run {
                    if daysRemaining > 0 {
                        self.subscriptionStatus = .freeTrial(daysRemaining: daysRemaining)
                        print("🧪 Simulation: Trial active with \(daysRemaining) days remaining")
                    } else {
                        self.subscriptionStatus = .expired
                        print("🧪 Simulation: Trial has expired - user needs to subscribe")
                    }
                }
            } else {
                // Check if user has ever purchased and might need to restore
                let hasEverPurchased = UserDefaults.standard.bool(forKey: hasEverPurchasedKey)
                await MainActor.run {
                    if hasEverPurchased {
                        self.subscriptionStatus = .needsRestore
                        print("🧪 Simulation: User has previous subscription - showing restore option")
                    } else {
                        self.subscriptionStatus = .notSubscribed
                        print("🧪 Simulation: New user - showing subscription options")
                    }
                }
            }
            return
        }

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                
                // Check if this is our subscription product
                if transaction.productID == subscriptionProductId {
                    print("📋 Processing subscription transaction:")
                    print("   - Product ID: \(transaction.productID)")
                    print("   - Purchase Date: \(transaction.purchaseDate)")
                    print("   - Is Upgraded: \(transaction.isUpgraded)")
                    print("   - Revocation Date: \(transaction.revocationDate?.description ?? "none")")
                    
                    await MainActor.run {
                        if transaction.isUpgraded == false || transaction.revocationDate == nil {
                            // Check if it's a trial or regular subscription
                            if isFreeTrial(transaction: transaction) {
                                let daysRemaining = calculateTrialDaysRemaining(transaction: transaction)
                                self.subscriptionStatus = .freeTrial(daysRemaining: max(0, daysRemaining))
                                print("✅ Set status to free trial with \(daysRemaining) days remaining")
                            } else {
                                self.subscriptionStatus = .subscribed
                                print("✅ Set status to regular subscription")
                            }
                        } else {
                            self.subscriptionStatus = .expired
                            print("❌ Set status to expired")
                        }
                    }
                    return
                }
                
                // Check if this is our one-time purchase product
                if transaction.productID == oneTimeProductId {
                    await MainActor.run {
                        if transaction.revocationDate == nil {
                            self.subscriptionStatus = .oneTimePurchased
                        } else {
                            self.subscriptionStatus = .expired
                        }
                    }
                    return
                }
            } catch {
                print("❌ Failed to verify transaction: \(error)")
            }
        }
        
        // No valid subscription found
        await MainActor.run {
            self.subscriptionStatus = .notSubscribed
        }
    }
    
    private func isFreeTrial(transaction: StoreKit.Transaction) -> Bool {
        // Enhanced trial detection with fallback logic
        print("🔍 Checking trial status for transaction:")
        print("   - Product ID: \(transaction.productID)")
        print("   - Purchase Date: \(transaction.purchaseDate)")
        print("   - Offer Type: \(transaction.offerType?.rawValue.description ?? "none")")
        print("   - Environment: \(transaction.environment.rawValue)")
        
        // Primary check: App Store Connect configured trial
        if transaction.offerType == .introductory {
            print("✅ App Store Connect trial detected")
            return true
        }
        
        // FALLBACK: If App Store Connect doesn't have trial configured,
        // treat recent subscriptions (within 7 days) as trials
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let isRecentSubscription = transaction.purchaseDate > sevenDaysAgo
        
        if isRecentSubscription {
            print("⚠️ App Store Connect trial NOT configured, but treating recent subscription as trial")
            print("   - This subscription should have a 7-day trial period")
            print("   - Please configure introductory offer in App Store Connect")
            return true
        }
        
        print("❌ No trial detected - regular subscription")
        return false
    }
    
    private func calculateTrialDaysRemaining(transaction: StoreKit.Transaction) -> Int {
        let trialDuration: TimeInterval = 7 * 24 * 60 * 60 // 7 days in seconds
        let purchaseDate = transaction.purchaseDate
        let trialEndDate = purchaseDate.addingTimeInterval(trialDuration)
        let now = Date()
        
        if now < trialEndDate {
            let remainingTime = trialEndDate.timeIntervalSince(now)
            return Int(ceil(remainingTime / (24 * 60 * 60))) // Convert to days
        } else {
            return 0
        }
    }
    
    private func calculateSimulatedTrialDaysRemaining(from startDate: Date) -> Int {
        let trialDuration: TimeInterval = 7 * 24 * 60 * 60 // 7 days in seconds
        let trialEndDate = startDate.addingTimeInterval(trialDuration)
        let now = Date()
        
        if now < trialEndDate {
            let remainingTime = trialEndDate.timeIntervalSince(now)
            return Int(ceil(remainingTime / (24 * 60 * 60))) // Convert to days
        } else {
            return 0
        }
    }
    
    // MARK: - Purchase Functions
    
    /// Purchase the annual subscription (with 7-day free trial)
    func purchaseSubscription() async throws -> StoreKit.Transaction? {
        await MainActor.run {
            self.isLoading = true
        }
        
        defer {
            Task {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
        
        if isSimulationMode {
            // Simulate successful subscription purchase with 7-day free trial
            let trialStartDate = Date()
            UserDefaults.standard.set(trialStartDate, forKey: simulatedTrialStartKey)
            
            // Mark that user has ever purchased (for restore logic)
            UserDefaults.standard.set(true, forKey: hasEverPurchasedKey)
            UserDefaults.standard.set("freeTrial", forKey: lastKnownSubscriptionKey)
            
            await MainActor.run {
                let daysRemaining = self.calculateSimulatedTrialDaysRemaining(from: trialStartDate)
                self.subscriptionStatus = .freeTrial(daysRemaining: daysRemaining)
                print("🧪 Simulated subscription purchase: Starting 7-day free trial")
            }
            return nil // Return nil since we don't have a real transaction
        }
        
        guard let product = products.first(where: { $0.id == subscriptionProductId }) else {
            throw SubscriptionError.productNotFound
        }
        
        // Check if the product has introductory offers configured
        print("🛒 Purchasing subscription:")
        print("   - Product ID: \(product.id)")
        print("   - Display Name: \(product.displayName)")
        print("   - Price: \(product.displayPrice)")
        
        if let introductoryOffer = product.subscription?.introductoryOffer {
            print("✅ Introductory offer found:")
            print("   - Type: \(introductoryOffer.type)")
            print("   - Period: \(introductoryOffer.period)")
            print("   - Price: \(introductoryOffer.displayPrice)")
        } else {
            print("⚠️ NO INTRODUCTORY OFFER CONFIGURED!")
            print("   - This product should have a 7-day free trial")
            print("   - Please add introductory offer in App Store Connect:")
            print("   - Type: Free Trial, Duration: 7 days")
        }
        
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await updateSubscriptionStatus()
            await transaction.finish()
            return transaction
            
        case .userCancelled, .pending:
            return nil
            
        @unknown default:
            return nil
        }
    }
    
    /// Purchase the one-time lifetime access
    func purchaseOneTime() async throws -> StoreKit.Transaction? {
        await MainActor.run {
            self.isLoading = true
        }
        
        defer {
            Task {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
        
        if isSimulationMode {
            // Simulate successful one-time purchase
            UserDefaults.standard.set(true, forKey: oneTimePurchaseKey)
            UserDefaults.standard.set(true, forKey: hasEverPurchasedKey)
            UserDefaults.standard.set("oneTimePurchased", forKey: lastKnownSubscriptionKey)
            
            await MainActor.run {
                self.subscriptionStatus = .oneTimePurchased
                print("🧪 Simulated one-time purchase: Lifetime access granted")
            }
            return nil // Return nil since we don't have a real transaction
        }
        
        guard let product = products.first(where: { $0.id == oneTimeProductId }) else {
            throw SubscriptionError.productNotFound
        }
        
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await updateSubscriptionStatus()
            await transaction.finish()
            return transaction
            
        case .userCancelled, .pending:
            return nil
            
        @unknown default:
            return nil
        }
    }
    
    /// Legacy purchase method - now defaults to subscription
    func purchase() async throws -> StoreKit.Transaction? {
        return try await purchaseSubscription()
    }
    
    func restorePurchases() async throws {
        await MainActor.run {
            self.isLoading = true
        }
        
        defer {
            Task {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
        
        if isSimulationMode {
            // Simulate restore - check if user previously had subscription or one-time purchase
            let hasEverPurchased = UserDefaults.standard.bool(forKey: hasEverPurchasedKey)
            let hasOneTimePurchase = UserDefaults.standard.bool(forKey: oneTimePurchaseKey)
            
            await MainActor.run {
                if hasOneTimePurchase {
                    // User has one-time purchase - restore it
                    self.subscriptionStatus = .oneTimePurchased
                    print("🧪 Simulated restore: One-time purchase restored successfully")
                } else if hasEverPurchased {
                    // User has previous subscription - restore it
                    self.subscriptionStatus = .subscribed
                    // Mark subscription as restored by setting a subscription date
                    UserDefaults.standard.set(Date(), forKey: "RestoredSubscriptionDate")
                    UserDefaults.standard.set("subscribed", forKey: self.lastKnownSubscriptionKey)
                    print("🧪 Simulated restore: Previous subscription restored successfully")
                } else {
                    // No previous purchases exist
                    self.subscriptionStatus = .notSubscribed
                    print("🧪 Simulated restore: No previous purchases found")
                }
            }
            return
        }
        
        try await AppStore.sync()
        await updateSubscriptionStatus()
    }
    
    // MARK: - Helper Functions
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw SubscriptionError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
    
    private func listenForTransactions() -> Task<Void, Never> {
        return Task.detached {
            if await self.isSimulationMode {
                // In simulation mode, don't listen for real transactions
                print("🧪 Simulation mode: Skipping transaction listener")
                return
            }
            
            for await result in Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)
                    await self.updateSubscriptionStatus()
                    await transaction.finish()
                } catch {
                    print("❌ Transaction verification failed: \(error)")
                }
            }
        }
    }
    
    // MARK: - Testing/Debug Methods
    
    /// Simulate a fresh install for a user who previously had a subscription
    /// This is for testing the restore functionality
    func simulateFreshInstallWithPreviousSubscription() {
        guard isSimulationMode else { return }
        
        // Clear current subscription data
        UserDefaults.standard.removeObject(forKey: simulatedTrialStartKey)
        UserDefaults.standard.removeObject(forKey: "RestoredSubscriptionDate")
        
        // But keep the fact that they've purchased before
        UserDefaults.standard.set(true, forKey: hasEverPurchasedKey)
        UserDefaults.standard.set("subscribed", forKey: lastKnownSubscriptionKey)
        
        Task {
            await updateSubscriptionStatus()
        }
        
        print("🧪 Simulated fresh install for user with previous subscription")
    }
    
    /// Clear all subscription data for testing
    func clearAllSubscriptionData() {
        guard isSimulationMode else { return }
        
        UserDefaults.standard.removeObject(forKey: simulatedTrialStartKey)
        UserDefaults.standard.removeObject(forKey: hasEverPurchasedKey)
        UserDefaults.standard.removeObject(forKey: lastKnownSubscriptionKey)
        UserDefaults.standard.removeObject(forKey: "RestoredSubscriptionDate")
        UserDefaults.standard.removeObject(forKey: oneTimePurchaseKey)
        
        Task {
            await MainActor.run {
                self.subscriptionStatus = .notSubscribed
            }
        }
        
        print("🧪 Cleared all subscription data")
    }
    
    // MARK: - Computed Properties
    
    var isSubscribed: Bool {
        switch subscriptionStatus {
        case .subscribed, .freeTrial, .oneTimePurchased:
            return true
        default:
            return false
        }
    }
    
    var isSubscribedOrInTrial: Bool {
        return isSubscribed
    }
    
    var displayName: String {
        switch subscriptionStatus {
        case .unknown:
            return "Loading..."
        case .notSubscribed:
            return "Not Subscribed"
        case .freeTrial(let daysRemaining):
            return "Free Trial (\(daysRemaining) days left)"
        case .subscribed:
            return "StreamRadios Pro"
        case .oneTimePurchased:
            return "StreamRadios Pro (Lifetime)"
        case .expired:
            return "Expired"
        case .needsRestore:
            return "Needs Restore"
        }
    }
}

// MARK: - Errors

enum SubscriptionError: Error {
    case productNotFound
    case failedVerification
    case unknownError
}

// MARK: - Renewal State

// Note: RenewalInfo types not available in simulation mode
// This would be used for real App Store Connect integration 