# Parked privacy policy

Last updated: 12 July 2026

Parked processes camera images, LiDAR depth, and reconstructed mesh data in memory on the iPhone. It does not save or upload camera images, location, or AR session history.

After a Dutch plate is confirmed across multiple frames, Parked sends only its six-character plate text over HTTPS to the public Open Data RDW service. RDW returns public vehicle facts. Parked does not request or display vehicle-owner data.

The RDW service handles the plate query under its [published privacy statement](https://www.rdw.nl/over-rdw/privacy-en-security/privacyverklaring). Parked minimizes this disclosure to the confirmed plate text and uses an ephemeral HTTPS session without a persistent URL cache.

Vehicle labels and lookup results last only for the current app session. One on-device preference remembers whether onboarding has been completed. Parked contains no advertising, analytics, cross-app tracking, or third-party SDKs.

On first use, scanning starts after the user chooses **Start scanning** and grants camera access. On later launches, the camera starts when Parked opens while permission remains granted. Camera permission can be withdrawn in iOS Settings at any time. **Reset** deletes all in-session labels, displayed lookup results, and the temporary RDW cache. Force-quitting or process termination discards the AR session. Deleting the app also removes the onboarding preference. Parked has no accounts or developer-operated server records to delete.
