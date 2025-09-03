//
//  Country.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/9/24.
//

import Foundation

struct Country: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var flag: String
    
    var displayFlag: String {
        return flag.isEmpty ? "flag.slash.fill" : flag
    }
    
    /// Get the ISO country code for API calls
    var apiCountryCode: String {
        // For most countries, the flag code is the same as the ISO code
        // Handle special cases where the display name differs from the API expectation
        switch name {
        case "United States":
            return "US"
        case "United Kingdom":
            return "GB"
        case "Russia":
            return "RU"
        case "South Korea":
            return "KR"
        case "North Korea":
            return "KP"
        case "Czech Republic":
            return "CZ"
        case "Select Country", "Unknown Region":
            return ""
        default:
            // For most countries, use the flag code as it's already the ISO code
            return flag.uppercased()
        }
    }
    
    /// Check if this country supports radio station lookup
    var supportsRadioLookup: Bool {
        return !apiCountryCode.isEmpty && name != "Select Country" && name != "Unknown Region"
    }
}

extension Country {
    /// Get a comprehensive list of all countries with their proper API codes
    static func getAllCountriesWithAPICodes() -> [Country] {
        return [
            Country(name: "Select Country", flag: ""),
            Country(name: "Afghanistan", flag: "AF"),
            Country(name: "Albania", flag: "AL"),
            Country(name: "Algeria", flag: "DZ"),
            Country(name: "American Samoa", flag: "AS"),
            Country(name: "Andorra", flag: "AD"),
            Country(name: "Angola", flag: "AO"),
            Country(name: "Anguilla", flag: "AI"),
            Country(name: "Antigua & Barbuda", flag: "AG"),
            Country(name: "Argentina", flag: "AR"),
            Country(name: "Armenia", flag: "AM"),
            Country(name: "Aruba", flag: "AW"),
            Country(name: "Australia", flag: "AU"),
            Country(name: "Austria", flag: "AT"),
            Country(name: "Azerbaijan", flag: "AZ"),
            Country(name: "Bahamas", flag: "BS"),
            Country(name: "Bahrain", flag: "BH"),
            Country(name: "Bangladesh", flag: "BD"),
            Country(name: "Barbados", flag: "BB"),
            Country(name: "Belarus", flag: "BY"),
            Country(name: "Belgium", flag: "BE"),
            Country(name: "Belize", flag: "BZ"),
            Country(name: "Benin", flag: "BJ"),
            Country(name: "Bermuda", flag: "BM"),
            Country(name: "Bhutan", flag: "BT"),
            Country(name: "Bolivia", flag: "BO"),
            Country(name: "Bosnia & Herzegovina", flag: "BA"),
            Country(name: "Botswana", flag: "BW"),
            Country(name: "Brazil", flag: "BR"),
            Country(name: "British Virgin Islands", flag: "VG"),
            Country(name: "Brunei", flag: "BN"),
            Country(name: "Bulgaria", flag: "BG"),
            Country(name: "Burkina Faso", flag: "BF"),
            Country(name: "Burundi", flag: "BI"),
            Country(name: "Cambodia", flag: "KH"),
            Country(name: "Cameroon", flag: "CM"),
            Country(name: "Canada", flag: "CA"),
            Country(name: "Cape Verde", flag: "CV"),
            Country(name: "Cayman Islands", flag: "KY"),
            Country(name: "Central African Republic", flag: "CF"),
            Country(name: "Chad", flag: "TD"),
            Country(name: "Chile", flag: "CL"),
            Country(name: "China", flag: "CN"),
            Country(name: "Christmas Island", flag: "CX"),
            Country(name: "Cocos (Keeling) Islands", flag: "CC"),
            Country(name: "Colombia", flag: "CO"),
            Country(name: "Comoros", flag: "KM"),
            Country(name: "Congo - Brazzaville", flag: "CG"),
            Country(name: "Congo - Kinshasa", flag: "CD"),
            Country(name: "Cook Islands", flag: "CK"),
            Country(name: "Costa Rica", flag: "CR"),
            Country(name: "Croatia", flag: "HR"),
            Country(name: "Cuba", flag: "CU"),
            Country(name: "Curaçao", flag: "CW"),
            Country(name: "Cyprus", flag: "CY"),
            Country(name: "Czech Republic", flag: "CZ"),
            Country(name: "Côte d'Ivoire", flag: "CI"),
            Country(name: "Denmark", flag: "DK"),
            Country(name: "Djibouti", flag: "DJ"),
            Country(name: "Dominica", flag: "DM"),
            Country(name: "Dominican Republic", flag: "DO"),
            Country(name: "Ecuador", flag: "EC"),
            Country(name: "Egypt", flag: "EG"),
            Country(name: "El Salvador", flag: "SV"),

            Country(name: "Equatorial Guinea", flag: "GQ"),
            Country(name: "Eritrea", flag: "ER"),
            Country(name: "Estonia", flag: "EE"),
            Country(name: "Ethiopia", flag: "ET"),
            Country(name: "Falkland Islands", flag: "FK"),
            Country(name: "Faroe Islands", flag: "FO"),
            Country(name: "Fiji", flag: "FJ"),
            Country(name: "Finland", flag: "FI"),
            Country(name: "France", flag: "FR"),
            Country(name: "French Guiana", flag: "GF"),
            Country(name: "French Polynesia", flag: "PF"),
            Country(name: "Gabon", flag: "GA"),
            Country(name: "Gambia", flag: "GM"),
            Country(name: "Georgia", flag: "GE"),
            Country(name: "Germany", flag: "DE"),
            Country(name: "Ghana", flag: "GH"),
            Country(name: "Gibraltar", flag: "GI"),
            Country(name: "Greece", flag: "GR"),
            Country(name: "Greenland", flag: "GL"),
            Country(name: "Grenada", flag: "GD"),
            Country(name: "Guadeloupe", flag: "GP"),
            Country(name: "Guam", flag: "GU"),
            Country(name: "Guatemala", flag: "GT"),
            Country(name: "Guernsey", flag: "GG"),
            Country(name: "Guinea", flag: "GN"),
            Country(name: "Guinea-Bissau", flag: "GW"),
            Country(name: "Guyana", flag: "GY"),
            Country(name: "Haiti", flag: "HT"),
            Country(name: "Honduras", flag: "HN"),
            Country(name: "Hong Kong", flag: "HK"),
            Country(name: "Hungary", flag: "HU"),
            Country(name: "Iceland", flag: "IS"),
            Country(name: "India", flag: "IN"),
            Country(name: "Indonesia", flag: "ID"),
            Country(name: "Iran", flag: "IR"),
            Country(name: "Iraq", flag: "IQ"),
            Country(name: "Ireland", flag: "IE"),
            Country(name: "Isle of Man", flag: "IM"),
            Country(name: "Israel", flag: "IL"),
            Country(name: "Italy", flag: "IT"),
            Country(name: "Jamaica", flag: "JM"),
            Country(name: "Japan", flag: "JP"),
            Country(name: "Jersey", flag: "JE"),
            Country(name: "Jordan", flag: "JO"),
            Country(name: "Kazakhstan", flag: "KZ"),
            Country(name: "Kenya", flag: "KE"),
            Country(name: "Kiribati", flag: "KI"),
            Country(name: "Kosovo", flag: "XK"),
            Country(name: "Kuwait", flag: "KW"),
            Country(name: "Kyrgyzstan", flag: "KG"),
            Country(name: "Laos", flag: "LA"),
            Country(name: "Latvia", flag: "LV"),
            Country(name: "Lebanon", flag: "LB"),
            Country(name: "Lesotho", flag: "LS"),
            Country(name: "Liberia", flag: "LR"),
            Country(name: "Libya", flag: "LY"),
            Country(name: "Liechtenstein", flag: "LI"),
            Country(name: "Lithuania", flag: "LT"),
            Country(name: "Luxembourg", flag: "LU"),
            Country(name: "Macau", flag: "MO"),
            Country(name: "Macedonia", flag: "MK"),
            Country(name: "Madagascar", flag: "MG"),
            Country(name: "Malawi", flag: "MW"),
            Country(name: "Malaysia", flag: "MY"),
            Country(name: "Maldives", flag: "MV"),
            Country(name: "Mali", flag: "ML"),
            Country(name: "Malta", flag: "MT"),
            Country(name: "Marshall Islands", flag: "MH"),
            Country(name: "Martinique", flag: "MQ"),
            Country(name: "Mauritania", flag: "MR"),
            Country(name: "Mauritius", flag: "MU"),
            Country(name: "Mayotte", flag: "YT"),
            Country(name: "Mexico", flag: "MX"),
            Country(name: "Micronesia", flag: "FM"),
            Country(name: "Moldova", flag: "MD"),
            Country(name: "Monaco", flag: "MC"),
            Country(name: "Mongolia", flag: "MN"),
            Country(name: "Montenegro", flag: "ME"),
            Country(name: "Montserrat", flag: "MS"),
            Country(name: "Morocco", flag: "MA"),
            Country(name: "Mozambique", flag: "MZ"),
            Country(name: "Myanmar", flag: "MM"),
            Country(name: "Namibia", flag: "NA"),
            Country(name: "Nauru", flag: "NR"),
            Country(name: "Nepal", flag: "NP"),
            Country(name: "Netherlands", flag: "NL"),
            Country(name: "New Caledonia", flag: "NC"),
            Country(name: "New Zealand", flag: "NZ"),
            Country(name: "Nicaragua", flag: "NI"),
            Country(name: "Niger", flag: "NE"),
            Country(name: "Nigeria", flag: "NG"),
            Country(name: "Niue", flag: "NU"),
            Country(name: "Norfolk Island", flag: "NF"),
            Country(name: "North Korea", flag: "KP"),

            Country(name: "Northern Mariana Islands", flag: "MP"),
            Country(name: "Norway", flag: "NO"),
            Country(name: "Oman", flag: "OM"),
            Country(name: "Pakistan", flag: "PK"),
            Country(name: "Palau", flag: "PW"),
            Country(name: "Palestinian Territories", flag: "PS"),
            Country(name: "Panama", flag: "PA"),
            Country(name: "Papua New Guinea", flag: "PG"),
            Country(name: "Paraguay", flag: "PY"),
            Country(name: "Peru", flag: "PE"),
            Country(name: "Philippines", flag: "PH"),
            Country(name: "Pitcairn Islands", flag: "PN"),
            Country(name: "Poland", flag: "PL"),
            Country(name: "Portugal", flag: "PT"),
            Country(name: "Puerto Rico", flag: "PR"),
            Country(name: "Qatar", flag: "QA"),
            Country(name: "Romania", flag: "RO"),
            Country(name: "Russia", flag: "RU"),
            Country(name: "Rwanda", flag: "RW"),
            Country(name: "Réunion", flag: "RE"),
            Country(name: "Saint Barthélemy", flag: "BL"),
            Country(name: "Saint Helena", flag: "SH"),
            Country(name: "Saint Kitts & Nevis", flag: "KN"),
            Country(name: "Saint Lucia", flag: "LC"),
            Country(name: "Saint Martin", flag: "MF"),
            Country(name: "Saint Pierre & Miquelon", flag: "PM"),
            Country(name: "Saint Vincent & Grenadines", flag: "VC"),
            Country(name: "Samoa", flag: "WS"),
            Country(name: "San Marino", flag: "SM"),
            Country(name: "Saudi Arabia", flag: "SA"),

            Country(name: "Senegal", flag: "SN"),
            Country(name: "Serbia", flag: "RS"),
            Country(name: "Seychelles", flag: "SC"),
            Country(name: "Sierra Leone", flag: "SL"),
            Country(name: "Singapore", flag: "SG"),
            Country(name: "Sint Maarten", flag: "SX"),
            Country(name: "Slovakia", flag: "SK"),
            Country(name: "Slovenia", flag: "SI"),
            Country(name: "Solomon Islands", flag: "SB"),
            Country(name: "Somalia", flag: "SO"),
            Country(name: "South Africa", flag: "ZA"),
            Country(name: "South Korea", flag: "KR"),
            Country(name: "South Sudan", flag: "SS"),
            Country(name: "Spain", flag: "ES"),
            Country(name: "Sri Lanka", flag: "LK"),
            Country(name: "Sudan", flag: "SD"),
            Country(name: "Suriname", flag: "SR"),
            Country(name: "Swaziland", flag: "SZ"),
            Country(name: "Sweden", flag: "SE"),
            Country(name: "Switzerland", flag: "CH"),
            Country(name: "Syria", flag: "SY"),
            Country(name: "São Tomé & Príncipe", flag: "ST"),
            Country(name: "Taiwan", flag: "TW"),
            Country(name: "Tajikistan", flag: "TJ"),
            Country(name: "Tanzania", flag: "TZ"),
            Country(name: "Thailand", flag: "TH"),
            Country(name: "Timor-Leste", flag: "TL"),
            Country(name: "Togo", flag: "TG"),
            Country(name: "Tokelau", flag: "TK"),
            Country(name: "Tonga", flag: "TO"),
            Country(name: "Trinidad & Tobago", flag: "TT"),
            Country(name: "Tunisia", flag: "TN"),
            Country(name: "Turkey", flag: "TR"),
            Country(name: "Turkmenistan", flag: "TM"),
            Country(name: "Turks & Caicos Islands", flag: "TC"),
            Country(name: "Tuvalu", flag: "TV"),
            Country(name: "Uganda", flag: "UG"),
            Country(name: "United Kingdom", flag: "GB"),
            Country(name: "Ukraine", flag: "UA"),
            Country(name: "United Arab Emirates", flag: "AE"),
            Country(name: "United States", flag: "US"),
            Country(name: "Uruguay", flag: "UY"),
            Country(name: "U.S. Virgin Islands", flag: "VI"),
            Country(name: "Uzbekistan", flag: "UZ"),
            Country(name: "Vanuatu", flag: "VU"),
            Country(name: "Vatican City", flag: "VA"),
            Country(name: "Venezuela", flag: "VE"),
            Country(name: "Vietnam", flag: "VN"),

            Country(name: "Wallis & Futuna", flag: "WF"),
            Country(name: "Yemen", flag: "YE"),
            Country(name: "Zambia", flag: "ZM"),
            Country(name: "Zimbabwe", flag: "ZW"),
            Country(name: "Åland Islands", flag: "AX"),
            Country(name: "Unknown Region", flag: "")
        ]
    }
}
