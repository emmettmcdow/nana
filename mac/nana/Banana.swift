import Foundation
import SwiftUI

// generated from banana.svg using https://svg-to-swiftui.quassum.com/
// normalized to fill bounding box (original x: 0.41281-0.55943, y: 0.45546-0.56144)
struct Banana: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.size.width
        let height = rect.size.height
        path.move(to: CGPoint(x: 0.0 * width, y: 0.45687 * height))
        path.addCurve(to: CGPoint(x: 0.19629 * width, y: 0.33265 * height), control1: CGPoint(x: 0.0 * width, y: 0.45687 * height), control2: CGPoint(x: 0.02469 * width, y: 0.23985 * height))
        path.addCurve(to: CGPoint(x: 0.53830 * width, y: 0.45970 * height), control1: CGPoint(x: 0.36789 * width, y: 0.42546 * height), control2: CGPoint(x: 0.53830 * width, y: 0.45970 * height))
        path.addCurve(to: CGPoint(x: 0.72983 * width, y: 0.38734 * height), control1: CGPoint(x: 0.53830 * width, y: 0.45970 * height), control2: CGPoint(x: 0.62626 * width, y: 0.48863 * height))
        path.addCurve(to: CGPoint(x: 0.85445 * width, y: 0.26019 * height), control1: CGPoint(x: 0.83340 * width, y: 0.28605 * height), control2: CGPoint(x: 0.85445 * width, y: 0.26019 * height))
        path.addCurve(to: CGPoint(x: 0.90732 * width, y: 0.04916 * height), control1: CGPoint(x: 0.85445 * width, y: 0.26019 * height), control2: CGPoint(x: 0.92374 * width, y: 0.09831 * height))
        path.addCurve(to: CGPoint(x: 0.94027 * width, y: 0.01162 * height), control1: CGPoint(x: 0.90091 * width, y: 0.0 * height), control2: CGPoint(x: 0.94027 * width, y: 0.01162 * height))
        path.addCurve(to: CGPoint(x: 0.96142 * width, y: 0.17924 * height), control1: CGPoint(x: 0.94027 * width, y: 0.01162 * height), control2: CGPoint(x: 0.99132 * width, y: 0.13588 * height))
        path.addCurve(to: CGPoint(x: 0.91064 * width, y: 0.36821 * height), control1: CGPoint(x: 0.93151 * width, y: 0.22260 * height), control2: CGPoint(x: 0.91064 * width, y: 0.36821 * height))
        path.addCurve(to: CGPoint(x: 0.78330 * width, y: 0.80879 * height), control1: CGPoint(x: 0.91064 * width, y: 0.36821 * height), control2: CGPoint(x: 0.93971 * width, y: 0.62252 * height))
        path.addCurve(to: CGPoint(x: 0.0 * width, y: 0.45687 * height), control1: CGPoint(x: 0.62690 * width, y: 0.99506 * height), control2: CGPoint(x: 0.00730 * width, y: 0.82946 * height))
        path.closeSubpath()
        return path
    }
}

struct LoadingBanana: View {
    var msg: String = "loading"
    var x: Double = 0.5
    var y: Double = 0.6

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    @State private var rotation: Angle = .degrees(-45)
    @State private var dotCount: Int = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        let anchorPoint = UnitPoint(x: x, y: y)
        HStack {
            Banana()
                .fill(palette.foreground.shadow(.inner(radius: 3, y: 3)))
                .frame(width: 30, height: 15)
                .rotationEffect(rotation, anchor: anchorPoint)
                .onAppear {
                    withAnimation(.bouncy
                        .speed(0.75)
                        .repeatForever(autoreverses: false))
                    {
                        rotation = rotation + Angle(degrees: 360)
                    }
                }
            Text(msg + String(repeating: ".", count: dotCount))
                .onReceive(timer) { _ in
                    dotCount = (dotCount + 1) % 4 // Cycle through 0, 1, 2, 3 dots
                }
                .font(.caption)
                .foregroundStyle(palette.foreground)
                .fontWeight(.light)
                .italic()
        }
        .padding(.all, 15)
    }
}
