# Zeta Stitch (Refactored SwiftUI Edition)

A clean, ad-free, paywall-free native iOS long-screenshot & scrollshot app reconstructed using **Swift 5.9 + SwiftUI + Metal + Vision + ReplayKit**.

## Key Features

- **Smart Long Stitch (`长截图`)**:
  - Multi-band row signature + coarse-to-fine native-resolution overlap alignment (`OverlapDetector`) with `VNTranslationalImageRegistrationRequest` fallback.
  - Automatic detection and exclusion of static status bars, navigation headers, home indicators, and fixed bottom toolbars.
  - Interactive Seam Editor (`StitchEditorView`) with direct drag handles and pixel-exact `±2px / ±20px` micro-nudge controls.
- **Vertical & Horizontal Collage (`竖拼图` / `横拼图`)**:
  - Seamless or spaced (`0 / 8 / 16 / 28px`) joining with proportional width/height normalization.
- **Live Scrollshot (`滚动截屏`) via ReplayKit**:
  - `ZetaScrollshotExtension` (`RPBroadcastSampleHandler`) tracks live scroll translation using Vision within ReplayKit's 50 MB memory budget.
  - Configurable idle auto-end timer (`0.5s – 3s` or manual), start haptic feedback, and completion notification deep-linking straight into the editor.
  - Embedded `RPSystemBroadcastPickerView` inside `ScrollshotHubView` plus recent Scrollshot history via App Group `group.com.zeta.stitch`.
- **Video-to-Long-Screenshot (`视频/录屏拼接`)**:
  - Interactive filmstrip `VideoTrimmerView` with smart keyframe sampling (`VideoStitcher.extractKeyframes`).
- **GPU Metal Scrollbar Removal (`去滚动条`)**:
  - Automatic right-edge scroll indicator detection (`ScrollbarDetector`) + `scrollBarTransform` Metal compute kernel (`ScrollbarRemoval.metal`), toggleable non-destructively.
- **Crop & Multi-Format Export**:
  - Interactive 4-edge canvas cropper, export resolution presets (`Original`, `2048px`, `1080px` short side), `PNG / HEIC / JPEG` encoding, auto-tiled `PDFCreator`, pure-Swift `ZipArchiveWriter`, Photos saving, and original asset cleanup.

## Building on macOS / Xcode

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. Update `DEVELOPMENT_TEAM` (and adjust `PRODUCT_BUNDLE_IDENTIFIER` / App Group `group.com.zeta.stitch` if needed) in:
   - `project.yml`
   - `Shared/AppGroupStore.swift`
   - `ZetaStitch/ZetaStitch.entitlements`
   - `ZetaScrollshotExtension/ZetaScrollshotExtension.entitlements`
   - `ZetaStitch/UI/Scrollshot/ScrollshotHubView.swift` (`BroadcastPickerRepresentable`)
3. Generate and open the Xcode project:
   ```bash
   cd ZetaStitch
   xcodegen generate
   open ZetaStitch.xcodeproj
   ```
4. Select your iOS device / simulator and build or run unit tests (`Cmd+U`).

## GitHub Actions Cloud IPA Build

This repository includes [.github/workflows/build-ipa.yml](.github/workflows/build-ipa.yml) running on `macos-15-intel`:

- **Unsigned IPA (zero secrets required)**: Automatically runs `ZetaStitchTests`, compiles `ZetaStitch.app` + `ZetaScrollshotExtension.appex` + `default.metallib`, and uploads `ZetaStitch-unsigned.ipa` (for TrollStore / Esign / Sideloadly / self-signing) as a workflow artifact.
- **Signed IPA (optional)**: Add repository secrets `APPLE_P12_BASE64`, `APPLE_P12_PASSWORD`, `APP_PROVISION_BASE64`, `EXT_PROVISION_BASE64`, and optional `EXPORT_METHOD` (`ad-hoc` / `development` / `app-store`) to also export `ZetaStitch-signed.ipa`.

