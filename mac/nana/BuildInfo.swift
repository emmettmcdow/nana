import Foundation

enum BuildInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let gitSHA = "bf3935a"
    static var label: String { "\(version)+\(gitSHA)" }
}
