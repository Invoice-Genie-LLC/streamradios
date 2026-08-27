//
//  HiddenCountriesSettingsView.swift
//  StreamRadios
//
//  Created by AI Assistant on 1/2/25.
//

import SwiftUI
import FlagKit
import StreamRadiosKit

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
    @State private var isAscendingSort = true
    @FocusState private var isSearchFieldFocused: Bool
    
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
    
    private var groupedCountries: [CountryRegion: [Country]] {
        let filtered = searchText.isEmpty ? allCountries :
            allCountries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return Dictionary(grouping: filtered) { CountryRegion.region(for: $0.name) }
    }
    
    private func sortedByName(_ list: [Country]) -> [Country] {
        list.sorted { isAscendingSort ? $0.name < $1.name : $0.name > $1.name }
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
            header
            
            List {
                ForEach(Array(groupedCountries.keys).sorted { $0.sortOrder < $1.sortOrder }, id: \.self) { region in
                    if let regionCountries = groupedCountries[region], !regionCountries.isEmpty {
                        Section {
                            ForEach(sortedByName(regionCountries), id: \.id) { country in
                                HiddenCountryRow(
                                    country: country,
                                    isHidden: hiddenCountries.contains(country.name),
                                    showRegion: !searchText.isEmpty
                                ) {
                                    toggleCountryVisibility(country.name, isHidden: !hiddenCountries.contains(country.name))
                                }
                                .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        } header: {
                            if searchText.isEmpty {
                                sectionHeader(region.displayName, systemImage: region.icon, tint: .adaptiveSecondaryText)
                            }
                        }
                    }
                }
                
                Section {
                    EmptyView()
                } footer: {
                    Text("Hidden countries will not appear in the country picker when adding stations or browsing by country.")
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.adaptiveBackground)
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
                                isScrolling = true
                            }
                        }
                    }
                    .onEnded { _ in
                        // Debounce the scroll end to prevent rapid state changes
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            isScrolling = false
                        }
                    }
            )
        }
        .background(Color.adaptiveBackground)
        .navigationBarHidden(true)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { _ in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        )
        .onAppear {
            loadHiddenCountries()
        }
        .onDisappear {
            saveHiddenCountries()
        }
    }
    
    // MARK: - Header
    
    /// Mirrors the Select Country header: a leading capsule plus a trailing action capsule.
    private var header: some View {
        HStack(spacing: 10) {
            if isSearchPresented {
                searchBar
            } else {
                headerActionButton("chevron.left") {
                    dismiss()
                }
                .frame(height: 40)
                .background(Capsule().fill(Color.adaptiveSecondaryBackground))
                .modifier(ConditionalLiquidGlass(cornerRadius: 20))
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hidden Countries")
                        .font(.headline)
                        .foregroundColor(.adaptivePrimaryText)
                        .lineLimit(1)
                    
                    Text("\(hiddenCountries.count) hidden")
                        .font(.caption2)
                        .foregroundColor(.adaptiveSecondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            headerActions
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.adaptiveBackground)
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundColor(.adaptiveSecondaryText)
            
            TextField("Search countries...", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.subheadline)
                .foregroundColor(.adaptivePrimaryText)
                .focused($isSearchFieldFocused)
                .submitLabel(.search)
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.adaptiveSecondaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Capsule().fill(Color.adaptiveFieldBackground))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFieldFocused = true
            }
        }
    }
    
    private var headerActions: some View {
        HStack(spacing: 0) {
            if isSearchPresented {
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isSearchPresented = false
                        searchText = ""
                        isSearchFieldFocused = false
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.adaptivePrimaryText)
                .padding(.horizontal, 14)
            } else {
                headerActionButton("magnifyingglass") {
                    withAnimation(.easeInOut(duration: 0.25)) { isSearchPresented = true }
                }
                
                headerActionButton(isAscendingSort ? "arrow.up.circle" : "arrow.down.circle") {
                    isAscendingSort.toggle()
                }
                
                Menu {
                    Button("Hide All") { hideAllCountries() }
                    Button("Show All") { showAllCountries() }
                    Button("Reset to Default") { resetToDefault() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.adaptivePrimaryText)
                        .frame(width: 38, height: 40)
                        .contentShape(Rectangle())
                }
            }
        }
        .frame(height: 40)
        .background(Capsule().fill(Color.adaptiveSecondaryBackground))
        .modifier(ConditionalLiquidGlass(cornerRadius: 20))
    }
    
    private func headerActionButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.adaptivePrimaryText)
                .frame(width: 38, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func sectionHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundColor(tint)
        .padding(.leading, 4)
        .padding(.top, 6)
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
    let showRegion: Bool
    let onToggle: () -> Void
    
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 14) {
                flagView
                    .opacity(isHidden ? 0.45 : 1)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(country.name)
                        .font(.body)
                        .foregroundColor(isHidden ? .adaptiveSecondaryText : .adaptivePrimaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                    
                    if showRegion {
                        Text(CountryRegion.region(for: country.name).displayName)
                            .font(.caption)
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                if isHidden {
                    Text("Hidden")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                }
                
                Image(systemName: isHidden ? "eye.slash.fill" : "eye.fill")
                    .font(.body)
                    .foregroundColor(isHidden ? .red : SRColor.accent)
            }
            .frame(minHeight: 44)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(shape.fill(isHidden ? Color.red.opacity(0.10) : Color.adaptiveCardBackground))
            .overlay(shape.stroke(isHidden ? Color.red.opacity(0.30) : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(HiddenCountryRowButtonStyle())
        .animation(.snappy(duration: 0.25), value: isHidden)
    }
    
    @ViewBuilder
    private var flagView: some View {
        if !country.flag.isEmpty, let flag = Flag(countryCode: country.flag) {
            Image(uiImage: flag.image(style: .roundedRect))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 46, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.adaptiveBorder, lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.adaptiveSectionBackground)
                .frame(width: 46, height: 34)
                .overlay(
                    Image(systemName: "globe")
                        .font(.footnote)
                        .foregroundColor(.adaptiveSecondaryText)
                )
        }
    }
}

private struct HiddenCountryRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
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
