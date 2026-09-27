# Contributing to Blikvanger

Thanks for contributing. Blikvanger is an iOS 18+ SwiftUI/ARKit application
and requires a LiDAR-equipped iPhone for meaningful runtime validation.

## Before opening a pull request

1. Install the Xcode version documented in `README.md` and XcodeGen 2.46.0.
2. Regenerate the project with `mint run yonaskolb/xcodegen@2.46.0 xcodegen generate`
   after changing `project.yml`.
3. Run the unit tests on an iOS Simulator with code signing disabled.
4. Run `scripts/security_scan.sh`.
5. Run `git diff --check` and keep generated-project changes in the same pull
   request as their source change.

Do not commit signing files, API keys, provisioning profiles, device captures
containing identifiable information, or private RDW test data.

## Scope and review expectations

Keep spatial truth, presentation state, OCR, and RDW enrichment separate. A
change must not make a guessed screen position authoritative or silently turn a
network/vision failure into a successful result. Add deterministic tests for
geometry, OCR parsing, lifecycle, and networking changes.

Physical AR behavior needs a LiDAR-device test entry in `DEVICE_TESTS.md` and
should include device model, iOS version, lighting, distance, and observed
status text.
