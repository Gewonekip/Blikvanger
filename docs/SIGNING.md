# Signing and bundle identity

The repository intentionally does not contain an Apple Developer Team ID or a
fork-specific bundle ID. The checked-in App Store product currently uses
`nl.gewonekip.blikvanger`; forks should choose their own identifier.

For a local signed build, copy `Config/Signing.xcconfig.example` to
`Config/Signing.xcconfig` and use it as the build configuration in Xcode, or
override the values directly:

```sh
xcodebuild -project Blikvanger.xcodeproj -scheme Blikvanger \
  -configuration Release \
  DEVELOPMENT_TEAM=YOUR_APPLE_TEAM_ID \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.blikvanger
```

CI and unsigned simulator builds should use `CODE_SIGNING_ALLOWED=NO`.
App Store Connect/Xcode Cloud supplies signing identity through the Apple
account configured for that product.
