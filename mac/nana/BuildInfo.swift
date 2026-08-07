import Foundation

enum BuildInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let gitSHA = "fe7c1b6"
    static var label: String { "\(version)+\(gitSHA)" }
}
