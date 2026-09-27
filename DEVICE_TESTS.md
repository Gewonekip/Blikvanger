# Physical LiDAR Test Checklist

Use a LiDAR-equipped iPhone Pro. The prototype target range is roughly 1–5 m; 5–8 m remains exploratory because persistent placement is limited by reliable LiDAR/mesh evidence even when OCR pixels are readable. Record device, iOS version, lighting, distance, plate type, and the exact on-screen status for each failure.

The repository contains 160 deterministic test methods and CI runs the
simulator test target. CI cannot validate real camera, LiDAR, reflective
plates, 4K thermal behavior, or AR recovery, so the focused smoke round below
is still required before a physical release.

## Next smoke round — do this first

- [ ] Fresh-launch or reset Blikvanger. Confirm the camera view contains only consumer controls, status, and vehicle cards—no aim box, yellow detector outline, HUD, or manual toggle.
- [ ] At 1–5 m, point at one common yellow Dutch plate with the plate clearly visible in any part of the image. Explicitly repeat with it above the former center area, like the reported photo.
- [ ] Hold steadily until status progresses through plate found/measured/reading. The count must change from **No vehicles** to **1 vehicle**, never jump by several.
- [ ] Look fully away, return to the same car, and confirm the count remains **1 vehicle** and the card returns to that car.
- [ ] Keep windows, grilles, gray/white bumper recesses, blank yellow panels, and yellow signs without valid plate text in view. The vehicle count must remain unchanged.
- [ ] Point at a second parked car without deliberately creating a detection gap. The first vehicle must remain and exactly one new vehicle may appear after fresh evidence.

Stop here and record a screen capture plus distance/lighting if any count or placement is wrong. OCR/RDW results are not useful until this spatial and false-positive gate passes.

## Capability, permission, and lifecycle

- [ ] A non-LiDAR iPhone or Simulator shows the unsupported state and never fakes placement.
- [ ] Camera denial shows Blikvanger's recovery screen, opens Settings, and resumes after permission is granted; no unrelated permission is requested.
- [ ] Background and foreground the app. Scanning stays paused until a fresh normally tracked frame; old cards do not flash at stale positions.
- [ ] Interrupt tracking by covering/moving the camera, then recover. Pre-interruption candidate evidence cannot immediately create a label. Existing cards return only after relocalization and matching AR anchors.
- [ ] If camera tracking cannot recover, the top-right reset control restarts scanning even when there are no vehicles.
- [ ] Network inspection confirms camera images are never uploaded; only a confirmed canonical plate is sent to RDW.
- [ ] The installed bundle is an explicit signed Release build and contains no debug/preview dylibs or developer UI strings.

## Automatic localization and pose

- [ ] Test daylight, shade, low light, wet/reflected plates, glare, partial occlusion, and a dirty plate. Strong perspective should either converge on the true projective center or fail safely without a jump.
- [ ] Test standard 520 × 110 mm, compact 310 × 110 mm, and motorcycle 340 × 210 mm plates within roughly 1–5 m. Treat 5–8 m as exploratory only.
- [ ] A one-frame or four-observation plate-like target never creates a permanent label. Two empty detector passes may be tolerated; a third miss resets convergence.
- [ ] A label does not appear immediately: acquisition must still collect repeated visual and measured-position evidence before creating a vehicle.
- [ ] Missing or degenerate mesh data still permits a calibrated depth-backed pose. A spatially broad mesh surface that strongly contradicts depth prevents placement.
- [ ] The generic `Scanning vehicle` label appears at the measured car position before OCR/RDW enrichment. It is never placed at a fixed camera distance or guessed ground point.
- [ ] Make the plate unreadable or look away after placement. The established world label remains; returning to the same car reassociates within the tested tolerance instead of duplicating it.
- [ ] Move the camera from one plate to another before convergence. Measurements from the two targets never combine.
- [ ] Reobserve one car after ARKit map refinement; the adjusted anchor remains the reassociation source and does not duplicate.
- [ ] A moving vehicle never reaches multi-frame stationarity. Blikvanger supports stationary vehicles only; an established label is intentionally frozen rather than following later movement.

## Vehicle lifecycle

- [ ] Ordinary taps on empty camera space never create a vehicle.
- [ ] Walk laterally and toward/away from an automatically found car. Its card remains attached to the same measured place.
- [ ] Confirm the card sits about 0.75 m above the measured base and the leader line still points to the true projection when layout moves it.
- [ ] Remove a single vehicle from details. Its still-live candidate cannot recreate it immediately; a later fresh acquisition is allowed to find it again.
- [ ] Reset removes every vehicle, card, selection, candidate, and cached RDW result.

## OCR and RDW

- [ ] Clear plates rename the existing spatial label only after multiple OCR frames; OCR never moves or replaces the AR anchor.
- [ ] A distant plate that Vision reads as separate groups still resolves, and an official raised duplicate code (for example `1` or `2` above the first dash) is excluded from the six-character RDW query.
- [ ] Immediately after recognition, the bottom status shows the exact formatted plate; it changes to `Checking … with RDW…` and stays visible until RDW returns, even if the AR card leaves the viewport.
- [ ] Unreadable text backs off rather than running accurate OCR every detector frame, and retries again if framing or lighting later improves.
- [ ] Exercise 0/O, 1/I, 2/Z, 5/S, 6/G, and 8/B ambiguity. One transient misread neither renames nor moves a confirmed label.
- [ ] Confirm representative historic/current sidecodes and prohibited combinations.
- [ ] RDW make, trade name, color, first-registration year, and technical fields update the existing card and live details.
- [ ] For offline/cache testing, press Reset first or use a never-looked-up plate. Airplane mode, timeout, empty result, malformed data, and server error preserve the label with an honest unavailable/uncertain state.

## Presentation, accessibility, and endurance

- [ ] Test the live scanner at default text, Accessibility 1, and Accessibility 5. Cards avoid controls; overflow is omitted rather than overlapped; every visible card remains readable.
- [ ] Multiple cards settle deterministically, leader lines retain identity, and a raised card remains available when its base is visible near the top edge.
- [ ] VoiceOver reads plate/name, state, and distance. Details retain per-label removal, and candidate details honestly say plate detection/reading are paused.
- [ ] Scan continuously for 10 minutes. Confirm responsive rendering, bounded memory, no repeated unreadable OCR storm, no leaked work after leaving the view, and acceptable thermal behavior.
