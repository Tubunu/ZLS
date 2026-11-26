import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("settings.section.stitching", comment: "")) {
                    Picker(NSLocalizedString("settings.export_size", comment: ""), selection: $appState.exportResolution) {
                        Text(NSLocalizedString("settings.export_size.original", comment: ""))
                            .tag(ExportResolution.original)
                        Text(NSLocalizedString("settings.export_size.2048", comment: ""))
                            .tag(ExportResolution.shortSide2048)
                        Text(NSLocalizedString("settings.export_size.1080", comment: ""))
                            .tag(ExportResolution.shortSide1080)
                    }

                    Picker(NSLocalizedString("settings.export_format", comment: ""), selection: $appState.exportFormat) {
                        Text("PNG").tag(ExportFormat.png)
                        Text("HEIC").tag(ExportFormat.heic)
                        Text("JPEG").tag(ExportFormat.jpeg)
                    }

                    Toggle(NSLocalizedString("settings.auto_trim_bars", comment: ""), isOn: $appState.autoTrimStaticBars)
                }

                Section(NSLocalizedString("settings.section.scrollshot", comment: "")) {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            appState.isScrollshotHubPresented = true
                        }
                    } label: {
                        Label(NSLocalizedString("settings.scrollshot_hub", comment: ""), systemImage: "record.circle")
                    }

                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            appState.isScrollshotGuidePresented = true
                        }
                    } label: {
                        Label(NSLocalizedString("scrollshot.guide", comment: ""), systemImage: "book.pages")
                    }
                }

                Section(NSLocalizedString("settings.section.about", comment: "")) {
                    HStack {
                        Text(NSLocalizedString("settings.version", comment: ""))
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label(NSLocalizedString("settings.privacy.title", comment: ""), systemImage: "lock.shield")
                            .font(.subheadline.weight(.semibold))
                        Text(NSLocalizedString("settings.privacy.desc", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(NSLocalizedString("settings.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("common.done", comment: "")) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
