# Shelfer Release QA

Date: 2026-08-31
Environment: macOS 26.6.2, Xcode 26.6, Apple Silicon MacBook Pro with notch

## Result

The app builds, archives, and passes its unit/integration suite. The Finder Sync extension is embedded in the containing app, and the current extension archive includes the App Store-required `LSUIElement` value.

## Automated checks

- 129 tests across 8 suites passed in Debug.
- Xcode result bundle reported 0 build errors and 0 warnings for the test run.
- Release build succeeded with optimization and hardened runtime enabled.
- Release static analysis succeeded.
- Universal archive succeeded for `arm64` and `x86_64`.
- App and Finder Sync property lists and entitlements passed `plutil` validation.
- Asset Catalog compiled the complete macOS app-icon set without warnings.
- Finder Sync is registered in PlugInKit with the debugger-use election during development.
- `git diff --check` passed.

## Onboarding tutorial QA

- All four tutorial clips are bundled with the app.
- AVFoundation reports every clip as playable at `1200 × 928`.
- Quick Look successfully decoded a representative frame from every clip.
- The onboarding policy, extension-status flow, and bundled-clip test suite passed.
- Clip durations are 6.01 seconds (shake), 8.25 seconds (collect), 8.07 seconds (paths), and 19.71 seconds (actions).

## Regression coverage added

- Complete state cleanup when all shelves are hidden.
- Independent notch shelves on different displays.
- Finder handoff rejection for unknown modes, malformed JSON, and empty payloads.
- Context-menu Copy, AirDrop, and Clear action forwarding.
- AirDrop conversion of stored paths into private, numbered plain-text files.
- Text file-promise representations, HTML escaping, safe names, and exact UTF-8 output.
- File metadata for ordinary files and image pixel dimensions.
- Image type detection without requiring the referenced file to exist.

## Defects fixed during QA

- Global Hide Shelf now routes through each shelf's reducer cleanup path. It clears selection and docking state and cancels in-flight notch lifecycle work instead of leaving transient state behind.
- Release code coverage instrumentation is explicitly disabled. The final binary contains no LLVM profile sections.
- A valid `PrivacyInfo.xcprivacy` is bundled. It declares app-local `UserDefaults` use with approved reason `CA92.1`, no collected data, and no tracking.
- The Finder Sync extension declares `LSUIElement = true`, as required by App Store upload validation for the embedded agent extension.

## Manual Release QA

Verified by launching the actual Release app with controlled seed data:

- Expanded two-file shelf renders file metadata, grid/list controls, Back, and Reveal in Finder without background loss.
- Compact path-only shelf renders two path items and the full circular Close/Clear controls.
- Direct notch storage retracts the ordinary shelf window and leaves a single ambient overlay around the notch.
- Release QA instances produced no stderr runtime errors.
- App Sandbox is present on the app and Finder extension; archive entitlements do not contain `get-task-allow`.

## Not completed by automation

The macOS UI test runner entered automation mode but stalled while waiting for its worker to materialize. The run was stopped after several minutes. No app assertion failed, but the click-at-the-edge UI tests must be run once from Xcode on a machine where Xcode UI Testing/Accessibility automation is functioning.

Run at least these tests before upload:

- `testClearButtonAcceptsClicksNearTheEdgeOfItsVisibleCircle`
- `testCloseButtonAcceptsClicksNearTheEdgeOfItsVisibleCircle`
- `testDirectNotchPathShelfKeepsTheWholeClearCircleInteractive`
- `testOptionShakePathShelfKeepsPathsAndFullButtonHitTargets`

## App Store submission notes

1. Create and upload a fresh archive after the Finder Sync `LSUIElement` fix; archives created before the fix remain invalid.
2. Let Organizer manage App Store distribution signing for both the containing app and embedded Finder Sync extension.
3. Confirm these product choices before submission:
   - Minimum system version is macOS 26.0.
   - `LSApplicationCategoryType` is `public.app-category.developer-tools`.
   - `NSHumanReadableCopyright` is empty.
   - App target currently uses Swift 5 language mode with approachable-concurrency/Swift 6 upcoming features; Finder Sync uses Swift 6.

## Final pre-upload checklist

- Re-archive, validate, and distribute through Organizer using automatic signing.
- Generate the archive Privacy Report and compare it with App Store Connect privacy answers.
- Run the four UI interaction tests above from Xcode.
- Fill copyright and confirm category/minimum macOS version.
