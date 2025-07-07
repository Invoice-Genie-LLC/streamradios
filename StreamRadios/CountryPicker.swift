//
//  CountryPicker.swift
//  StreamRadios
//
//  Created by AI Assistant on 1/2/25.
//

import SwiftUI
import FlagKit

struct CountryPicker: View {
    @Binding var selectedCountry: String
    var countries: [Country]
    @Environment(\.presentationMode) var presentationMode
    
    @State private var searchText = ""
    @State private var recentCountries: [String] = []
    
    // Group countries by regions
    private var groupedCountries: [CountryRegion: [Country]] {
        let filtered = searchText.isEmpty ? countries.filter { $0.name != "Select Country" } :
            countries.filter { $0.name.localizedCaseInsensitiveContains(searchText) && $0.name != "Select Country" }
        
        return Dictionary(grouping: filtered) { country in
            CountryRegion.region(for: country.name)
        }
    }
    
    private var filteredRecentCountries: [Country] {
        let validRecent = recentCountries.filter { recent in
            countries.contains { $0.name == recent && recent != "Select Country" }
        }
        return validRecent.compactMap { recentName in
            countries.first { $0.name == recentName }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar with safe area consideration
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.adaptiveSecondaryText)
                            .font(.system(size: 16, weight: .medium))
                        
                        TextField("Search countries...", text: $searchText)
                            .font(.system(size: 16))
                            .textFieldStyle(PlainTextFieldStyle())
                            .foregroundColor(.adaptivePrimaryText)
                        
                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.adaptiveSecondaryText)
                                    .font(.system(size: 16))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.adaptiveFieldBackground)
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.top, 60) // Increased padding to account for custom header
                }
                .padding(.bottom, 16)
                .background(Color.adaptiveBackground)
                
                List {
                    // Recent selections section
                    if !filteredRecentCountries.isEmpty && searchText.isEmpty {
                        Section {
                            ForEach(filteredRecentCountries, id: \.id) { country in
                                CountryRow(
                                    country: country,
                                    isSelected: selectedCountry == country.name,
                                    showRegion: false
                                ) {
                                    selectCountry(country.name)
                                }
                                .listRowBackground(Color.adaptiveCardBackground)
                            }
                        } header: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(.cyan)
                                    .font(.system(size: 14, weight: .medium))
                                Text("Recent")
                                    .font(.system(size: 14, weight: .medium))
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
                                    showRegion: false
                                ) {
                                    selectCountry(country.name)
                                }
                                .listRowBackground(Color.adaptiveCardBackground)
                            }
                        } header: {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.yellow)
                                    .font(.system(size: 14, weight: .medium))
                                Text("Popular")
                                    .font(.system(size: 14, weight: .medium))
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
                                        showRegion: searchText.isEmpty ? false : true
                                    ) {
                                        selectCountry(country.name)
                                    }
                                    .listRowBackground(Color.adaptiveCardBackground)
                                }
                            } header: {
                                if searchText.isEmpty {
                                    HStack {
                                        Image(systemName: region.icon)
                                            .foregroundColor(.adaptiveSecondaryText)
                                            .font(.system(size: 14, weight: .medium))
                                        Text(region.displayName)
                                            .font(.system(size: 14, weight: .medium))
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
            .navigationBarHidden(true)
            .overlay(
                // Custom header to exactly match Add Station style
                VStack(spacing: 0) {
                    HStack {
                        Button("Cancel") {
                            presentationMode.wrappedValue.dismiss()
                        }
                        .foregroundColor(.blue)
                        .font(.system(size: 17))
                        
                        Spacer()
                        
                        Text("Select Country")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        Spacer()
                        
                        // Invisible button for balance (same width as Cancel)
                        Button("Cancel") { }
                            .foregroundColor(.clear)
                            .font(.system(size: 17))
                            .disabled(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.black)
                    
                    // Separator line to match Add Station
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 0.5)
                    
                    Spacer()
                }
                , alignment: .top
            )
        }
        .background(Color.adaptiveBackground)
        .onAppear {
            loadRecentCountries()
        }
    }
    
    private var popularCountries: [Country] {
        let popularNames = ["United States", "USA", "Canada", "United Kingdom", "UK", "Germany", "France", "Australia", "Japan", "Brazil"]
        return popularNames.compactMap { name in
            countries.first { $0.name == name }
        }
    }
    
    private func selectCountry(_ countryName: String) {
        selectedCountry = countryName
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
}

struct CountryRow: View {
    let country: Country
    let isSelected: Bool
    let showRegion: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Flag
                Group {
                    if country.flag.isEmpty {
                        Image(systemName: "flag.slash")
                            .foregroundColor(.adaptiveSecondaryText)
                            .font(.system(size: 20))
                            .frame(width: 32, height: 24)
                    } else {
                        if let flag = Flag(countryCode: country.flag) {
                            Image(uiImage: flag.image(style: .roundedRect))
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 32, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.adaptiveBorder, lineWidth: 0.5)
                                )
                        } else {
                            Image(systemName: "flag.slash")
                                .foregroundColor(.adaptiveSecondaryText)
                                .font(.system(size: 20))
                                .frame(width: 32, height: 24)
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(country.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.adaptivePrimaryText)
                        .multilineTextAlignment(.leading)
                    
                    if showRegion {
                        Text(CountryRegion.region(for: country.name).displayName)
                            .font(.system(size: 12))
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 20))
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
        let northAmericaCountries = ["United States", "USA", "Canada", "Mexico", "Greenland"]
        let southAmericaCountries = ["Brazil", "Argentina", "Chile", "Peru", "Colombia", "Venezuela", "Ecuador", "Bolivia", "Paraguay", "Uruguay", "Guyana", "Suriname", "French Guiana"]
        let europeCountries = ["United Kingdom", "UK", "England", "Scotland", "Wales", "Northern Ireland", "Germany", "France", "Italy", "Spain", "Netherlands", "Belgium", "Switzerland", "Austria", "Sweden", "Norway", "Denmark", "Finland", "Poland", "Czech Republic", "Slovakia", "Hungary", "Romania", "Bulgaria", "Croatia", "Slovenia", "Serbia", "Bosnia & Herzegovina", "Montenegro", "Albania", "Macedonia", "Greece", "Portugal", "Ireland", "Iceland", "Lithuania", "Latvia", "Estonia", "Belarus", "Ukraine", "Moldova", "Russia", "Luxembourg", "Malta", "Cyprus", "Liechtenstein", "Monaco", "San Marino", "Vatican City", "Andorra"]
        let africaCountries = ["Nigeria", "South Africa", "Kenya", "Egypt", "Morocco", "Ghana", "Ethiopia", "Algeria", "Tunisia", "Libya", "Sudan", "South Sudan", "Uganda", "Tanzania", "Rwanda", "Burundi", "Democratic Republic of Congo", "Congo - Kinshasa", "Congo - Brazzaville", "Central African Republic", "Chad", "Niger", "Mali", "Burkina Faso", "Senegal", "Guinea", "Guinea-Bissau", "Sierra Leone", "Liberia", "Ivory Coast", "Côte d'Ivoire", "Togo", "Benin", "Cameroon", "Equatorial Guinea", "Gabon", "São Tomé & Príncipe", "Angola", "Namibia", "Botswana", "Zimbabwe", "Zambia", "Malawi", "Mozambique", "Madagascar", "Mauritius", "Seychelles", "Comoros", "Djibouti", "Eritrea", "Somalia", "Lesotho", "Swaziland", "Gambia", "Cape Verde"]
        let asiaCountries = ["China", "Japan", "South Korea", "North Korea", "India", "Indonesia", "Thailand", "Vietnam", "Philippines", "Malaysia", "Singapore", "Myanmar", "Cambodia", "Laos", "Bangladesh", "Pakistan", "Afghanistan", "Nepal", "Bhutan", "Sri Lanka", "Maldives", "Mongolia", "Kazakhstan", "Uzbekistan", "Turkmenistan", "Kyrgyzstan", "Tajikistan", "Taiwan", "Hong Kong", "Macau", "Brunei", "Timor-Leste"]
        let oceaniaCountries = ["Australia", "New Zealand", "Fiji", "Papua New Guinea", "Solomon Islands", "Vanuatu", "Samoa", "Tonga", "Kiribati", "Tuvalu", "Nauru", "Palau", "Marshall Islands", "Micronesia", "Cook Islands", "Niue", "American Samoa", "French Polynesia", "Guam", "Northern Mariana Islands", "New Caledonia", "Norfolk Island"]
        let middleEastCountries = ["Saudi Arabia", "United Arab Emirates", "Iran", "Iraq", "Israel", "Jordan", "Lebanon", "Syria", "Turkey", "Kuwait", "Qatar", "Bahrain", "Oman", "Yemen", "Palestinian Territories"]
        let caribbeanCountries = ["Jamaica", "Cuba", "Haiti", "Dominican Republic", "Puerto Rico", "Trinidad & Tobago", "Barbados", "Bahamas", "Saint Lucia", "Grenada", "Saint Vincent & Grenadines", "Antigua & Barbuda", "Dominica", "Saint Kitts & Nevis", "Aruba", "Curaçao", "Sint Maarten", "British Virgin Islands", "U.S. Virgin Islands", "Cayman Islands", "Turks & Caicos Islands", "Anguilla", "Montserrat", "Guadeloupe", "Martinique", "Saint Barthélemy", "Saint Martin"]
        
        if northAmericaCountries.contains(countryName) {
            return .northAmerica
        } else if southAmericaCountries.contains(countryName) {
            return .southAmerica
        } else if europeCountries.contains(countryName) {
            return .europe
        } else if africaCountries.contains(countryName) {
            return .africa
        } else if asiaCountries.contains(countryName) {
            return .asia
        } else if oceaniaCountries.contains(countryName) {
            return .oceania
        } else if middleEastCountries.contains(countryName) {
            return .middleEast
        } else if caribbeanCountries.contains(countryName) {
            return .caribbean
        } else {
            return .other
        }
    }
}

