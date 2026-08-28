//
//  CountryPicker.swift
//  StreamRadios
//
//  Created by AI Assistant on 1/2/25.
//

import SwiftUI
import FlagKit
import StreamRadiosKit

// MARK: - Conditional Liquid Glass Modifier
struct CountryPickerLiquidGlass: ViewModifier {
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

// MARK: - Progress View Models
class CountryDeletionProgressViewModel: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var currentStep: String = ""
    @Published var isCompleted: Bool = false
    @Published var isCancelled: Bool = false
    
    func updateProgress(_ newProgress: Double, step: String) {
        DispatchQueue.main.async {
            self.progress = newProgress
            self.currentStep = step
        }
    }
    
    func markCompleted() {
        DispatchQueue.main.async {
            self.isCompleted = true
            self.progress = 1.0
        }
    }
    
    func cancel() {
        isCancelled = true
    }
    
    func reset() {
        progress = 0.0
        currentStep = ""
        isCompleted = false
        isCancelled = false
    }
}

// MARK: - Progress View
struct CountryDeletionProgressView: View {
    @ObservedObject var viewModel: CountryDeletionProgressViewModel
    let countryName: String
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                Text("Deleting Stations")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Removing all stations from \(countryName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                VStack(spacing: 16) {
                    // Progress bar
                    ProgressView(value: viewModel.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .scaleEffect(y: 2)
                    
                    // Percentage
                    Text("\(Int(viewModel.progress * 100))%")
                        .font(.title3)
                        .fontWeight(.medium)
                    
                    // Current step
                    Text(viewModel.currentStep)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 20)
                }
                
                if viewModel.isCompleted {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") {
                        viewModel.cancel()
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
            )
            .shadow(radius: 10)
            .padding(.horizontal, 40)
        }
    }
}

struct CountryPicker: View {
    @Binding var selectedCountry: String
    var countries: [Country]
    var stationCount: ((String) -> Int)?
    var onSelect: ((String) -> Void)? = nil
    @Environment(\.presentationMode) var presentationMode
    
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var recentCountries: [String] = []
    @State private var showingDeleteAlert = false
    @State private var countryToDelete: Country? = nil
    @State private var showingProgressView = false
    @StateObject private var progressViewModel = CountryDeletionProgressViewModel()
    @AppStorage("hiddenCountries") private var hiddenCountriesData: Data = Data()
    @State private var hiddenCountries: Set<String> = []
    @State private var isAscendingSort = true
    
    // Group countries by regions
    private var groupedCountries: [CountryRegion: [Country]] {
        let filtered = searchText.isEmpty ? countries.filter { $0.name != "Select Country" && !hiddenCountries.contains($0.name) } :
            countries.filter { $0.name.localizedCaseInsensitiveContains(searchText) && $0.name != "Select Country" && !hiddenCountries.contains($0.name) }
        
        return Dictionary(grouping: filtered) { country in
            CountryRegion.region(for: country.name)
        }
    }
    
    private var filteredRecentCountries: [Country] {
        let validRecent = recentCountries.filter { recent in
            countries.contains { $0.name == recent && recent != "Select Country" && !hiddenCountries.contains($0.name) }
        }
        return validRecent.compactMap { recentName in
            countries.first { $0.name == recentName }
        }
    }
    
