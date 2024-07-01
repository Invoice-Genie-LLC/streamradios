//
//  PurchaseView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/1/24.
//

import SwiftUI

import SwiftUI

struct PurchaseView: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            List {
                Button("Activate Now") {
                    if let firstProduct = PurchaseManager.shared.products.first {
                        PurchaseManager.shared.buyProduct(firstProduct)
                    } else {
                        // Handle the case where there is no product loaded
                        print("No products available")
                    }
                }
                Button("Restore Purchases") {
                    PurchaseManager.shared.restorePurchases()
                }
                Button("Cancel") {
                    isPresented = false
                }
            }
            .navigationBarTitle("Unlock Premium Features", displayMode: .inline)
        }
    }
}
