//
//  StyledPickerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/8/24.
//

import SwiftUI
import FlagKit

struct StyledPickerView: View {
    @Binding var selectedCountry: String
    var countries: [Country]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            Picker("Select a Country", selection: $selectedCountry) {
                ForEach(countries) { country in
                    CountryPickerRow(country: country)
                        .tag(country.name)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .accentColor(.primary) // Highlight color for selection
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }
}

struct CountryPickerRow: View {
    let country: Country
    
    var body: some View {
        HStack {
            flagImage(for: country.flag)
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.gray, lineWidth: 1)) // Optional: add a border

            Text(country.name)
                .font(.title) // Larger font size for better readability
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            Spacer()
        }
        .padding(.vertical, 10)
    }

    /// Fetches the flag image using FlagKit based on the country code.
    func flagImage(for countryCode: String) -> Image {
        let bundle = FlagKit.assetBundle
        let image = UIImage(named: countryCode, in: bundle, compatibleWith: nil) ?? UIImage()
        return Image(uiImage: image)
    }
}

struct StyledPickerView_Previews: PreviewProvider {
    static var previews: some View {
        StyledPickerView(selectedCountry: .constant("Select Country"), countries: [
            Country(name: "Select Country", flag: ""),
            Country(name: "USA", flag: "US"),
            Country(name: "Canada", flag: "CA"),
            Country(name: "Mexico", flag: "MX")
        ])
        .previewLayout(.sizeThatFits)
    }
}
