# Architecture

## Core invariant

`VehicleTrack.stableTransform` and its `ARAnchor` identify the physical car. Screen detections and cards never become spatial truth. A multi-frame stable automatic pose calls `AnchorManager.createAnchor(at:displayName:)` or reassociates an existing nearby vehicle before OCR. Once established, anchors are frozen and survive loss of the detector candidate. OCR and network results can update card content but cannot create, move, or replace spatial truth.

```text
camera ─ rectangle proposals ─ appearance ───────────────┐
       └─ throttled validated-text localization fallback ├─ one target ─ temporal track ─ planar + depth ─ stable pose
                                                         │                              └─ optional mesh       │
                                                         └──────────────────────────────────────────── AnchorManager ─ ARAnchor
                                                                                                                        ├─ project every frame ─ card layout
camera crop ─ bounded OCR consensus ─ RDW ─ update existing vehicle card ───────────────────────────────────────────────┘
```

## Responsibilities

- `ARSessionController`: session capability/permission gate, ordered callback reduction, interruption and run-boundary ownership, retryable session-failure state, pre-copy frame admission, exact-frame snapshot lifetime, detector/OCR/enrichment cancellation, optional mesh evidence, frame-synchronized anchor projection, and consumer guidance.
- `AnchorManager`: the single lifecycle authority for AR anchors and vehicle identities.
- `AnchorProjectionService`: deterministic world/clip/screen projection used by replay tests.
- `CardLayoutEngine`: screen-only safe-area and overlap resolution; returns leader-line endpoints.
- `VisionPlateDetector`, `VisionPlateTextLocalizer`, `PlateAppearanceScorer`, and `PlateDetectionWorker`: bounded full-frame rectangle localization, throttled Dutch-text fallback, legal geometry, perspective-corrected common-yellow-plate appearance, and deterministic selection without center bias. The worker emits at most one viable target per frame. Both localization paths remain replaceable through protocols.
- `PlateTracker`: overlap plus bounded center/scale/aspect motion identity, associated-observation count, expiry, and pose history. Two empty detector passes are tolerated; a third miss or an immediate selected-target switch resets convergence.
- `ImageCoordinateMapper`: explicit EXIF-oriented Vision, raw captured-image, depth, and screen conversions.
- `DepthSampler`: raw image/depth mapping, confidence/range rejection, robust outlier removal, and back-projection. Snapshots prefer smoothed scene depth and fall back to scene depth.
- `PlanarPoseSolver`, `PlatePoseEstimator`, `MeshEvidenceProvider`, and `PoseFusion`: calibrated four-corner pose, legal-size/depth agreement, optional mesh validation/refinement, camera-to-world orientation, repeated-pose stabilization, and jump rejection.
- `PerspectiveCorrector`, `PlateRecognitionPreprocessor`, `VisionPlateRecognizer`, `PlateTextAssembler`, and `PlateConsensus`: crop rectification, bounded small-crop preparation, geometrically constrained split-fragment OCR assembly, Dutch/duplicate-code syntax, and multi-frame character evidence.
- `AutomaticVehicleCoordinator`: candidate state machine, duplicate suppression, immediate routing of stable spatial transforms to `AnchorManager`, detector-expiry cleanup that preserves established anchors, and later OCR association.
- `RDWClient`: protocol-backed async HTTP, typed results, cache, timeout, and request deduplication.
- `VehicleEnrichmentService`: updates an existing track while preserving spatial state on all network results.

## State and lifecycle

Automatic candidates progress through detected, tracking, spatially estimating, spatially stable, reading, confirming, and anchored states. Neither a generic rectangle nor one pose sample can create an automatic anchor. Detections must match the depth snapshot timestamp exactly. Five observations must produce four agreeing world poses over at least 0.25 seconds; at least two of those poses must come from recent `.normal` AR tracking. A robust fused pose becomes the stationarity reference, so a bad first depth frame cannot poison acquisition. Two detector misses are tolerated, while a third resets convergence. Initializing, excessive-motion, and relocalizing states start a new evidence epoch. As soon as the evidence stabilizes, `AnchorManager` creates or reassociates a generic `Scanning vehicle` anchor and OCR begins enriching that same track. Later OCR remains tied to its reserved detection timestamp but does not demand another same-frame LiDAR pose after localization has already succeeded. The 2D candidate may expire without deleting the world anchor. Anchored tracks stay until explicit removal/reset or terminal session teardown. Reobservation within 0.45 m is treated as the same physical car. ARKit-refined anchor transforms are synchronized back into that reassociation truth so relocalization cannot create a duplicate merely because the world map moved.

Work is bounded: one detector and one OCR operation are allowed in flight; Vision rectangle proposals are capped at 40; full-frame text localization runs only when no appearance-plausible rectangle exists and at most once per 0.40 seconds; each analyzed frame contributes no more than one deterministic target; obsolete frames are dropped before copied snapshots; candidate/history/evidence collections are capped; crop OCR scheduling is fair and backs off to a capped cadence; and RDW calls deduplicate per canonical plate. Every `ARSession.run` suspends admission, drains old callbacks, starts a new callback epoch, and rejects queued pre-run timestamps. Main-actor event delivery is sequence-buffered so a later tracking callback cannot suppress an earlier interruption or failure. Projection resumes only on a fresh normal frame and only when that same frame contains the matching `ARAnchor`. Reset restarts tracking and clears anchors, candidates, presentation state, and the RDW cache; teardown additionally pauses AR. There is no manual-placement or developer-overlay branch in the app target.
