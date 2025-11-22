import SwiftUI

#if DISABLE_NANAKIT
    func nana_import(_: UnsafePointer<Int8>, _: Int) -> Int32 {
        return 1 // Success
    }
#else
    import NanaKit
#endif

/// Imports a list of files using `nana_import`.
///
/// - Parameters:
///   - files: Array of file path strings to import
///   - onProgress: Called on MainActor when a file is processed. Receives (completeCount, skippedCount).
///   - onError: Called on MainActor when an error occurs. Receives the error message.
/// - Returns: `true` if all files imported successfully, `false` if an error occurred.
@MainActor
func importFiles(
    _ files: [String],
    onProgress: @escaping (_ complete: Int, _ skipped: Int) -> Void,
    onError: @escaping (String) -> Void
) async -> Bool {
    var completeFiles = 0
    var skippedFiles = 0

    for fileURL in files {
        let res = fileURL.withCString { cString in
            nana_import(cString, numericCast(fileURL.utf8.count))
        }

        if res <= 0 {
            // -13 means file was skipped (not an error)
            if res != -13 {
                onError("Failed to import " + fileURL + " with error: \(res)")
                return false
            }
            skippedFiles += 1
        }

        completeFiles += 1
        onProgress(completeFiles, skippedFiles)
    }

    return true
}

struct Progress: View {
    var action: String
    var err: String
    var totalFiles: Int
    var skippedFiles: Int
    var completeFiles: Int

    var body: some View {
        if err != "" {
            Text("Failed to \(action) files:")
            ScrollView {
                Text(err)
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            .frame(maxHeight: 200)
        } else if totalFiles != (completeFiles + skippedFiles) {
            Text("\(action.capitalized)ing \(totalFiles) files...")
            ProgressView(value: Float(completeFiles), total: Float(totalFiles))
                .progressViewStyle(.linear)
                .padding(.horizontal)
        } else if totalFiles != 0 {
            Text("Successfully \(action)ed \(completeFiles) files")
            if skippedFiles != 0 {
                Text("Skipped \(action)ing \(completeFiles) files")
            }
        }
    }
}
