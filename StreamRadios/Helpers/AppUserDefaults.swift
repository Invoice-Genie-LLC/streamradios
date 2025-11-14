import Foundation

/// Centralized UserDefaults manager that uses app group storage to prevent CFPreferences overflow
/// This ensures all app data is stored in the app group domain, not the standard domain
class AppUserDefaults {
    /// Shared instance that always uses app group UserDefaults
    static let shared = AppUserDefaults()
    
    /// The underlying UserDefaults instance (app group or standard as fallback)
    private let defaults: UserDefaults
    
    /// Whether app group is available
    let isUsingAppGroup: Bool
    
    private init() {
        if let appGroupDefaults = UserDefaults(suiteName: "group.streamradios") {
            self.defaults = appGroupDefaults
            self.isUsingAppGroup = true
            print("✅ AppUserDefaults: Using app group storage")
        } else {
            self.defaults = UserDefaults.standard
            self.isUsingAppGroup = false
            print("⚠️ AppUserDefaults: App group not available, using standard UserDefaults")
        }
    }
    
    // MARK: - String
    
    func string(forKey key: String) -> String? {
        return defaults.string(forKey: key)
    }
    
    func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
    
    // MARK: - Bool
    
    func bool(forKey key: String) -> Bool {
        return defaults.bool(forKey: key)
    }
    
    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
    
    // MARK: - Int
    
    func integer(forKey key: String) -> Int {
        return defaults.integer(forKey: key)
    }
    
    func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }
    
    // MARK: - Double/TimeInterval
    
    func double(forKey key: String) -> Double {
        return defaults.double(forKey: key)
    }
    
    func set(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: key)
    }
    
    // MARK: - Data
    
    func data(forKey key: String) -> Data? {
        return defaults.data(forKey: key)
    }
    
    func set(_ value: Data?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
    
    // MARK: - Object/Any
    
    func object(forKey key: String) -> Any? {
        return defaults.object(forKey: key)
    }
    
    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
    
    // MARK: - Remove
    
    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
    
    // MARK: - Dictionary Representation
    
    func dictionaryRepresentation() -> [String: Any] {
        return defaults.dictionaryRepresentation()
    }
}
