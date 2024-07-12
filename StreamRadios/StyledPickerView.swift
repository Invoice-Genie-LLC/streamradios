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
        Menu {
            ForEach(countries) { country in
                Button(action: {
                    selectedCountry = country.name
                }) {
                    CountryPickerRow(country: country)
                }
            }
        } label: {
            HStack {
                if let selectedCountryFlag = countries.first(where: { $0.name == selectedCountry })?.flag, !selectedCountryFlag.isEmpty {
                    Image(selectedCountryFlag)
                        .resizable()
                        .frame(width: 24, height: 18)
                }
                Text(selectedCountry.isEmpty ? "Select Country" : selectedCountry)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.down")
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .padding(.horizontal)
    }
}

struct CountryPickerRow: View {
    let country: Country
    
    var body: some View {
        HStack(spacing: 10) {
            if country.flag.isEmpty {
                Image(systemName: "flag.slash.fill")
                    .resizable()
                    .frame(width: 24, height: 18)
                    .foregroundColor(.gray)
            } else {
                Image(country.flag)
                    .resizable()
                    .frame(width: 24, height: 18)
            }
            
            Text(country.name)
                .font(.headline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.vertical, 4)
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
        .padding()
    }
}

