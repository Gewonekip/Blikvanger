# Parked — AR Vehicle Labels

Parked is a native SwiftUI iPhone app that attaches persistent, readable information cards to stationary parked cars. The spatial label is the source of truth: every card is backed by a measured `ARAnchor`, projected into screen space each frame, and retained when the car leaves view. Plate localization, OCR, and public RDW data enrich that existing anchor.

## Requirements

- Xcode 26.4.1 or newer
- iOS 18 or newer
- A LiDAR-equipped iPhone Pro for physical scanning
- Camera permission

The simulator deliberately shows the polished unsupported-device state because ARKit camera tracking and LiDAR are unavailable there. Its deterministic tests exercise the geometry and data pipeline.

## Prototype status

The project passes all 160/160 deterministic simulator tests under Swift 6 strict concurrency, an optimized arm64 iPhone build, and Xcode static analysis. The signed Release revision is installed on the paired iPhone 13 Pro Max. The consumer scanner has no aim box, detector outline, diagnostic HUD, manual-placement mode, or pipeline console logging. The remaining prototype gate is hands-on camera/LiDAR validation around varied real parked vehicles with `DEVICE_TESTS.md`; distribution and App Store work are intentionally outside the current focus.

## Build and test

The checked-in `.xcodeproj` is generated from `project.yml` with XcodeGen. Regenerate only after changing target structure. List available destinations and substitute a simulator UDID below:

```sh
xcodegen generate
xcodebuild -project LicensePlates.xcodeproj -scheme LicensePlates -showdestinations
xcodebuild -project LicensePlates.xcodeproj -scheme LicensePlates \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild -project LicensePlates.xcodeproj -scheme LicensePlates \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  test CODE_SIGNING_ALLOWED=NO
xcodebuild -project LicensePlates.xcodeproj -scheme LicensePlates \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

For a consumer-style prototype install, build and install the explicit Release product so Xcode's development dylibs are not copied to the phone:

```sh
xcodebuild -project LicensePlates.xcodeproj -scheme LicensePlates \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/ParkedPhoneBuild -allowProvisioningUpdates build
xcrun devicectl device install app --device <DEVICE_ID> \
  /tmp/ParkedPhoneBuild/Build/Products/Release-iphoneos/Parked.app
