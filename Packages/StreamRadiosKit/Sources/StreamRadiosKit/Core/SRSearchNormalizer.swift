import Foundation

/// Builds the normalized text that station/episode search predicates run against.
///
/// Searching with `CONTAINS[cd]` makes SQLite case- and diacritic-fold every row on every
/// keystroke. Folding once at write time into a dedicated column lets the query use a plain
/// `CONTAINS`, which is dramatically cheaper — and lets prefix matches use a real index.
public enum SRSearchNormalizer {
    /// Folds case and diacritics, strips punctuation, collapses whitespace.
    /// "Rádio Comercial (FM)" -> "radio comercial fm"
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )

        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }

        return String(cleaned)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Combines the fields a station is searchable by into one indexed column.
    /// Padded with spaces so a `" \(term)"` predicate can express "matches a word start".
    public static func stationIndexText(name: String?, country: String?) -> String {
        let parts = [name, country]
            .compactMap { $0 }
            .map(normalize)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        return " " + parts.joined(separator: " ") + " "
    }

    /// Normalizes what the user typed so it can be compared against the stored column.
    public static func query(_ text: String) -> String {
        normalize(text)
    }
}