    var body: some View {
        Group {
            VStack(spacing: 0) {
                pickerHeader
                
                List {
                    // Recent selections section
                    if !filteredRecentCountries.isEmpty && searchText.isEmpty {
                        Section {
                            ForEach(sortedByName(filteredRecentCountries), id: \.id) { country in
                                countryRow(country, showRegion: false)
                            }
                        } header: {
                            sectionHeader("Recent", systemImage: "clock.arrow.circlepath", tint: .cyan)
                        }
                    }
                    
                    // Popular countries section (if no search)
                    if searchText.isEmpty {
                        Section {
                            ForEach(sortedByName(popularCountries), id: \.id) { country in
                                countryRow(country, showRegion: false)
                            }
                        } header: {
                            sectionHeader("Popular", systemImage: "star.fill", tint: .yellow)
                        }
                    }
                    
                    // Regional sections
                    ForEach(Array(groupedCountries.keys).sorted { $0.sortOrder < $1.sortOrder }, id: \.self) { region in
                        if let regionCountries = groupedCountries[region], !regionCountries.isEmpty {
                            Section {
                                ForEach(sortedByName(regionCountries), id: \.id) { country in
                                    countryRow(country, showRegion: !searchText.isEmpty)
                                }
                            } header: {
                                if searchText.isEmpty {
                                    sectionHeader(region.displayName, systemImage: region.icon, tint: .adaptiveSecondaryText)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.adaptiveBackground)
            }
            .background(Color.adaptiveBackground)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { _ in
                    // Dismiss keyboard when tapping outside search field
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            )
        }
        .background(Color.adaptiveBackground)
        .onAppear {
            loadRecentCountries()
            loadHiddenCountries()
        }
        .alert("Delete All Stations", isPresented: $showingDeleteAlert, presenting: countryToDelete) { country in
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                deleteStationsForCountry(country)
            }
        } message: { country in
            let stationCount = stationCount?(country.name) ?? 0
            return Text("Are you sure you want to delete all \(stationCount) stations from \(country.name)?\n\nThis will permanently remove them from both CloudKit and your local device.\n\nIf you have any custom stations you want to keep, please go to Settings → Manage App Data → Export Stations to backup your data first.")
        }
        .overlay(
            showingProgressView ?
            CountryDeletionProgressView(
                viewModel: progressViewModel,
                countryName: countryToDelete?.name ?? "",
                isPresented: $showingProgressView
            ) : nil
        )
    }
    
    // MARK: - Rows

    private func sortedByName(_ list: [Country]) -> [Country] {
        list.sorted { isAscendingSort ? $0.name < $1.name : $0.name > $1.name }
    }

    private func countryRow(_ country: Country, showRegion: Bool) -> some View {
        CountryRow(
            country: country,
            isSelected: selectedCountry == country.name,
            showRegion: showRegion,
            stationCount: stationCount?(country.name)
        ) {
            selectCountry(country.name)
        }
        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let count = stationCount?(country.name), count > 0 {
                // Not `role: .destructive`: SwiftUI animates the row out the moment a destructive
                // swipe button is tapped, so cancelling the confirmation still lost the row.
                Button {
                    countryToDelete = country
                    showingDeleteAlert = true
                } label: {
                    // Icon-only: a title widens the button and iOS draws it as an ellipse.
                    Label("Delete Stations", systemImage: "trash").labelStyle(.iconOnly)
                }
                .tint(.red)
            }
        }
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

    // MARK: - Header

    /// Mirrors the radio home header: a leading capsule plus a trailing action capsule.
    private var pickerHeader: some View {
        HStack(spacing: 10) {
            if isSearchPresented {
                searchBar
            } else {
                headerActionButton("chevron.left") {
                    presentationMode.wrappedValue.dismiss()
                }
                .frame(height: 40)
                .background(Capsule().fill(Color.adaptiveSecondaryBackground))
                .modifier(ConditionalLiquidGlass(cornerRadius: 20))

                Text("Select Country")
                    .font(.headline)
                    .foregroundColor(.adaptivePrimaryText)
                    .lineLimit(1)
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

    private var popularCountries: [Country] {
        let popularNames = ["United States", "Canada", "United Kingdom", "Germany", "France", "Australia", "Japan", "Brazil"]
        return popularNames.compactMap { name in
            countries.first { $0.name == name && !hiddenCountries.contains($0.name) }
        }
    }
    
    private func selectCountry(_ countryName: String) {
        selectedCountry = countryName
        onSelect?(countryName)
        saveRecentCountry(countryName)
        presentationMode.wrappedValue.dismiss()
    }
    
    private func loadRecentCountries() {
        recentCountries = UserDefaults.standard.stringArray(forKey: "recentCountries") ?? []
    }
    
    private func saveRecentCountry(_ countryName: String) {
        var recent = UserDefaults.standard.stringArray(forKey: "recentCountries") ?? []
        
        // Remove if already exists
        recent.removeAll { $0 == countryName }
        
        // Add to beginning
        recent.insert(countryName, at: 0)
        
        // Keep only last 5
        recent = Array(recent.prefix(5))
        
        UserDefaults.standard.set(recent, forKey: "recentCountries")
        recentCountries = recent
    }
    
    private func loadHiddenCountries() {
        if let decodedCountries = try? JSONDecoder().decode(Set<String>.self, from: hiddenCountriesData) {
            hiddenCountries = decodedCountries
        }
    }
    
    private func deleteStationsForCountry(_ country: Country) {
        // Reset and show progress view
        progressViewModel.reset()
        showingProgressView = true
        
        Task { @MainActor in
            await RadioStationViewModel.shared.deleteStationsForCountry(country.name, progressViewModel: progressViewModel)
            // Update the UI by notifying that stations have been updated
            NotificationCenter.default.post(name: .stationsUpdated, object: nil)
        }
    }
}

struct CountryRow: View {
    let country: Country
    let isSelected: Bool
    let showRegion: Bool
    let stationCount: Int?
    let onTap: () -> Void
    
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                flagView

                VStack(alignment: .leading, spacing: 2) {
                    Text(country.name)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? SRColor.accent : .adaptivePrimaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)

                    if showRegion {
                        Text(CountryRegion.region(for: country.name).displayName)
                            .font(.caption)
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Station count badge
                if let count = stationCount, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(SRColor.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(SRColor.accent.opacity(0.15)))
                }

                // Kept in the layout so selecting a country doesn't shift the row's contents.
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundColor(SRColor.accent)
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.5)
            }
            // The swipe button has a fixed minimum width, so a short row makes it a wide ellipse.
            .frame(minHeight: 44)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(shape.fill(isSelected ? SRColor.accent.opacity(0.12) : Color.adaptiveCardBackground))
            .overlay(shape.stroke(isSelected ? SRColor.accent.opacity(0.35) : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(CountryRowButtonStyle())
        .animation(.snappy(duration: 0.25), value: isSelected)
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

private struct CountryRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

enum CountryRegion: String, CaseIterable, Hashable {
    case northAmerica = "North America"
    case southAmerica = "South America"
    case europe = "Europe"
    case africa = "Africa"
    case asia = "Asia"
    case oceania = "Oceania"
    case middleEast = "Middle East"
    case caribbean = "Caribbean"
    case other = "Other"
    
    var displayName: String {
        return rawValue
    }
    
    var icon: String {
        switch self {
        case .northAmerica: return "map"
        case .southAmerica: return "map"
        case .europe: return "building.2"
        case .africa: return "safari"
        case .asia: return "mountain.2"
        case .oceania: return "water.waves"
        case .middleEast: return "building.columns"
        case .caribbean: return "sun.max"
        case .other: return "globe"
        }
    }
    
    var sortOrder: Int {
        switch self {
        case .northAmerica: return 0
        case .europe: return 1
        case .asia: return 2
        case .oceania: return 3
        case .southAmerica: return 4
        case .middleEast: return 5
        case .africa: return 6
        case .caribbean: return 7
        case .other: return 8
        }
    }
    
    static func region(for countryName: String) -> CountryRegion {
        // North America (including Central America)
        let northAmericaCountries = [
            "United States", "Canada", "Mexico", "Greenland",
            "Guatemala", "Belize", "Honduras", "El Salvador", "Nicaragua", "Costa Rica", "Panama"
        ]
        
        // South America
        let southAmericaCountries = [
            "Brazil", "Argentina", "Chile", "Peru", "Colombia", "Venezuela", "Ecuador", "Bolivia",
            "Paraguay", "Uruguay", "Guyana", "Suriname", "French Guiana"
        ]
        
        // Europe (including European Russia)
        let europeCountries = [
            "United Kingdom", "Germany", "France", "Italy", "Spain", "Netherlands", "Belgium",
            "Switzerland", "Austria", "Sweden", "Norway", "Denmark", "Finland", "Poland",
            "Czech Republic", "Slovakia", "Hungary", "Romania", "Bulgaria", "Croatia", "Slovenia",
            "Serbia", "Bosnia & Herzegovina", "Montenegro", "Albania", "Macedonia", "Greece",
            "Portugal", "Ireland", "Iceland", "Lithuania", "Latvia", "Estonia", "Belarus",
            "Ukraine", "Moldova", "Russia", "Luxembourg", "Malta", "Cyprus", "Liechtenstein",
            "Monaco", "San Marino", "Vatican City", "Andorra", "Kosovo"
        ]
        
        // Africa
        let africaCountries = [
            "Nigeria", "South Africa", "Kenya", "Egypt", "Morocco", "Ghana", "Ethiopia", "Algeria",
            "Tunisia", "Libya", "Sudan", "South Sudan", "Uganda", "Tanzania", "Rwanda", "Burundi",
            "Congo - Kinshasa", "Congo - Brazzaville", "Central African Republic", "Chad", "Niger",
            "Mali", "Burkina Faso", "Senegal", "Guinea", "Guinea-Bissau", "Sierra Leone", "Liberia",
            "Côte d'Ivoire", "Togo", "Benin", "Cameroon", "Equatorial Guinea", "Gabon",
            "São Tomé & Príncipe", "Angola", "Namibia", "Botswana", "Zimbabwe", "Zambia", "Malawi",
            "Mozambique", "Madagascar", "Mauritius", "Seychelles", "Comoros", "Djibouti", "Eritrea",
            "Somalia", "Lesotho", "Swaziland", "Gambia", "Cape Verde"
        ]
        
        // Asia (including Central Asia and parts of Middle East)
        let asiaCountries = [
            "China", "Japan", "South Korea", "North Korea", "India", "Indonesia", "Thailand",
            "Vietnam", "Philippines", "Malaysia", "Singapore", "Myanmar", "Cambodia", "Laos",
            "Bangladesh", "Pakistan", "Afghanistan", "Nepal", "Bhutan", "Sri Lanka", "Maldives",
            "Mongolia", "Kazakhstan", "Uzbekistan", "Turkmenistan", "Kyrgyzstan", "Tajikistan",
            "Taiwan", "Hong Kong", "Macau", "Brunei", "Timor-Leste"
        ]
        
        // Oceania (Australia, New Zealand, and Pacific Islands)
        let oceaniaCountries = [
            "Australia", "New Zealand", "Fiji", "Papua New Guinea", "Solomon Islands", "Vanuatu",
            "Samoa", "Tonga", "Kiribati", "Tuvalu", "Nauru", "Palau", "Marshall Islands",
            "Micronesia", "Cook Islands", "Niue", "American Samoa", "French Polynesia", "Guam",
            "Northern Mariana Islands", "New Caledonia", "Norfolk Island", "Pitcairn Islands",
            "Tokelau", "Wallis & Futuna"
        ]
        
        // Middle East (Western Asia and North Africa)
        let middleEastCountries = [
            "Saudi Arabia", "United Arab Emirates", "Iran", "Iraq", "Israel", "Jordan", "Lebanon",
            "Syria", "Turkey", "Kuwait", "Qatar", "Bahrain", "Oman", "Yemen", "Palestinian Territories"
        ]
        
        // Caribbean
        let caribbeanCountries = [
            "Jamaica", "Cuba", "Haiti", "Dominican Republic", "Puerto Rico", "Trinidad & Tobago",
            "Barbados", "Bahamas", "Saint Lucia", "Grenada", "Saint Vincent & Grenadines",
            "Antigua & Barbuda", "Dominica", "Saint Kitts & Nevis", "Aruba", "Curaçao",
            "Sint Maarten", "British Virgin Islands", "United States Virgin Islands", "Cayman Islands",
            "Turks & Caicos Islands", "Anguilla", "Montserrat", "Guadeloupe", "Martinique",
            "Saint Barthélemy", "Saint Martin"
        ]
        
        // Add missing countries to proper regions
        let additionalEuropeCountries = [
            "Armenia", "Azerbaijan", "Georgia", "Faroe Islands", "Gibraltar", "Guernsey",
            "Isle of Man", "Jersey", "Åland Islands"
        ]
        
        let additionalAfricaCountries = [
            "Mayotte", "Réunion", "Saint Helena"
        ]
        
        let additionalOceaniaCountries = [
            "Christmas Island", "Cocos (Keeling) Islands"
        ]
        
        let additionalCaribbean = [
            "Bermuda", "Saint Pierre & Miquelon"
        ]
        
        let additionalSouthAmerica = [
            "Falkland Islands"
        ]
        
        // Special territories and other regions
        let otherRegions = [
            "Select Country", "Unknown Region"
        ]
        
        // Check all regions including additional countries
        let allEuropeCountries = europeCountries + additionalEuropeCountries
        let allAfricaCountries = africaCountries + additionalAfricaCountries
        let allOceaniaCountries = oceaniaCountries + additionalOceaniaCountries
        let allCaribbeanCountries = caribbeanCountries + additionalCaribbean
        let allSouthAmericaCountries = southAmericaCountries + additionalSouthAmerica
        
        if northAmericaCountries.contains(countryName) {
            return .northAmerica
        } else if allSouthAmericaCountries.contains(countryName) {
            return .southAmerica
        } else if allEuropeCountries.contains(countryName) {
            return .europe
        } else if allAfricaCountries.contains(countryName) {
            return .africa
        } else if asiaCountries.contains(countryName) {
            return .asia
        } else if allOceaniaCountries.contains(countryName) {
            return .oceania
        } else if middleEastCountries.contains(countryName) {
            return .middleEast
        } else if allCaribbeanCountries.contains(countryName) {
            return .caribbean
        } else if otherRegions.contains(countryName) {
            return .other
        } else {
            return .other
        }
    }
}

struct CountryPickerButton: View {
    @Binding var selectedCountry: String
    var countries: [Country]
    var stationCount: ((String) -> Int)?
    var onSelect: ((String) -> Void)? = nil
    var isDisabled: Bool = false
    /// Single-line capsule for the radio list header; forms keep the taller two-line layout.
    var compact: Bool = false
    @State private var showingPicker = false
    
    var body: some View {
        Button(action: {
            if !isDisabled {
                showingPicker = true
            }
        }) {
            if compact {
                compactLabel
            } else {
                standardLabel
            }
        }
        .disabled(isDisabled)
        .fullScreenCover(isPresented: $showingPicker) {
            CountryPicker(selectedCountry: $selectedCountry, countries: countries, stationCount: stationCount, onSelect: { country in
                onSelect?(country)
                // FIXED: Use countryChanged notification instead of stationsUpdated to prevent contamination of currently playing station
                // This allows UI updates without affecting the currently playing station state
                NotificationCenter.default.post(name: .countryChanged, object: nil)
            })
        }
    }

    private var hasSelection: Bool {
        !selectedCountry.isEmpty && selectedCountry != "Select Country"
    }

    private var resolvedCount: Int? {
        guard !isDisabled, hasSelection, let count = stationCount?(selectedCountry), count > 0 else { return nil }
        return count
    }

    @ViewBuilder
    private var flagView: some View {
        if isDisabled {
            Image(systemName: "wifi.slash")
                .foregroundColor(.gray)
                .font(.body)
                .frame(width: 30, height: 20)
        } else if let selectedCountryData = countries.first(where: { $0.name == selectedCountry }),
                  !selectedCountryData.flag.isEmpty,
                  let flag = Flag(countryCode: selectedCountryData.flag) {
            Image(uiImage: flag.image(style: .roundedRect))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.adaptiveBorder, lineWidth: 0.5)
                )
        } else {
            Image(systemName: "globe")
                .foregroundColor(.adaptiveSecondaryText)
                .font(.body)
                .frame(width: 30, height: 20)
        }
    }

    private var compactLabel: some View {
        HStack(spacing: 8) {
            flagView
                .scaleEffect(0.8)
                .frame(width: 24, height: 16)

            Text(isDisabled ? "Offline" : (hasSelection ? selectedCountry : "Select Country"))
                .font(.subheadline.weight(.medium))
                .foregroundColor(isDisabled ? .gray : .adaptivePrimaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            if let count = resolvedCount {
                Text(count.formatted(.number))
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundColor(.adaptiveSecondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.adaptiveSecondaryText.opacity(0.15)))
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundColor(isDisabled ? .gray : .adaptiveSecondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Capsule().fill(Color.adaptiveFieldBackground))
        .contentShape(Capsule())
    }

    private var standardLabel: some View {
        HStack(spacing: 8) {
            flagView
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isDisabled ? "Offline - Country Browser Disabled" : (hasSelection ? selectedCountry : "Select Country"))
                    .font(.body)
                    .foregroundColor(isDisabled ? .gray : .adaptivePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                // Show station count for selected country
                if let count = resolvedCount {
                    Text("\(count) stations")
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.down")
                .font(.body)
                .foregroundColor(isDisabled ? .gray : .adaptiveSecondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isDisabled ? Color.gray.opacity(0.2) : Color.adaptiveFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CountryPicker_Previews: PreviewProvider {
    static var previews: some View {
        CountryPickerButton(
            selectedCountry: .constant("Canada"),
            countries: [
                Country(name: "Select Country", flag: ""),
                Country(name: "Canada", flag: "CA"),
                Country(name: "Mexico", flag: "MX"),
                Country(name: "Germany", flag: "DE"),
                Country(name: "France", flag: "FR")
            ],
            stationCount: { country in
                // Sample station counts for preview
                switch country {
                case "Canada": return 15
                case "Mexico": return 8
                case "Germany": return 25
                case "France": return 12
                default: return 0
                }
            }
        )
        .previewLayout(.sizeThatFits)
        .padding()
        .background(Color.black)
    }
}
