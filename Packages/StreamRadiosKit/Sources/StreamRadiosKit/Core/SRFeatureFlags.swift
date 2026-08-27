import Foundation
import Observation
import SwiftUI

/// Screens being rebuilt on the new stack. Each redesigned screen ships behind its own flag so
/// the old implementation stays reachable until the replacement is proven, then gets deleted.
public enum SRFeature: String, CaseIterable, Sendable {
    case newRadioList
    case newPodcastList
    case newEpisodeList
    case newPlayer
    case newSettings

    public var title: String {
        switch self {
        case .newRadioList: "Radio list (redesigned)"
        case .newPodcastList: "Podcast list (redesigned)"
        case .newEpisodeList: "Episode list (redesigned)"
        case .newPlayer: "Player (redesigned)"
        case .newSettings: "Settings (redesigned)"
        }
    }

    /// Shipped screens are on for everyone; the rest stay off until they land.
    var defaultValue: Bool {
        switch self {
        case .newRadioList: true
        case .newPodcastList, .newEpisodeList, .newPlayer, .newSettings: false
        }
    }
}

@MainActor
@Observable
public final class SRFeatureFlags {
    public static let shared = SRFeatureFlags()

    @ObservationIgnored private let defaults: UserDefaults
    private var overrides: [String: Bool]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [String: Bool] = [:]
        for feature in SRFeature.allCases {
            let key = Self.storageKey(for: feature)
            loaded[feature.rawValue] = defaults.object(forKey: key) as? Bool ?? feature.defaultValue
        }
        self.overrides = loaded
    }

    public func isEnabled(_ feature: SRFeature) -> Bool {
        overrides[feature.rawValue] ?? feature.defaultValue
    }

    public func setEnabled(_ isEnabled: Bool, for feature: SRFeature) {
        overrides[feature.rawValue] = isEnabled
        defaults.set(isEnabled, forKey: Self.storageKey(for: feature))
    }

    public func binding(for feature: SRFeature) -> Binding<Bool> {
        Binding(
            get: { self.isEnabled(feature) },
            set: { self.setEnabled($0, for: feature) }
        )
    }

    private static func storageKey(for feature: SRFeature) -> String {
        "sr.feature.\(feature.rawValue)"
    }
}
