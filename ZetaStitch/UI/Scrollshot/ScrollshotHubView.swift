import SwiftUI
import UIKit
import ReplayKit

public struct ScrollshotHubView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var recordings: [ScreenRecordingInfo] = []

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    liveBroadcastCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section(NSLocalizedString("scrollshot.settings.section", comment: "")) {
                    Picker(NSLocalizedString("scrollshot.auto_end", comment: ""), selection: $appState.autoEndSeconds) {
                        ForEach(AutoEndSeconds.allCases) { option in
                            Text(autoEndLabel(option)).tag(option)
                        }
                    }

                    Toggle(NSLocalizedString("scrollshot.vibrate_start", comment: ""), isOn: $appState.hapticOnStart)

                    Toggle(NSLocalizedString("scrollshot.send_notification", comment: ""), isOn: $appState.notifyOnComplete)
                        .onChange(of: appState.notifyOnComplete) { enabled in
                            if enabled {
                                Task {
                                    _ = await NotificationService.shared.requestAuthorizationIfNeeded()
                                }
                            }
                        }

                    Button {
                        appState.isScrollshotGuidePresented = true
                    } label: {
                        HStack {
                            Label(NSLocalizedString("scrollshot.guide", comment: ""), systemImage: "book.pages")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section(NSLocalizedString("scrollshot.recent.section", comment: "")) {
                    if recordings.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "rectangle.dashed")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text(NSLocalizedString("scrollshot.recent.empty", comment: ""))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 20)
                            Spacer()
                        }
                    } else {
                        ForEach(recordings) { rec in
                            Button {
                                appState.openRecordingInEditor(rec)
                            } label: {
                                RecordingRow(info: rec)
                            }
                            .foregroundStyle(.primary)
                        }
                        .onDelete { offsets in
                            deleteRecordings(at: offsets)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("home.scrollshot", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("common.done", comment: "")) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                recordings = AppGroupStore.shared.listRecordings()
            }
        }
    }

    private var liveBroadcastCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(ZetaTheme.accent.opacity(0.14))
                    .frame(width: 78, height: 78)

                BroadcastPickerRepresentable(extensionBundleID: "com.zeta.stitch.scrollshot")
                    .frame(width: 60, height: 60)
            }

            VStack(spacing: 4) {
                Text(NSLocalizedString("scrollshot.start_title", comment: ""))
                    .font(.headline)
                Text(NSLocalizedString("scrollshot.start_subtitle", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(ZetaTheme.surfaceCard, in: RoundedRectangle(cornerRadius: ZetaTheme.cornerRadiusCard, style: .continuous))
    }

    private func autoEndLabel(_ option: AutoEndSeconds) -> String {
        if option == .never {
            return NSLocalizedString("scrollshot.auto_end.never", comment: "")
        }
        let formatted = option.rawValue.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", option.rawValue)
            : String(format: "%.1f", option.rawValue)
        return String(format: NSLocalizedString("scrollshot.auto_end.seconds", comment: ""), formatted)
    }

    private func deleteRecordings(at offsets: IndexSet) {
        for idx in offsets {
            let rec = recordings[idx]
            try? AppGroupStore.shared.deleteRecording(id: rec.id)
        }
        recordings.remove(atOffsets: offsets)
    }
}

private struct RecordingRow: View {
    let info: ScreenRecordingInfo

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
                .frame(width: 48, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(info.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                Text("\(info.matches.count) \(NSLocalizedString("scrollshot.keyframes_unit", comment: "")) · \(info.frameWidth)×\(info.frameHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let first = info.matches.first {
            let url = AppGroupStore.shared.keyframesFolderURL(for: info.id, folderName: info.keyframesFolderName)
                .appendingPathComponent(first.keyframeFileName)
            if let uiImg = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImg)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            Image(systemName: "video")
                .foregroundStyle(.secondary)
        }
    }
}

public struct BroadcastPickerRepresentable: UIViewRepresentable {
    public let extensionBundleID: String

    public func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = extensionBundleID
        picker.showsMicrophoneButton = false
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
                button.setImage(UIImage(systemName: "record.circle.fill", withConfiguration: config), for: .normal)
                button.tintColor = UIColor(ZetaTheme.accent)
            }
        }
        return picker
    }

    public func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = extensionBundleID
    }
}
