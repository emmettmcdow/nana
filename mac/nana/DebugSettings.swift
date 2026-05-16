import Foundation

class DebugSettings: ObservableObject {
    @Published var showBoundingBoxes: Bool = false
    @Published var hideMarkdownChars: Bool = true
    @Published var fps: Double = 0.0

    private var frameCount: Int = 0
    private var lastFPSUpdate: Date = .now

    func tick(now: Date) {
        frameCount += 1
        let elapsed = now.timeIntervalSince(lastFPSUpdate)
        guard elapsed >= 0.5 else { return }
        fps = Double(frameCount) / elapsed
        frameCount = 0
        lastFPSUpdate = now
    }
}
