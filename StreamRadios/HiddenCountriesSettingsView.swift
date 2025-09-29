//
//  HiddenCountriesSettingsView.swift
//  StreamRadios
//
//  Created by AI Assistant on 1/2/25.
//

import SwiftUI
import FlagKit

// MARK: - Conditional Liquid Glass Modifier
struct ConditionalLiquidGlass: ViewModifier {
    let cornerRadius: CGFloat
    
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
        }
    }
}

struct HiddenCountriesSettingsView: View {
    // Scroll detection bindings for TabView hide functionality
    @Binding var isScrolling: Bool
    @Binding var isFooterMenuHidden: Bool
    
    @AppStorage("hiddenCountries") private var hiddenCountriesData: Data = Data()
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    @State private var hiddenCountries: Set<String> = []
    @State private var searchText = ""
    @State private var isSearchPresented = false
    
    // Default initializer for backward compatibility
    init() {
        self._isScrolling = .constant(false)
        self._isFooterMenuHidden = .constant(false)
    }
    
    // Main initializer with scroll detection bindings
    init(isScrolling: Binding<Bool>, isFooterMenuHidden: Binding<Bool>) {
        self._isScrolling = isScrolling
        self._isFooterMenuHidden = isFooterMenuHidden
    }
    
    private let allCountries = Country.getAllCountriesWithAPICodes().filter { $0.name != "Select Country" }
    
    private var filteredCountries: [Country] {
        let filtered = searchText.isEmpty ? allCountries :
            allCountries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return filtered.sorted { $0.name < $1.name }
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
            // Custom Search Bar (when presented)
            if isSearchPresented {
                CustomSearchBar(searchText: $searchText, isPresented: $isSearchPresented, placeholder: "Search countries...")
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .background(backgroundColor)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            // Countries list
            List {
                Section {
                    ForEach(filteredCountries, id: \.id) { country in
                        HiddenCountryRow(
                            country: country,
                            isHidden: hiddenCountries.contains(country.name),
                            onToggle: { isHidden in
                                toggleCountryVisibility(country.name, isHidden: isHidden)
                            }
                        )
                        .listRowBackground(cardBackgroundColor)
                }
                } header: {
                    HStack {
                        Text("Countries")
                            .font(.subheadline)
                            .foregroundColor(secondaryTextColor)
                        Spacer()
                        Text("\(hiddenCountries.count) hidden")
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                    }
                } footer: {
                    Text("Hidden countries will not appear in the country picker when adding stations or browsing by country.")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                }
            }
            .listStyle(InsetGroupedListStyle())
            .scrollContentBackground(.hidden)
            .background(backgroundColor)
            .safeAreaInset(edge: .bottom) {
                // Add space at bottom to prevent player obstruction
                Color.clear.frame(height: 100)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10) // Set minimum distance to 10 to avoid interfering with button taps
                    .onChanged { _ in
                        // IMMEDIATE update - no conditions, just set it
                        DispatchQueue.main.async {
                            if !isScrolling {
                                print("🏠 DEBUG: Setting isScrolling = true in HiddenCountriesSettingsView")
                                isScrolling = true
                                // FIRST-TIME PLAYBACK PROTECTION: Only set scroll state, let ContentView handle TabView hiding
                                // REMOVED: Direct isFooterMenuHidden assignment - let ContentView shouldHideFooterMenu logic handle this
                            }
                        }
                    }
                    .onEnded { _ in
                        // Debounce the scroll end to prevent rapid state changes
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            print("🏠 DEBUG: Setting isScrolling = false in HiddenCountriesSettingsView")
                            isScrolling = false
                            // Note: Don't reset isFooterMenuHidden here - let home button control it
                        }
                    }
            )
        }
        .background(backgroundColor)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Hidden Countries")
                    .font(.headline)
                    .foregroundColor(primaryTextColor)
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 8) {
                    // Search button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isSearchPresented.toggle()
                        }
                    }) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.white)
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Menu button
                    Menu {
                        Button("Hide All") {
                            hideAllCountries()
                        }
                        
                        Button("Show All") {
                            showAllCountries()
                        }
                        
                        Button("Reset to Default") {
                            resetToDefault()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(.white)
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
               // .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .onAppear {
            loadHiddenCountries()
        }
        .onDisappear {
            saveHiddenCountries()
        }
    }
    
    private func toggleCountryVisibility(_ countryName: String, isHidden: Bool) {
        if isHidden {
            hiddenCountries.insert(countryName)
            // Clear selected country if it's being hidden
            clearSelectedCountryIfHidden(countryName)
        } else {
            hiddenCountries.remove(countryName)
        }
        saveHiddenCountries()
        // Notify that hidden countries changed to update UI
        NotificationCenter.default.post(name: .hiddenCountriesChanged, object: countryName, userInfo: ["isHidden": isHidden])
    }
    
    private func hideAllCountries() {
        let previousHidden = hiddenCountries
        hiddenCountries = Set(allCountries.map { $0.name })
        saveHiddenCountries()
        
        // Clear selected country and notify for all newly hidden countries
        clearSelectedCountryIfAnyHidden()
        for country in hiddenCountries where !previousHidden.contains(country) {
            NotificationCenter.default.post(name: .hiddenCountriesChanged, object: country, userInfo: ["isHidden": true])
        }
    }
    
    private func showAllCountries() {
        let previousHidden = hiddenCountries
        hiddenCountries.removeAll()
        saveHiddenCountries()
        
        // Notify for all newly shown countries
        for country in previousHidden {
            NotificationCenter.default.post(name: .hiddenCountriesChanged, object: country, userInfo: ["isHidden": false])
        }
    }
    
    private func resetToDefault() {
        // Keep popular countries visible by default
        let popularCountries = ["United States", "Canada", "United Kingdom", "Germany", "France", "Australia", "Japan", "Brazil"]
        let previousHidden = hiddenCountries
        hiddenCountries = Set(allCountries.map { $0.name }.filter { !popularCountries.contains($0) })
        saveHiddenCountries()
        
        // Clear selected country if it's being hidden
        clearSelectedCountryIfAnyHidden()
        
        // Notify for changes
        let newlyHidden = hiddenCountries.subtracting(previousHidden)
        let newlyShown = previousHidden.subtracting(hiddenCountries)
        
        for country in newlyHidden {
            NotificationCenter.default.post(name: .hiddenCountriesChanged, object: country, userInfo: ["isHidden": true])
        }
        for country in newlyShown {
            NotificationCenter.default.post(name: .hiddenCountriesChanged, object: country, userInfo: ["isHidden": false])
        }
    }
    
    private func clearSelectedCountryIfHidden(_ countryName: String) {
        // Check if the currently selected country is being hidden
        if let selectedCountry = UserDefaults.standard.string(forKey: "selectedCountry"),
           selectedCountry == countryName {
            UserDefaults.standard.set("Select Country", forKey: "selectedCountry")
            // Notify RadioStationViewModel to update its selectedCountry
            NotificationCenter.default.post(name: .selectedCountryCleared, object: nil)
        }
    }
    
    private func clearSelectedCountryIfAnyHidden() {
        if let selectedCountry = UserDefaults.standard.string(forKey: "selectedCountry"),
           hiddenCountries.contains(selectedCountry) {
            UserDefaults.standard.set("Select Country", forKey: "selectedCountry")
            // Notify RadioStationViewModel to update its selectedCountry
            NotificationCenter.default.post(name: .selectedCountryCleared, object: nil)
        }
    }
    
    private func loadHiddenCountries() {
        if let decodedCountries = try? JSONDecoder().decode(Set<String>.self, from: hiddenCountriesData) {
            hiddenCountries = decodedCountries
        }
    }
    
    private func saveHiddenCountries() {
        if let encodedData = try? JSONEncoder().encode(hiddenCountries) {
            hiddenCountriesData = encodedData
        }
    }
}

