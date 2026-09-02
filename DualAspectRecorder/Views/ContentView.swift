import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CameraPreviewView(session: viewModel.captureSession)
                .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            FramingGuidesView()
                .padding(.horizontal, 18)
                .padding(.vertical, 80)

            VStack {
                topBar
                Spacer()
                statusArea
                controls
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .task(id: scenePhase) {
            await viewModel.handleScenePhase(scenePhase)
        }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dual Aspect")
                    .font(.headline.weight(.semibold))
                Text(viewModel.qualityLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)

            Spacer()

            Button {
                Task { await viewModel.switchCamera() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(!viewModel.canSwitchCamera)
            .foregroundStyle(.white)
            .accessibilityLabel("Switch camera")
        }
    }

    private var statusArea: some View {
        VStack(spacing: 10) {
            if viewModel.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.elapsedTime)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.35), in: Capsule())
            }

            if viewModel.exportProgress > 0, viewModel.exportProgress < 1 {
                VStack(spacing: 8) {
                    ProgressView(value: viewModel.exportProgress)
                        .tint(.white)
                    Text(viewModel.statusText)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else if !viewModel.statusText.isEmpty {
                Text(viewModel.statusText)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .animation(.snappy, value: viewModel.statusText)
        .animation(.snappy, value: viewModel.exportProgress)
    }

    private var controls: some View {
        HStack {
            Button {
                Task { await viewModel.toggleRecording() }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.85), lineWidth: 4)
                        .frame(width: 78, height: 78)
                    if viewModel.isRecording {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.red)
                            .frame(width: 32, height: 32)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 62, height: 62)
                    }
                }
            }
            .disabled(!viewModel.canRecord)
            .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Start recording")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
    }
}