struct CountryPickerButton: View {
    @Binding var selectedCountry: String
    var countries: [Country]
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
                            .frame(width: 24, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.adaptiveBorder, lineWidth: 0.5)
                            )
                    } else {
                        Image(systemName: "flag.slash")
                            .foregroundColor(.adaptiveSecondaryText)
                            .font(.system(size: 16))
                            .frame(width: 24, height: 16)
                    }
                }
                
                Text(selectedCountry.isEmpty || selectedCountry == "Select Country" ? "Select Country" : selectedCountry)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.adaptivePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.adaptiveSecondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.adaptiveFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .sheet(isPresented: $showingPicker) {
            CountryPicker(selectedCountry: $selectedCountry, countries: countries)
        }
    }
}

struct CountryPicker_Previews: PreviewProvider {
    static var previews: some View {
        CountryPickerButton(
            selectedCountry: .constant("Select Country"),
            countries: [
                Country(name: "Select Country", flag: ""),
                Country(name: "United States", flag: "US"),
                Country(name: "Canada", flag: "CA"),
                Country(name: "Mexico", flag: "MX"),
                Country(name: "Germany", flag: "DE"),
                Country(name: "France", flag: "FR")
            ]
        )
        .previewLayout(.sizeThatFits)
        .padding()
        .background(Color.black)
    }
}
