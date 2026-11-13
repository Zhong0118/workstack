import Foundation

private let stringsBundle: Bundle =
    Bundle.main.url(forResource: "workstack_WorkbenchApp", withExtension: "bundle")
    .flatMap(Bundle.init(url:)) ?? Bundle.module

@MainActor
func tr(_ key: String, table: String = "App") -> String {
    stringsBundle.localizedString(forKey: key, value: nil, table: table)
}
