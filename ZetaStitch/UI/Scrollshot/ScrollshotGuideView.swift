import SwiftUI

public struct ScrollshotGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0

    private let steps: [(icon: String, titleKey: String, descKey: String)] = [
        ("hand.draw", "guide.step1.title", "guide.step1.desc"),
        ("slider.horizontal.3", "guide.step2.title", "guide.step2.desc"),
        ("record.circle", "guide.step3.title", "guide.step3.desc"),
        ("bell.badge", "guide.step4.title", "guide.step4.desc")
    ]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(NSLocalizedString("guide.exit", comment: "")) {
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            TabView(selection: $currentPage) {
                ForEach(0..<steps.count, id: \.self) { idx in
                    VStack(spacing: 24) {
                        Spacer()

                        ZStack {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .fill(ZetaTheme.accent.opacity(0.10))
                                .frame(width: 140, height: 140)
                            Image(systemName: steps[idx].icon)
                                .font(.system(size: 56, weight: .medium))
                                .foregroundStyle(ZetaTheme.accent)
                        }

                        VStack(spacing: 12) {
                            Text(NSLocalizedString(steps[idx].titleKey, comment: ""))
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)

                            Text(NSLocalizedString(steps[idx].descKey, comment: ""))
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }

                        Spacer()
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if currentPage < steps.count - 1 {
                    withAnimation { currentPage += 1 }
                } else {
                    dismiss()
                }
            } label: {
                Text(NSLocalizedString(currentPage < steps.count - 1 ? "guide.next" : "common.done", comment: ""))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ZetaTheme.accent, in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
}
