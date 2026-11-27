import SwiftUI
import AVFoundation
import CoreMedia
import UIKit

public struct VideoTrimmerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let draft: VideoTrimmerDraft

    @State private var player: AVPlayer
    @State private var isPlaying = false
    @State private var durationSeconds: Double = 1.0
    @State private var startFraction: Double = 0.0
    @State private var endFraction: Double = 1.0
    @State private var currentFraction: Double = 0.0
    @State private var filmstrip: [UIImage] = []
    @State private var isExtracting = false
    @State private var extractProgress: Double = 0

    @State private var timeObserverToken: Any?

    public init(draft: VideoTrimmerDraft) {
        self.draft = draft
        let item = AVPlayerItem(asset: draft.asset)
        _player = State(initialValue: AVPlayer(playerItem: item))
    }

    public var body: some View {
        ZStack {
            ZetaTheme.studioCanvas.ignoresSafeArea()

            VStack(spacing: 16) {
                headerBar

                ZStack {
                    PlayerLayerView(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onTapGesture {
                            togglePlayPause()
                        }

                    if !isPlaying {
                        Button {
                            togglePlayPause()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 20)

                trimmerSection
                    .padding(.horizontal, 20)

                Button {
                    startVideoStitch()
                } label: {
                    HStack(spacing: 8) {
                        if isExtracting {
                            ProgressView()
                                .tint(.white)
                            Text(String(format: NSLocalizedString("video_trimmer.extracting", comment: ""), Int(extractProgress * 100)))
                        } else {
                            Image(systemName: "rectangle.stack.badge.plus")
                            Text(NSLocalizedString("video_trimmer.stitch_button", comment: ""))
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ZetaTheme.accent, in: Capsule())
                }
                .disabled(isExtracting)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .navigationBarHidden(true)
        .preferredColorScheme(.dark)
        .task {
            await loadMetadataAndThumbnails()
        }
        .onAppear {
            attachTimeObserver()
        }
        .onDisappear {
            player.pause()
            if let token = timeObserverToken {
                player.removeTimeObserver(token)
                timeObserverToken = nil
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            Spacer()
            Text(NSLocalizedString("video_trimmer.title", comment: ""))
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var trimmerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text(formatTime(startFraction * durationSeconds))
                Spacer()
                Text(String(format: "%.1fs", max(0.2, (endFraction - startFraction) * durationSeconds)))
                    .foregroundStyle(ZetaTheme.accent)
                Spacer()
                Text(formatTime(endFraction * durationSeconds))
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))

            GeometryReader { geo in
                let w = max(60, geo.size.width)
                let startX = startFraction * w
                let endX = endFraction * w
                let playX = min(max(startX, currentFraction * w), endX)

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<max(1, filmstrip.count), id: \.self) { idx in
                            if idx < filmstrip.count {
                                Image(uiImage: filmstrip[idx])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: w / CGFloat(max(1, filmstrip.count)), height: 52)
                                    .clipped()
                            } else {
                                Color.white.opacity(0.08)
                            }
                        }
                    }
                    .frame(width: w, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    // Dim outside selection
                    HStack(spacing: 0) {
                        Color.black.opacity(0.58)
                            .frame(width: max(0, startX))
                        Spacer(minLength: 0)
                        Color.black.opacity(0.58)
                            .frame(width: max(0, w - endX))
                    }
                    .frame(width: w, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)

                    // Playhead
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 2.5, height: 58)
                        .offset(x: playX - 1.25)

                    // Active Trim Border
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(ZetaTheme.accent, lineWidth: 2.5)
                        .frame(width: max(24, endX - startX), height: 52)
                        .offset(x: startX)

                    // Leading Handle
                    trimHandle()
                        .offset(x: max(0, startX - 10))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    let next = min(max(0, val.location.x / w), endFraction - 0.05)
                                    startFraction = next
                                    seekTo(fraction: next)
                                }
                        )

                    // Trailing Handle
                    trimHandle()
                        .offset(x: min(w - 20, endX - 10))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    let next = max(min(1.0, val.location.x / w), startFraction + 0.05)
                                    endFraction = next
                                    seekTo(fraction: next)
                                }
                        )
                }
            }
            .frame(height: 56)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func trimHandle() -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(ZetaTheme.accent)
            .frame(width: 20, height: 56)
            .overlay(
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: 22)
            )
            .contentShape(Rectangle().inset(by: -10))
    }

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentFraction >= endFraction - 0.01 || currentFraction < startFraction {
                seekTo(fraction: startFraction)
            }
            player.play()
            isPlaying = true
        }
    }

    private func seekTo(fraction: Double) {
        let t = CMTime(seconds: fraction * durationSeconds, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentFraction = fraction
    }

    private func attachTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard durationSeconds > 0 else { return }
            let frac = CMTimeGetSeconds(time) / durationSeconds
            currentFraction = frac
            if isPlaying && frac >= endFraction {
                player.pause()
                isPlaying = false
                seekTo(fraction: startFraction)
            }
        }
    }

    private func loadMetadataAndThumbnails() async {
        guard let dur = try? await draft.asset.load(.duration) else { return }
        let sec = max(0.2, CMTimeGetSeconds(dur))
        await MainActor.run {
            self.durationSeconds = sec
        }

        let generator = AVAssetImageGenerator(asset: draft.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 140, height: 140)

        let count = 10
        var thumbs: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: sec * (Double(i) / Double(count)), preferredTimescale: 600)
            if let (cg, _) = try? await generator.image(at: t) {
                thumbs.append(UIImage(cgImage: cg))
            }
        }
        await MainActor.run {
            self.filmstrip = thumbs
        }
    }

    private func startVideoStitch() {
        player.pause()
        isPlaying = false
        isExtracting = true
        extractProgress = 0

        let startTime = CMTime(seconds: startFraction * durationSeconds, preferredTimescale: 600)
        let endTime = CMTime(seconds: endFraction * durationSeconds, preferredTimescale: 600)
        let range = CMTimeRange(start: startTime, end: endTime)

        Task {
            do {
                let result = try await VideoStitcher.extractStitchResult(
                    from: draft.asset,
                    timeRange: range
                ) { prog in
                    Task { @MainActor in
                        self.extractProgress = prog
                    }
                }

                await MainActor.run {
                    isExtracting = false
                    guard !result.images.isEmpty else {
                        appState.errorAlertMessage = NSLocalizedString("video_trimmer.error.no_frames", comment: "")
                        return
                    }
                    let assets = draft.sourcePhotoAsset.map { [$0] } ?? []
                    let editorDraft = StitchDraft(
                        mode: .longStitch,
                        images: result.images,
                        sourceAssets: assets,
                        sourceRecordingID: draft.sourceRecordingID,
                        initialSeams: result.seams
                    )
                    appState.navigationPath.append(.editor(editorDraft))
                }
            } catch {
                await MainActor.run {
                    isExtracting = false
                    appState.errorAlertMessage = error.localizedDescription
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerContainerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
