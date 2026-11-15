import Foundation

private let stringsBundle: Bundle =
    Bundle.main.url(forResource: "workstack_WorkbenchApp", withExtension: "bundle")
    .flatMap(Bundle.init(url:)) ?? Bundle.module

/// A bundle lookup matches preferred languages on every call. View bodies ask for the same
/// few hundred strings on each refresh, and the answers never change while the app runs.
@MainActor private var translations: [String: String] = [:]

@MainActor
func tr(_ key: String, table: String = "App") -> String {
    let slot = table + "\u{1F}" + key
    if let known = translations[slot] { return known }
    let value = stringsBundle.localizedString(forKey: key, value: nil, table: table)
    translations[slot] = value
    return value
}
