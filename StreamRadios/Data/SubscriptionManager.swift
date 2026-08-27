import Foundation
import StoreKit
import SwiftUI
import os.log

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    // MARK: - Persistent Debug Logging
    private static let logFileName = "subscription_debug.log"
    private static var logFileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(logFileName)
    }
    
    private static func writeToLog(_ message: String) {
        let timestamp = DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] \(message)\n"
        
        // Also print to console if debugger is connected
        print(logEntry.trimmingCharacters(in: .whitespacesAndNewlines))
        
        // Write to persistent log file
        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
    
    // Method to retrieve logs for viewing in app
    static func getDebugLogs() -> String {
        guard let data = try? Data(contentsOf: logFileURL),
              let logs = String(data: data, encoding: .utf8) else {
            return "No logs found"
        }
        return logs
    }
    
    // Method to clear logs
    static func clearDebugLogs() {
        try? FileManager.default.removeItem(at: logFileURL)
    }
    
    private func log(_ message: String) {
        SubscriptionManager.writeToLog(message)
    }
    
    // MARK: - Published Properties
    @Published var subscriptionStatus: SubscriptionStatus = .unknown {
        didSet {
            SubscriptionManager.entitlementSnapshot = (
                isEntitled: subscriptionStatus.isSubscribed,
                isResolved: subscriptionStatus != .unknown
            )
        }
    }
    
    /// Mirror of `subscriptionStatus` readable from any isolation context. The players and the
    /// CarPlay scene have to check entitlement from nonisolated callers.
    nonisolated(unsafe) static var entitlementSnapshot: (isEntitled: Bool, isResolved: Bool) = (false, false)

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
        log("🚀 SubscriptionManager: App starting up, initializing SubscriptionManager")
        if isSimulationMode {
            log("🧪 SubscriptionManager: Running in simulation mode")
        } else {
            log("🏪 SubscriptionManager: Running in App Store mode")
        }
        
        Task {
            await updateSubscriptionStatus()
        }
        
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
            print("ℹ️ No introductory offer detected by StoreKit")
            print("")
            print("🧪 SANDBOX TESTING:")
            print("   → This is NORMAL if your sandbox test user already consumed the trial")
            print("   → To test the trial again, create a NEW sandbox test user in App Store Connect")
            print("   → Each sandbox user can only use an introductory offer ONCE (by design)")
            print("")
            print("🔧 Troubleshooting:")
            print("   1. Delete app completely from device/simulator")
            print("   2. Create new sandbox test user: App Store Connect → Users & Access → Sandbox Testers")
            print("   3. Sign out of old sandbox account on device: Settings → App Store → Sandbox Account")
            print("   4. Reinstall app and sign in with new sandbox test user")
            print("")
            print("✅ App functionality is NOT affected - trial logic works correctly")
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
            log("🔍 DEBUG: Starting updateSubscriptionStatus in simulation mode")
            
            // Check for one-time purchase first
            let hasOneTimePurchase = UserDefaults.standard.bool(forKey: oneTimePurchaseKey)
            log("🔍 DEBUG: hasOneTimePurchase = \(hasOneTimePurchase)")
            if hasOneTimePurchase {
                await MainActor.run {
                    self.subscriptionStatus = .oneTimePurchased
                    log("🧪 Simulation: One-time purchase detected")
                }
                return
            }
            
            // Check if user has upgraded to full subscription (priority over trial)
            let lastKnownStatus = UserDefaults.standard.string(forKey: lastKnownSubscriptionKey)
            log("🔍 DEBUG: lastKnownStatus = \(lastKnownStatus ?? "nil")")
            if lastKnownStatus == "subscribed" {
                await MainActor.run {
                    self.subscriptionStatus = .subscribed
                    log("🔍 DEBUG: Found upgraded subscription status - setting to subscribed")
                }
                return
            }
            
            // Check trial logic only if no subscription found
            if let trialStartDate = UserDefaults.standard.object(forKey: simulatedTrialStartKey) as? Date {
                log("🔍 DEBUG: trialStartDate found = \(trialStartDate)")
                await MainActor.run {
                    let daysRemaining = self.calculateSimulatedTrialDaysRemaining(from: trialStartDate)
                    if daysRemaining > 0 {
                        self.subscriptionStatus = .freeTrial(daysRemaining: daysRemaining)
                        log("🧪 Simulation: Free trial active (\(daysRemaining) days remaining)")
                    } else {
                        self.subscriptionStatus = .expired
                        log("🧪 Simulation: Free trial expired")
                    }
                }
            } else {
                log("🔍 DEBUG: No trial start date found - setting to unknown")
                await MainActor.run {
                    self.subscriptionStatus = .unknown
                    log("🧪 Simulation: No subscription or trial data found")
                }
            }
            return
        }

        // App Store mode - CHECK USERDEFAULTS FIRST like simulation mode
        log("🔍 DEBUG: Starting updateSubscriptionStatus in App Store mode")
        
        // Check for one-time purchase first
        let hasOneTimePurchase = UserDefaults.standard.bool(forKey: oneTimePurchaseKey)
        log("🔍 DEBUG: App Store - hasOneTimePurchase = \(hasOneTimePurchase)")
        if hasOneTimePurchase {
            await MainActor.run {
                self.subscriptionStatus = .oneTimePurchased
                log("🏪 App Store: One-time purchase detected")
            }
            return
        }
        
        // Check if user has upgraded to full subscription (priority over StoreKit transactions)
        let lastKnownStatus = UserDefaults.standard.string(forKey: lastKnownSubscriptionKey)
        log("🔍 DEBUG: App Store - lastKnownStatus = \(lastKnownStatus ?? "nil")")
        if lastKnownStatus == "subscribed" {
            await MainActor.run {
                self.subscriptionStatus = .subscribed
                log("🔍 DEBUG: App Store - Found upgraded subscription status - setting to subscribed")
            }
            return
        }

        // Fall back to StoreKit transactions if no UserDefaults override found
        log("🔍 DEBUG: App Store - No UserDefaults override, checking StoreKit transactions")
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
            UserDefaults.standard.synchronize()
            
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
            print("✅ Introductory offer available:")
            print("   - Type: \(introductoryOffer.type)")
            print("   - Period: \(introductoryOffer.period)")
            print("   - Price: \(introductoryOffer.displayPrice)")
        } else {
            print("ℹ️ No introductory offer detected (user may have already used trial, or StoreKit cache issue)")
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
            UserDefaults.standard.synchronize()
            
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
    
    /// Convert yearly subscription to lifetime access
    /// This allows yearly subscribers to upgrade to one-time lifetime purchase
    func convertYearlyToLifetime() async throws -> StoreKit.Transaction? {
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
            // Simulate successful conversion to lifetime
            UserDefaults.standard.set(true, forKey: oneTimePurchaseKey)
            UserDefaults.standard.set(true, forKey: hasEverPurchasedKey)
            UserDefaults.standard.set("oneTimePurchased", forKey: lastKnownSubscriptionKey)
            // Clear subscription data
            UserDefaults.standard.removeObject(forKey: simulatedTrialStartKey)
            UserDefaults.standard.synchronize()
            
            await MainActor.run {
                self.subscriptionStatus = .oneTimePurchased
                log("🧪 Simulated yearly to lifetime conversion: Lifetime access granted")
            }
            return nil
        }
        
        guard let product = products.first(where: { $0.id == oneTimeProductId }) else {
            throw SubscriptionError.productNotFound
        }
        
        print("🛒 Converting yearly subscription to lifetime:")
        print("   - Product ID: \(product.id)")
        print("   - Display Name: \(product.displayName)")
        print("   - Price: \(product.displayPrice)")
        
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            
            // Update status to lifetime
            await MainActor.run {
                self.subscriptionStatus = .oneTimePurchased
                UserDefaults.standard.set(true, forKey: self.oneTimePurchaseKey)
                UserDefaults.standard.set("oneTimePurchased", forKey: self.lastKnownSubscriptionKey)
                UserDefaults.standard.synchronize()
                log("✅ Yearly subscription converted to lifetime access")
            }
            
            await transaction.finish()
            return transaction
            
        case .userCancelled, .pending:
            return nil
            
        @unknown default:
            return nil
        }
    }
    
    /// Upgrade from free trial to full paid subscription immediately
    /// This bypasses the trial period and activates yearly subscription right away
    func upgradeTrialToFullSubscription() async throws {
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
            // In simulation mode, immediately convert trial to full subscription
            await MainActor.run {
                log("🔍 DEBUG: Upgrading trial to full subscription")
                log("🔍 DEBUG: Before - lastKnownStatus = \(UserDefaults.standard.string(forKey: self.lastKnownSubscriptionKey) ?? "nil")")
                log("🔍 DEBUG: Before - trialStartDate = \(String(describing: UserDefaults.standard.object(forKey: self.simulatedTrialStartKey) as? Date))")
                
                self.subscriptionStatus = .subscribed
                UserDefaults.standard.set("subscribed", forKey: self.lastKnownSubscriptionKey)
                UserDefaults.standard.set(true, forKey: self.hasEverPurchasedKey)
                // Clear trial start date to prevent trial logic from overriding subscription
                UserDefaults.standard.removeObject(forKey: self.simulatedTrialStartKey)
                // Force immediate synchronization to disk to survive force close
                UserDefaults.standard.synchronize()
                
                log("🔍 DEBUG: After - lastKnownStatus = \(UserDefaults.standard.string(forKey: self.lastKnownSubscriptionKey) ?? "nil")")
                log("🔍 DEBUG: After - trialStartDate = \(String(describing: UserDefaults.standard.object(forKey: self.simulatedTrialStartKey) as? Date))")
                log("🔍 DEBUG: UserDefaults synchronized to disk")
                log("🧪 Simulated trial upgrade: Converted to full subscription immediately")
            }
            return
        }
        
        // For real App Store implementation, purchase the subscription product
        guard let product = products.first(where: { $0.id == subscriptionProductId }) else {
            throw SubscriptionError.productNotFound
        }
        
        print("🛒 Upgrading trial to full subscription:")
        print("   - Product ID: \(product.id)")
        print("   - Display Name: \(product.displayName)")
        print("   - Price: \(product.displayPrice)")
        
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            // Immediately set status to subscribed (not trial)
            await MainActor.run {
                log("🔍 DEBUG: App Store - Upgrading trial to full subscription")
                log("🔍 DEBUG: App Store - Before - lastKnownStatus = \(UserDefaults.standard.string(forKey: self.lastKnownSubscriptionKey) ?? "nil")")
                
                self.subscriptionStatus = .subscribed
                // Also persist to UserDefaults for force close scenarios
                UserDefaults.standard.set("subscribed", forKey: self.lastKnownSubscriptionKey)
                UserDefaults.standard.set(true, forKey: self.hasEverPurchasedKey)
                // Clear any trial data that might interfere
                UserDefaults.standard.removeObject(forKey: self.simulatedTrialStartKey)
                UserDefaults.standard.synchronize()
                
                log("🔍 DEBUG: App Store - After - lastKnownStatus = \(UserDefaults.standard.string(forKey: self.lastKnownSubscriptionKey) ?? "nil")")
                log("🔍 DEBUG: App Store - UserDefaults synchronized to disk")
                print("✅ Trial successfully upgraded to full subscription")
            }
            await transaction.finish()
            
        case .userCancelled, .pending:
            break
            
        @unknown default:
            break
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
                    UserDefaults.standard.synchronize()
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
    
    /// Check if user has yearly subscription (not lifetime)
    var isYearlySubscriber: Bool {
        switch subscriptionStatus {
        case .subscribed:
            return true
        default:
            return false
        }
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