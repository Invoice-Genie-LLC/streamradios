//
//  purchaseManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/1/24.
//

import StoreKit

class PurchaseManager: NSObject, SKProductsRequestDelegate, SKPaymentTransactionObserver {
    static let shared = PurchaseManager()
    var products: [SKProduct] = []
    
    func setupIAP() {
        SKPaymentQueue.default().add(self)
        let request = SKProductsRequest(productIdentifiers: Set(["com.streamradios.premiumfeatures"]))
        request.delegate = self
        request.start()
    }
    
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        products = response.products
        // Optionally post notification here to update the UI
    }
    
    func buyProduct(_ product: SKProduct?) {
        guard let product = product else {
            // Handle the error, e.g., show an alert or log the error
            print("Product not available")
            return
        }
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchased, .restored:
                // Unlock features here
                UserDefaults.standard.set(true, forKey: "isPremiumUser")
                SKPaymentQueue.default().finishTransaction(transaction)
            case .failed:
                SKPaymentQueue.default().finishTransaction(transaction)
            default:
                break
            }
        }
    }
    
    func restorePurchases() {
        SKPaymentQueue.default().restoreCompletedTransactions()
    }
}

extension PurchaseManager {
    func hasPurchasedPremium() -> Bool {
        return UserDefaults.standard.bool(forKey: "isPremiumUser")
    }
}
