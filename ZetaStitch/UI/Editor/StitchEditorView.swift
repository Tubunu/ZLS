import SwiftUI
import UIKit

public struct StitchEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: StitchEditorViewModel

    @State private var dragBaseValue: Int = 0
    @State private var isDraggingSeam = false

    public init(draft: StitchDraft) {
        _viewModel = StateObject(wrappedValue: StitchEditorViewModel(draft: draft))
    }

    public var body: some View {
        ZStack {
            ZetaTheme.studioCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topToolbar

                ZStack {
                    if viewModel.isAnalyzing {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                                .controlSize(.large)
                            Text(NSLocalizedString("editor.analyzing", comment: ""))
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    } else {
                        canvasArea
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 10) {
                Spacer()
                if viewModel.toolMode == .seamEdit, let activeIdx = viewModel.activeSeamIndex, activeIdx < viewModel.seams.count {
                    seamMicroAdjustBar(index: activeIdx)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if viewModel.toolMode == .crop {
                    cropActionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomGlassDock
            }
            .padding(.bottom, 10)
        }
        .navigationBarHidden(true)
        .preferredColorScheme(.dark)
        .task {
            await viewModel.analyzeIfNeeded(autoTrimStaticBars: appState.autoTrimStaticBars)
        }
    }

    // MARK: - Top Bar

    private var topToolbar: some View {
        HStack(spacing: 10) {
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

            VStack(spacing: 2) {
                Menu {
                    ForEach(StitchMode.allCases) { m in
                        Button {
                            Task {
                                await viewModel.switchMode(to: m, autoTrimStaticBars: appState.autoTrimStaticBars)
                            }
                        } label: {
                            HStack {
                                Text(modeTitle(m))
                                if viewModel.mode == m {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(modeTitle(viewModel.mode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                let size = viewModel.outputPixelSize
                HStack(spacing: 6) {
                    Text("\(Int(size.width)) × \(Int(size.height)) px")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))

                    if viewModel.unmatchedCount > 0 {
                        Text("· \(viewModel.unmatchedCount) \(NSLocalizedString("editor.unmatched_short", comment: ""))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(ZetaTheme.warning)
                    }
                }
            }

            Spacer()

            Button {
                performExport()
            } label: {
                Text(NSLocalizedString("common.done", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(ZetaTheme.accent, in: Capsule())
            }
            .disabled(viewModel.isAnalyzing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Canvas Area

    private var canvasArea: some View {
        GeometryReader { outerGeo in
            let maxContentW = max(120, outerGeo.size.width - 36)
            let maxContentH = max(160, outerGeo.size.height - 150)

            if viewModel.mode == .horizontal {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: CGFloat(viewModel.spacing) * 0.25) {
                        ForEach(0..<viewModel.draft.images.count, id: \.self) { idx in
                            let sliceImg = viewModel.croppedUIImage(for: idx)
                            let aspect = sliceImg.size.width / max(1, sliceImg.size.height)
                            let dispH = min(maxContentH, 420)
                            let dispW = dispH * aspect
                            let pixelScale = sliceImg.size.height / max(1, dispH)

                            Image(uiImage: sliceImg)
                                .resizable()
                                .frame(width: dispW, height: dispH)

                            if idx < viewModel.seams.count && viewModel.toolMode == .seamEdit {
                                HorizontalSeamHandle(
                                    seam: viewModel.seams[idx],
                                    isActive: viewModel.activeSeamIndex == idx,
                                    height: dispH
                                )
                                .onTapGesture {
                                    withAnimation(.snappy) {
                                        viewModel.activeSeamIndex = idx
                                    }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 2)
                                        .onChanged { val in
                                            if !isDraggingSeam {
                                                isDraggingSeam = true
                                                viewModel.activeSeamIndex = idx
                                                let cur = viewModel.seamTrimTarget == .topOfLower
                                                    ? viewModel.seams[idx].botCropTop
                                                    : viewModel.seams[idx].topCropBottom
                                                dragBaseValue = cur
                                            }
                                            let deltaPx = Int((-val.translation.width * pixelScale).rounded())
                                            let current = viewModel.seamTrimTarget == .topOfLower
                                                ? viewModel.seams[idx].botCropTop
                                                : viewModel.seams[idx].topCropBottom
                                            let step = (dragBaseValue + deltaPx) - current
                                            if step != 0 {
                                                viewModel.adjustSeam(at: idx, target: viewModel.seamTrimTarget, deltaPixels: step)
                                            }
                                        }
                                        .onEnded { _ in
                                            isDraggingSeam = false
                                        }
                                )
                            }
                        }
                    }
                    .overlay {
                        if viewModel.toolMode == .crop {
                            CropBoxOverlay(crop: $viewModel.crop)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
            } else {
                let targetDispW = min(maxContentW, 460)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: viewModel.mode == .vertical ? CGFloat(viewModel.spacing) * 0.35 : 0) {
                        ForEach(0..<viewModel.draft.images.count, id: \.self) { idx in
                            let sliceImg = viewModel.croppedUIImage(for: idx)
                            let aspect = sliceImg.size.height / max(1, sliceImg.size.width)
                            let dispH = max(4, targetDispW * aspect)
                            let pixelScale = sliceImg.size.width / max(1, targetDispW)

                            ZStack(alignment: .bottom) {
                                Image(uiImage: sliceImg)
                                    .resizable()
                                    .frame(width: targetDispW, height: dispH)

                                if idx < viewModel.seams.count && viewModel.toolMode == .seamEdit {
                                    VerticalSeamHandle(
                                        seam: viewModel.seams[idx],
                                        isActive: viewModel.activeSeamIndex == idx,
                                        width: targetDispW
                                    )
                                    .offset(y: 16)
                                    .zIndex(10)
                                    .onTapGesture {
                                        withAnimation(.snappy) {
                                            viewModel.activeSeamIndex = idx
                                        }
                                    }
                                    .gesture(
                                        DragGesture(minimumDistance: 2)
                                            .onChanged { val in
                                                if !isDraggingSeam {
                                                    isDraggingSeam = true
                                                    viewModel.activeSeamIndex = idx
                                                    let cur = viewModel.seamTrimTarget == .topOfLower
                                                        ? viewModel.seams[idx].botCropTop
                                                        : viewModel.seams[idx].topCropBottom
                                                    dragBaseValue = cur
                                                }
                                                let deltaPx = Int((-val.translation.height * pixelScale).rounded())
                                                let current = viewModel.seamTrimTarget == .topOfLower
                                                    ? viewModel.seams[idx].botCropTop
                                                    : viewModel.seams[idx].topCropBottom
                                                let step = (dragBaseValue + deltaPx) - current
                                                if step != 0 {
                                                    viewModel.adjustSeam(at: idx, target: viewModel.seamTrimTarget, deltaPixels: step)
                                                }
                                            }
                                            .onEnded { _ in
                                                isDraggingSeam = false
                                            }
                                    )
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        if viewModel.toolMode == .crop {
                            CropBoxOverlay(crop: $viewModel.crop)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 160)
                }
            }
        }
    }

    // MARK: - Micro Adjust Bars

    private func seamMicroAdjustBar(index: Int) -> some View {
        let seam = viewModel.seams[index]
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(String(format: NSLocalizedString("editor.seam_label", comment: ""), index + 1, index + 2))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Picker("", selection: $viewModel.seamTrimTarget) {
                    Text(NSLocalizedString("editor.trim_upper_bottom", comment: ""))
                        .tag(SeamTrimTarget.bottomOfUpper)
                    Text(NSLocalizedString("editor.trim_lower_top", comment: ""))
                        .tag(SeamTrimTarget.topOfLower)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)

                if viewModel.mode == .longStitch {
                    Button {
                        withAnimation {
                            viewModel.rematchSeam(at: index, autoTrimStaticBars: appState.autoTrimStaticBars)
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                }
            }

            HStack(spacing: 8) {
                nudgeButton("-20px", delta: -20)
                nudgeButton("-2px", delta: -2)

                Spacer()

                let trimmed = viewModel.seamTrimTarget == .topOfLower ? seam.botCropTop : seam.topCropBottom
                Text("\(trimmed) px")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)

                Spacer()

                nudgeButton("+2px", delta: 2)
                nudgeButton("+20px", delta: 20)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .zetaGlassToolbar()
        .padding(.horizontal, 16)
    }

    private func nudgeButton(_ title: String, delta: Int) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            viewModel.nudgeActiveSeam(deltaPixels: delta)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
    }

    private var cropActionBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "crop")
                .foregroundStyle(.white.opacity(0.8))
            Text(NSLocalizedString("editor.crop.hint", comment: ""))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button(NSLocalizedString("editor.crop.reset", comment: "")) {
                withAnimation(.snappy) {
                    viewModel.crop = .full
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(ZetaTheme.accent)
            .disabled(viewModel.crop.isFull)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .zetaGlassToolbar()
        .padding(.horizontal, 16)
    }

    // MARK: - Bottom Dock

    private var bottomGlassDock: some View {
        HStack(spacing: 4) {
            dockButton(
                title: NSLocalizedString("editor.tool.seam", comment: ""),
                icon: "scissors",
                active: viewModel.toolMode == .seamEdit,
                badge: viewModel.unmatchedCount > 0 ? "\(viewModel.unmatchedCount)" : nil
            ) {
                withAnimation(.snappy) {
                    viewModel.toolMode = viewModel.toolMode == .seamEdit ? .preview : .seamEdit
                }
            }
            .disabled(viewModel.draft.images.count < 2)

            dockButton(
                title: NSLocalizedString("editor.tool.crop", comment: ""),
                icon: "crop",
                active: viewModel.toolMode == .crop
            ) {
                withAnimation(.snappy) {
                    viewModel.toolMode = viewModel.toolMode == .crop ? .preview : .crop
                }
            }

            dockButton(
                title: NSLocalizedString(viewModel.removeScrollbars ? "editor.tool.restore_scrollbar" : "editor.tool.remove_scrollbar", comment: ""),
                icon: viewModel.removeScrollbars ? "arrow.uturn.backward" : "wand.and.stars",
                active: viewModel.removeScrollbars,
                badge: viewModel.totalScrollbarCount > 0 ? "\(viewModel.totalScrollbarCount)" : nil
            ) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.snappy) {
                    viewModel.toggleScrollbarRemoval()
                }
            }
            .disabled(viewModel.totalScrollbarCount == 0)

            if viewModel.mode != .longStitch {
                dockButton(
                    title: "\(viewModel.spacing)px",
                    icon: "distribute.vertical.center",
                    active: viewModel.spacing > 0
                ) {
                    withAnimation(.snappy) {
                        viewModel.cycleSpacing()
                    }
                }
            }

            dockButton(
                title: NSLocalizedString("editor.tool.preview", comment: ""),
                icon: "eye",
                active: viewModel.toolMode == .preview
            ) {
                withAnimation(.snappy) {
                    viewModel.toolMode = .preview
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .zetaGlassToolbar()
        .padding(.horizontal, 14)
    }

    private func dockButton(
        title: String,
        icon: String,
        active: Bool,
        badge: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.body.weight(.medium))
                        .frame(height: 22)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(ZetaTheme.warning, in: Capsule())
                            .offset(x: 10, y: -4)
                    }
                }

                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? ZetaTheme.accent : .white.opacity(0.88))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(active ? ZetaTheme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Actions

    private func modeTitle(_ m: StitchMode) -> String {
        switch m {
        case .longStitch: return NSLocalizedString("mode.long_stitch", comment: "")
        case .vertical: return NSLocalizedString("mode.v_stitch", comment: "")
        case .horizontal: return NSLocalizedString("mode.h_stitch", comment: "")
        }
    }

    private func performExport() {
        appState.busyMessage = NSLocalizedString("editor.rendering", comment: "")
        appState.isBusy = true

        Task {
            let result = await viewModel.exportResult(
                resolution: appState.exportResolution,
                format: appState.exportFormat
            )
            await MainActor.run {
                appState.isBusy = false
                if let result {
                    appState.navigationPath.append(.result(result))
                } else {
                    appState.errorAlertMessage = NSLocalizedString("editor.error.render_failed", comment: "")
                }
            }
        }
    }
}

// MARK: - Seam Handles

private struct VerticalSeamHandle: View {
    let seam: StitchSeam
    let isActive: Bool
    let width: CGFloat

    private var seamColor: Color {
        switch seam.status {
        case .matched: return isActive ? ZetaTheme.accent : ZetaTheme.success
        case .noMatch: return ZetaTheme.warning
        case .manual: return ZetaTheme.accent
        }
    }

    var body: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 16))
                p.addLine(to: CGPoint(x: width, y: 16))
            }
            .stroke(seamColor, style: StrokeStyle(lineWidth: isActive ? 2 : 1.5, dash: [6, 4]))
            .frame(width: width, height: 32)

            HStack(spacing: 5) {
                Image(systemName: seam.status.needsAttention ? "exclamationmark.triangle.fill" : "scissors")
                    .font(.caption2.weight(.bold))
                Text(seamLabel)
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(seamColor, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .frame(width: width, height: 32)
        .contentShape(Rectangle())
    }

    private var seamLabel: String {
        switch seam.status {
        case .matched:
            return seam.overlapHeight > 0 ? "-\(seam.overlapHeight)px" : "OK"
        case .noMatch:
            return NSLocalizedString("editor.seam.no_match", comment: "")
        case .manual:
            return NSLocalizedString("editor.seam.manual", comment: "")
        }
    }
}

private struct HorizontalSeamHandle: View {
    let seam: StitchSeam
    let isActive: Bool
    let height: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isActive ? ZetaTheme.accent : Color.white.opacity(0.55))
                .frame(width: isActive ? 2.5 : 1.5, height: height)

            Image(systemName: "scissors")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(isActive ? ZetaTheme.accent : Color.black.opacity(0.65), in: Circle())
        }
        .frame(width: 28, height: height)
        .contentShape(Rectangle())
    }
}

// MARK: - Interactive Crop Overlay

private struct CropBoxOverlay: View {
    @Binding var crop: NormalizedCropRect

    @State private var dragStartCrop: NormalizedCropRect?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let left = crop.left * w
            let right = crop.right * w
            let top = crop.top * h
            let bottom = crop.bottom * h
            let rectW = max(24, w - left - right)
            let rectH = max(24, h - top - bottom)

            ZStack(alignment: .topLeading) {
                // Dimmed outer crop regions
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRect(CGRect(x: left, y: top, width: rectW, height: rectH))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: rectW, height: rectH)
                    .offset(x: left, y: top)
                    .allowsHitTesting(false)

                // Top Edge Handle
                edgePill(horizontal: true)
                    .position(x: left + rectW / 2, y: top)
                    .gesture(dragEdge(.top, width: w, height: h))

                // Bottom Edge Handle
                edgePill(horizontal: true)
                    .position(x: left + rectW / 2, y: top + rectH)
                    .gesture(dragEdge(.bottom, width: w, height: h))

                // Left Edge Handle
                edgePill(horizontal: false)
                    .position(x: left, y: top + rectH / 2)
                    .gesture(dragEdge(.left, width: w, height: h))

                // Right Edge Handle
                edgePill(horizontal: false)
                    .position(x: left + rectW, y: top + rectH / 2)
                    .gesture(dragEdge(.right, width: w, height: h))
            }
        }
    }

    private enum Edge { case top, bottom, left, right }

    private func edgePill(horizontal: Bool) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: horizontal ? 42 : 6, height: horizontal ? 6 : 42)
            .shadow(color: .black.opacity(0.4), radius: 3)
            .padding(14)
            .contentShape(Rectangle())
    }

    private func dragEdge(_ edge: Edge, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { val in
                if dragStartCrop == nil { dragStartCrop = crop }
                guard let base = dragStartCrop else { return }

                switch edge {
                case .top:
                    let delta = val.translation.height / max(1, height)
                    crop.top = min(max(0, base.top + delta), 0.85 - crop.bottom)
                case .bottom:
                    let delta = -val.translation.height / max(1, height)
                    crop.bottom = min(max(0, base.bottom + delta), 0.85 - crop.top)
                case .left:
                    let delta = val.translation.width / max(1, width)
                    crop.left = min(max(0, base.left + delta), 0.85 - crop.right)
                case .right:
                    let delta = -val.translation.width / max(1, width)
                    crop.right = min(max(0, base.right + delta), 0.85 - crop.left)
                }
            }
            .onEnded { _ in
                dragStartCrop = nil
            }
    }
}
