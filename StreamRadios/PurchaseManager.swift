//
//  purchaseManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/1/24.
//

import Foundation
import StoreKit

class PurchaseManager: NSObject, ObservableObject, SKProductsRequestDelegate, SKPaymentTransactionObserver {
    static let shared = PurchaseManager()

    @Published var purchaseInProgress = false
    @Published var product: SKProduct?
    @Published var transactionState: SKPaymentTransactionState?
    @Published var restorationInProgress = false
    @Published var restorationError: String?

    private let productIdentifier = "d1e5bb7d"
    private let premiumFeaturesKey = "hasPremiumFeatures"

    override init() {
        super.init()
        SKPaymentQueue.default().add(self)
        fetchProducts()
    }

    deinit {
        SKPaymentQueue.default().remove(self)
    }

    func fetchProducts() {
        let request = SKProductsRequest(productIdentifiers: [productIdentifier])
        request.delegate = self
        request.start()
    }

    func resetTransactionState() {
        DispatchQueue.main.async {
            self.transactionState = nil
        }
    }

    func buyProduct() {
        guard let product = self.product else {
            print("Attempted to buy a product that is not available")
            return
        }
        purchaseInProgress = true
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
    }

    func restorePurchases() {
        restorationInProgress = true
        SKPaymentQueue.default().restoreCompletedTransactions()
    }

    var hasPurchasedPremium: Bool {
        return UserDefaults.standard.bool(forKey: premiumFeaturesKey)
    }

    // MARK: - SKProductsRequestDelegate
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        DispatchQueue.main.async {
            self.product = response.products.first
        }
    }

    // MARK: - SKPaymentTransactionObserver
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchased, .restored:
                UserDefaults.standard.set(true, forKey: premiumFeaturesKey)
                SKPaymentQueue.default().finishTransaction(transaction)
                DispatchQueue.main.async {
                    self.purchaseInProgress = false
                    self.restorationInProgress = false
                    self.transactionState = transaction.transactionState
                }
            case .failed:
                if let error = transaction.error as NSError? {
                    DispatchQueue.main.async {
                        self.restorationError = error.localizedDescription
                    }
                }
                SKPaymentQueue.default().finishTransaction(transaction)
                DispatchQueue.main.async {
                    self.purchaseInProgress = false
                    self.restorationInProgress = false
                    self.transactionState = .failed
                }
            default:
                break
            }
        }
    }

    func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        DispatchQueue.main.async {
            self.restorationInProgress = false
            self.transactionState = .restored
        }
    }

    func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        DispatchQueue.main.async {
            self.restorationInProgress = false
            self.restorationError = error.localizedDescription
            self.transactionState = .failed
        }
    }
}