```

The configured development team signs this direct-install prototype; only registered development devices can run it. The app runtime-gates world tracking, scene depth, and mesh reconstruction.

## Delivered phases

1. **Native foundation:** one SwiftUI iPhone app and one XCTest target, Swift 6 strict concurrency, no third-party runtime dependency.
2. **Spatial label lifecycle:** Only the automatic measured pipeline can create a vehicle label. Multiple independent identities, same-car reassociation, per-vehicle removal, and full reset share one lifecycle authority; ordinary screen taps have no placement behavior.
3. **Card presentation:** world positions project every render update into crisp SwiftUI cards. Safe-area clamping, distance prominence, collision resolution, leader lines, selection, details, and accessibility do not mutate the anchor.
4. **Automatic localization:** Vision rectangle detection is admitted before expensive frame copying, runs at a controlled cadence with at most one detector in flight, and maps portrait Vision results back to raw AR camera coordinates. The entire usable camera image is eligible—there is no center band or center-weighted ranking. Every one of Vision's bounded rectangle proposals reaches the appearance stage, so a small off-center plate cannot be starved by bumper or window edges. When characters are readable but the generic rectangle detector misses the outer plate border, a throttled full-frame text-localization fallback validates Dutch plate syntax and expands the text region to the yellow field. Both paths must then pass legal in-bounds geometry and a perspective-corrected yellow-field/distributed-dark-character score before they can seed tracking. Each frame emits at most one target using deterministic tie-breakers. Temporal tracks tolerate two missed detector passes, reset on a third, expire lost observations, cap memory, and prevent nearby duplicates.
5. **Stable pose:** exact-frame image, intrinsics, smoothed depth/confidence, timestamp, camera transform, and tracking quality are snapshotted together. A calibrated four-corner planar solve tests legal Dutch plate sizes with rigid reprojection and orthogonality checks; robust depth rejects duplicate cells, impossible physical scale, and edge outliers. Projective plate center rays prevent surrounding bumper depth from pulling labels sideways. A broad, agreeing reconstructed-mesh surface strengthens and refines the estimate; missing/degenerate mesh remains optional, while a broad surface that strongly contradicts depth vetoes placement. Five associated observations (with at most two intervening detector misses), four agreeing world-pose samples spanning at least 0.25 seconds, and two recent normally tracked pose frames are required before a permanent automatic anchor can be created or reassociated. The current camera/anchor transforms must also come from the same trusted AR frame before a card is shown.
6. **Recognition:** only a tracked, orientation-corrected perspective crop reaches serialized Vision OCR. Small crops are mildly contrast-normalized and upscaled within a hard bound. Distant Vision fragments such as `12`, `BD`, `34` are assembled left-to-right with a bounded beam before multi-frame consensus; nested regions and fragments from unrelated text rows cannot be combined. Three consistent moderate-confidence frames can confirm when two high-confidence frames are unavailable. Published Dutch sidecodes 1–14, prohibited groups, category exceptions, ambiguous glyph margins, whole-plate reads, and transient-misread resistance are independently tested. RDW's separate duplicate code (`0`–`9` around the first dash) is stripped only at the validated first sidecode boundary; it is never sent as part of the six-character registration. After spatial localization, intermittent LiDAR no longer blocks OCR on a frame that still sees the same visual candidate. Recognition failure cannot prevent or remove the anchor. Initial unreadable frames get a short autofocus acquisition burst before retries taper to a bounded exponential cadence.
7. **RDW:** the official `m9d7-ebf2` dataset is queried by canonical plate using encoded `URLComponents`. As soon as consensus succeeds, the scan status shows the exact plate being prepared and then checked with RDW until the response arrives, even when its AR card is offscreen. The actor client supports per-waiter cancellation, an explicit timeout, globally spaced retries, in-flight deduplication, result-specific caches, full public vehicle details, and explicit failure states. Failure never removes the anchor.
8. **Verification:** The same consumer surface is used in every build configuration: cards, vehicle count, privacy/reset controls, exact plate/RDW progress, and plain-language guidance. There is no developer overlay or manual placement code path in the target. Fixtures cover full-frame/off-center acquisition, text-localization fallback, candidate-pool starvation, yellow-plate-versus-neutral-bumper selection, appearance rejection, anchor identity/projection, removal, reset, reassociation, no-gap retargeting, multi-car OCR fairness, deterministic single-target selection, tracking-quality epochs, optional/contradictory mesh validation, depth-only pose fallback, stable pre-OCR anchoring, persistence after detector expiry, stale callbacks/timestamps, camera-motion invariance, and RDW cancellation/cache races. Terminal AR failures clear invalid spatial state and expose an in-app retry path; reset can restart stalled recovery even when no vehicles are saved.

## Privacy and scope

Camera frames are processed in memory on-device. The app does not upload or save frames, retain scan/location history, request owner information, or request unrelated permissions. After temporal confirmation, only the canonical plate text is sent over an ephemeral HTTPS session to Open Data RDW. Only stationary vehicles are supported. Reset explicitly removes all AR and presentation state.

## Data and assets

- Vehicle data: [Open Data RDW: Gekentekende voertuigen](https://opendata.rdw.nl/Voertuigen/Open-Data-RDW-Gekentekende_voertuigen/m9d7-ebf2), public domain.
- Detection/OCR: Apple Vision; no external model weights are bundled.
- UI: Apple SF Symbols and system materials. The original Parked icon is a repository-owned vector rendered into the asset catalog; no third-party image assets are bundled.

## Genuine limitations

- Generic rectangle localization plus the validated-text fallback is not a plate- or vehicle-specific trained detector. A plate-sized yellow sign carrying a syntactically valid Dutch registration remains a potential false-positive class, although repeated pose/OCR evidence is still required. A licensed Dutch/European Core ML detector or validated vehicle-context model remains the preferred future upgrade after on-device precision/recall and latency validation.
- Appearance thresholds currently have deterministic synthetic coverage, not a licensed real-image corpus. Glare, rain, dirt, motion blur, night exposure, and reflective LiDAR behavior require the next physical test round.
- The pose implementation uses calibrated homography decomposition plus robust depth and optional mesh corroboration, not a full IPPE/RANSAC solver. Strong obliquity and unusual legal plate sizes need broader physical validation.
- AR behavior cannot be validated in Simulator. Complete the physical checklist in `DEVICE_TESTS.md` before field release.
- Anchors persist for the current AR session only; cross-launch `ARWorldMap` persistence is intentionally outside this privacy-preserving scope.
