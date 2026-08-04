import Foundation

enum BuildInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let gitSHA = "13e0661"
    static var label: String { "\(version)+\(gitSHA)" }
}