struct HiddenCountryRow: View {
    let country: Country
    let isHidden: Bool
    let onToggle: (Bool) -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? .gray : .secondary
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Flag
            Group {
                if country.flag.isEmpty {
                    Image(systemName: "flag.slash")
                        .foregroundColor(secondaryTextColor)
                        .font(.body)
                        .frame(width: 40, height: 30)
                } else {
                    if let flag = Flag(countryCode: country.flag) {
                        Image(uiImage: flag.image(style: .roundedRect))
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                            )
                    } else {
                        Image(systemName: "flag.slash")
                            .foregroundColor(secondaryTextColor)
                            .font(.body)
                            .frame(width: 40, height: 30)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(country.name)
                    .font(.body)
                    .foregroundColor(isHidden ? secondaryTextColor : primaryTextColor)
                    .multilineTextAlignment(.leading)
                
                Text(CountryRegion.region(for: country.name).displayName)
                    .font(.caption)
                    .foregroundColor(secondaryTextColor)
            }
            
            Spacer()
            
            // Hidden status
            HStack(spacing: 8) {
                if isHidden {
                    Text("Hidden")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
                
                Button(action: {
                    onToggle(!isHidden)
                }) {
                    Image(systemName: isHidden ? "eye.slash.fill" : "eye.fill")
                        .foregroundColor(isHidden ? .red : .blue)
                        .font(.body)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle(!isHidden)
        }
    }
}


// MARK: - Liquid Glass Search Toolbar Behavior Modifier
struct SearchToolbarBehaviorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .searchToolbarBehavior(.minimize)
        } else {
            // For iOS < 26.0, ensure search bar is visible with standard behavior
            content
        }
    }
}


struct HiddenCountriesSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        HiddenCountriesSettingsView()
            .preferredColorScheme(.dark)
    }
}
