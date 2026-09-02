import SwiftUI

struct FramingGuidesView: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let landscape = fittedRect(in: size, aspect: 16.0 / 9.0)
            let portrait = fittedRect(in: size, aspect: 9.0 / 16.0)

            ZStack {
                Rectangle()
                    .stroke(.white.opacity(0.35), lineWidth: 1)
                    .frame(width: landscape.width, height: landscape.height)
                    .position(x: landscape.midX, y: landscape.midY)

                Rectangle()
                    .stroke(.yellow.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [8, 8]))
                    .frame(width: portrait.width, height: portrait.height)
                    .position(x: portrait.midX, y: portrait.midY)

                VStack {
                    Text("9:16")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: Capsule())
                    Spacer()
                }
                .frame(width: portrait.width, height: portrait.height)
                .position(x: portrait.midX, y: portrait.midY)
            }
            .allowsHitTesting(false)
        }
    }

    private func fittedRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        let containerAspect = size.width / max(size.height, 1)
        let width: CGFloat
        let height: CGFloat

        if containerAspect > aspect {
            height = size.height
            width = height * aspect
        } else {
            width = size.width
            height = width / aspect
        }

        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }
}
