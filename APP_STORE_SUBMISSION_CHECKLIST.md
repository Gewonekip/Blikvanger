# Blikvanger — App Store submission checklist

This checklist is for the first public App Store submission. It contains no
credentials or signing material.

## Completed

- [x] App Store Connect app record exists: **Blikvanger** (`6816631317`).
- [x] Bundle identifier is `nl.gewonekip.blikvanger`.
- [x] Version 1.0 metadata is configured in Dutch.
- [x] Support URL: <https://gewonekip.com/blikvanger>.
- [x] Privacy policy URL: <https://gewonekip.com/blikvanger/privacy>.
- [x] Age rating is 4+.
- [x] App Review contact is configured for Job van Dijke.
- [x] The app does not require an account or demo credentials.
- [x] Build 4 is valid and attached to version 1.0.
- [x] Export-compliance setting is non-exempt encryption (`ITSAppUsesNonExemptEncryption = NO`).
- [x] No StoreKit or in-app-purchase implementation exists in the project.
- [x] App Store Review notes explain the camera, LiDAR and stationary-car test flow.
- [x] `AGENTS.md` documents the review contact and test instructions.

## App Store Connect actions still required

- [ ] Complete the App Privacy questionnaire truthfully. The app does not track
  users, use advertising, use analytics or upload camera/LiDAR data. It does
  send a confirmed license-plate text to the public RDW service, so classify
  that behavior according to Apple's current questionnaire definitions.
- [ ] Confirm the app is **Free** under Pricing and Availability.
- [ ] Confirm availability is **All territories** (worldwide), unless a
  deliberate regional restriction is required.
- [ ] Upload the final iPhone screenshots. Screenshots are currently absent.
- [ ] Confirm the required agreements, tax and banking sections are active for
  the developer account.
- [ ] Select build 4 for version 1.0 if App Store Connect asks for it again.
- [ ] Submit the version for App Review after the physical-device check below.

## Physical-device acceptance check

Use a LiDAR-equipped iPhone Pro and a stationary Dutch vehicle with a readable
license plate. Follow the detailed procedure in `DEVICE_TESTS.md` and verify:

- [ ] Camera permission prompt and denial path are clear.
- [ ] The AR experience starts reliably on the supported device.
- [ ] A readable six-character Dutch plate is detected only when appropriate.
- [ ] RDW lookup succeeds over the network.
- [ ] No owner or personal data is shown.
- [ ] Camera images, LiDAR depth and AR session data are not persisted or uploaded.
- [ ] The app remains usable when the plate is unreadable or the network fails.

## Final submission check

- [ ] Version status is ready for submission.
- [ ] The selected build is processed and valid.
- [ ] Metadata, privacy answers, screenshots and review notes are complete.
- [ ] The release notes accurately describe the submitted build.
- [ ] Submit to App Review.

