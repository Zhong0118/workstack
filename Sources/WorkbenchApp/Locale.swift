import SwiftUI

@MainActor
private let stringsBundle: Bundle =
    Bundle.main.url(forResource: "WindowWorkbench_WorkbenchApp", withExtension: "bundle")
    .flatMap(Bundle.init(url:)) ?? Bundle.module

@MainActor var appLanguage = "system"

@MainActor
func tr(_ key: String, table: String = "App") -> String {
    let preference = appLanguage
    let language = preference == "system" ? Bundle.preferredLocalizations(from: ["en", "zh-Hans"]).first ?? "en" : preference
    let bundle =
        stringsBundle.path(forResource: language.lowercased(), ofType: "lproj").flatMap(Bundle.init(path:)) ?? stringsBundle
    return bundle.localizedString(forKey: key, value: key, table: table)
}
