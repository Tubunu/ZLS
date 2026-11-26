import SwiftUI
import UIKit
import UserNotifications

final class AppNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var appState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let recID = userInfo["recordingID"] as? String,
           let info = AppGroupStore.shared.loadRecordingInfo(id: recID) {
            await MainActor.run {
                self.appState?.openRecordingInEditor(info)
            }
        }
    }
}

@main
struct ZetaStitchApp: App {
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var notificationDelegate
    @StateObject private var appState = AppState()
    @StateObject private var photoService = PhotoLibraryService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $appState.navigationPath) {
                HomeView()
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .editor(let draft):
                            StitchEditorView(draft: draft)
                        case .videoTrimmer(let trimmerDraft):
                            VideoTrimmerView(draft: trimmerDraft)
                        case .result(let resultDraft):
                            StitchResultView(draft: resultDraft)
                        }
                    }
            }
            .environmentObject(appState)
            .environmentObject(photoService)
            .sheet(isPresented: $appState.isScrollshotHubPresented) {
                ScrollshotHubView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $appState.isSettingsPresented) {
                SettingsView()
                    .environmentObject(appState)
            }
            .fullScreenCover(isPresented: $appState.isScrollshotGuidePresented) {
                ScrollshotGuideView()
            }
            .overlay {
                if appState.isBusy {
                    ZetaLoadingOverlay(message: appState.busyMessage)
                }
            }
            .alert(
                NSLocalizedString("common.error", comment: ""),
                isPresented: Binding(
                    get: { appState.errorAlertMessage != nil },
                    set: { if !$0 { appState.errorAlertMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) {
                    appState.errorAlertMessage = nil
                }
            } message: {
                Text(appState.errorAlertMessage ?? "")
            }
            .onAppear {
                notificationDelegate.appState = appState
                appState.checkForNewScrollshot()
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    appState.checkForNewScrollshot()
                }
            }
            .onOpenURL { url in
                guard url.scheme == AppGroupStore.urlScheme else { return }
                if url.host == "scrollshot",
                   let id = url.pathComponents.dropFirst().first,
                   let info = AppGroupStore.shared.loadRecordingInfo(id: id) {
                    appState.openRecordingInEditor(info)
                } else if url.host == "scrollshot" {
                    appState.isScrollshotHubPresented = true
                }
            }
        }
    }
}

private struct ZetaLoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                if !message.isEmpty {
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        }
    }
}
