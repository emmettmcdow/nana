import Foundation

enum BuildInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let gitSHA = "ed5e3cb"
    static var label: String { "\(version)+\(gitSHA)" }
}
