//
//  PurchaseView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/1/24.
//

import SwiftUI

struct PurchaseView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var purchaseManager: PurchaseManager

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGray6)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 20) {
                    Text("Unlock Premium Features")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.top, 30)

                    Text("Unlock premium features for a one-time payment of $4.99 and elevate your listening experience. Enjoy premium benefits with no subscriptions or hidden fees!")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding([.horizontal, .bottom])

                    featureList
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                    
                    if purchaseManager.purchaseInProgress || purchaseManager.restorationInProgress {
                        ProgressView("Processing...")
                            .padding()
                    } else {
                        purchaseButton
                        restoreButton
                    }
                }
                .navigationBarItems(trailing: closeButton)
                .navigationBarTitle("Premium Features", displayMode: .inline)
                .padding()
                .onAppear {
                    purchaseManager.fetchProducts() 
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onReceive(purchaseManager.$transactionState) { state in
            if state == .purchased || state == .restored {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.isPresented = false
                    self.purchaseManager.resetTransactionState()
                }
            }
        }
    }
    
    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureItem(text: "Add Unlimited Stations: Break free from limits and add as many stations as you desire.")
            FeatureItem(text: "Real-Time Lyrics: Enjoy the ability to view lyrics for many songs identified via Shazam.")
        }
        .padding(.horizontal)
    }

    private var purchaseButton: some View {
        Button("Activate Now") {
            if let product = purchaseManager.product {
                print("Attempting to buy product: \(product.productIdentifier)")
                purchaseManager.buyProduct()
            } else {
                print("No products available")
            }
        }
        .buttonStyle(PremiumButtonStyle())
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            purchaseManager.restorePurchases()
        }
        .buttonStyle(PremiumButtonStyle())
    }

    private var closeButton: some View {
        Button(action: {
            isPresented = false
            purchaseManager.resetTransactionState()
        }) {
            Image(systemName: "xmark.circle.fill")
                .imageScale(.large)
                .foregroundColor(.primary)
        }
    }

    private func FeatureItem(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.accentColor)
                .font(.title2)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PremiumButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding()
            .background(Color.accentColor.opacity(0.8))
            .cornerRadius(10)
            .shadow(color: configuration.isPressed ? .black.opacity(0.3) : .clear, radius: configuration.isPressed ? 0 : 5, x: 0, y: configuration.isPressed ? 0 : 5)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

struct PurchaseView_Previews: PreviewProvider {
    @State static var isPresented = true

    static var previews: some View {
        PurchaseView(isPresented: $isPresented)
            .environmentObject(PurchaseManager.shared)
    }
}
