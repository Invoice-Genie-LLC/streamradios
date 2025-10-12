//
//  CountryPicker.swift
//  StreamRadios
//
//  Created by AI Assistant on 1/2/25.
//

import SwiftUI
import FlagKit

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
    @State private var recentCountries: [String] = []
    @State private var showingDeleteAlert = false
    @State private var countryToDelete: Country? = nil
    @State private var showingProgressView = false
    @StateObject private var progressViewModel = CountryDeletionProgressViewModel()
    @AppStorage("hiddenCountries") private var hiddenCountriesData: Data = Data()
    @State private var hiddenCountries: Set<String> = []
    
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
        NavigationView {
            VStack(spacing: 0) {
                // Search bar with liquid glass style (conditional)
                if isSearchPresented {
                    HStack(spacing: 12) {
                        CustomSearchBar(searchText: $searchText, isPresented: $isSearchPresented, placeholder: "Search countries...")
                        
                        // Cancel button
                        Button("Cancel") {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isSearchPresented = false
                                searchText = ""
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }
                        }
                        .foregroundColor(.blue)
                        .font(.system(size: 16))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .background(Color.adaptiveBackground)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                List {
                    // Recent selections section
                    if !filteredRecentCountries.isEmpty && searchText.isEmpty {
                        Section {
                            ForEach(filteredRecentCountries, id: \.id) { country in
                                CountryRow(
                                    country: country,
                                    isSelected: selectedCountry == country.name,
                                    showRegion: false,
                                    stationCount: stationCount?(country.name)
                                ) {
                                    selectCountry(country.name)
                                }
                                .listRowBackground(Color.adaptiveCardBackground)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if let count = stationCount?(country.name), count > 0 {
                                        Button(role: .destructive) {
                                            countryToDelete = country
                                            showingDeleteAlert = true
                                        } label: {
                                            Label("Delete Stations", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(.cyan)
                                    .font(.subheadline)
                                Text("Recent")
                                    .font(.subheadline)
                                    .foregroundColor(.cyan)
                            }
                        }
                    }
                    
                    // Popular countries section (if no search)
                    if searchText.isEmpty {
                        Section {
                            ForEach(popularCountries, id: \.id) { country in
                                CountryRow(
                                    country: country,
                                    isSelected: selectedCountry == country.name,
                                    showRegion: false,
                                    stationCount: stationCount?(country.name)
                                ) {
                                    selectCountry(country.name)
                                }
                                .listRowBackground(Color.adaptiveCardBackground)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if let count = stationCount?(country.name), count > 0 {
                                        Button(role: .destructive) {
                                            countryToDelete = country
                                            showingDeleteAlert = true
                                        } label: {
                                            Label("Delete Stations", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.yellow)
                                    .font(.subheadline)
                                Text("Popular")
                                    .font(.subheadline)
                                    .foregroundColor(.yellow)
                            }
                        }
                    }
                    
                    // Regional sections
                    ForEach(Array(groupedCountries.keys).sorted { $0.sortOrder < $1.sortOrder }, id: \.self) { region in
                        if let regionCountries = groupedCountries[region], !regionCountries.isEmpty {
                            Section {
                                ForEach(regionCountries.sorted { $0.name < $1.name }, id: \.id) { country in
                                    CountryRow(
                                        country: country,
                                        isSelected: selectedCountry == country.name,
                                        showRegion: searchText.isEmpty ? false : true,
                                        stationCount: stationCount?(country.name)
                                    ) {
                                        selectCountry(country.name)
                                    }
                                    .listRowBackground(Color.adaptiveCardBackground)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if let count = stationCount?(country.name), count > 0 {
                                            Button(role: .destructive) {
                                                countryToDelete = country
                                                showingDeleteAlert = true
                                            } label: {
                                                Label("Delete Stations", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            } header: {
                                if searchText.isEmpty {
                                    HStack {
                                        Image(systemName: region.icon)
                                            .foregroundColor(.adaptiveSecondaryText)
                                            .font(.subheadline)
                                        Text(region.displayName)
                                            .font(.subheadline)
                                            .foregroundColor(.adaptiveSecondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
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
            .navigationTitle("Select Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.blue)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 8) {
                        // Sort button
                        Button(action: {
                            // Toggle sort direction in RadioStationViewModel
                            RadioStationViewModel.shared.sortStationsAlphabetically()
                        }) {
                            Image(systemName: RadioStationViewModel.shared.isAscendingSort ? "arrow.up.circle" : "arrow.down.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 32, height: 32)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        
                        // Search button
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isSearchPresented.toggle()
                                if !isSearchPresented {
                                    searchText = ""
                                }
                            }
                        }) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.white)
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 32, height: 32)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                }
            }
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
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Flag
                Group {
                    if country.flag.isEmpty {
                        Image(systemName: "flag.slash")
                            .foregroundColor(.adaptiveSecondaryText)
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
                                        .stroke(Color.adaptiveBorder, lineWidth: 0.5)
                                )
                        } else {
                            Image(systemName: "flag.slash")
                                .foregroundColor(.adaptiveSecondaryText)
                                .font(.body)
                                .frame(width: 40, height: 30)
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(country.name)
                        .font(.body)
                        .foregroundColor(.adaptivePrimaryText)
                        .multilineTextAlignment(.leading)
                    
                    if showRegion {
                        Text(CountryRegion.region(for: country.name).displayName)
                            .font(.caption)
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                }
                
                Spacer()
                
                // Station count badge
                if let count = stationCount, count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(10)
                }
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.body)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
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
    @State private var showingPicker = false
    
    var body: some View {
        Button(action: {
            showingPicker = true
        }) {
            HStack(spacing: 8) {
                // Flag
                Group {
                    if let selectedCountryData = countries.first(where: { $0.name == selectedCountry }),
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
                        Image(systemName: "flag.slash")
                            .foregroundColor(.adaptiveSecondaryText)
                            .font(.body)
                            .frame(width: 30, height: 20)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedCountry.isEmpty || selectedCountry == "Select Country" ? "Select Country" : selectedCountry)
                        .font(.body)
                        .foregroundColor(.adaptivePrimaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    // Show station count for selected country
                    if let count = stationCount?(selectedCountry), count > 0, selectedCountry != "Select Country" && !selectedCountry.isEmpty {
                        Text("\(count) stations")
                            .font(.caption)
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.down")
                    .font(.body)
                    .foregroundColor(.adaptiveSecondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.adaptiveFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .sheet(isPresented: $showingPicker) {
            CountryPicker(selectedCountry: $selectedCountry, countries: countries, stationCount: stationCount, onSelect: { country in
                onSelect?(country)
                // FIXED: Use countryChanged notification instead of stationsUpdated to prevent contamination of currently playing station
                // This allows UI updates without affecting the currently playing station state
                NotificationCenter.default.post(name: .countryChanged, object: nil)
            })
        }
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
