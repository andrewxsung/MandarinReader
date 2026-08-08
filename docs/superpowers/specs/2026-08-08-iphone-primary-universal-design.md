# iPhone-Primary Universal App — Design

**Date:** 2026-08-08
**Status:** Approved by Andrew

## Goal

Make the existing iPad handwriting-practice app run on iPhone with finger
input, with iPhone as the primary device. iPad keeps working unchanged in
behavior (it just gets more whitespace).

## Context

The app is currently iPad-only (`TARGETED_DEVICE_FAMILY = 2`). Nothing in the
code is Pencil-specific:

- `HandwritingCanvasView` uses a plain `DragGesture`, which handles finger
  input identically.
- `StrokeMatcher` is a port of hanzi-writer whose thresholds operate in a
  normalized 1024×1024 data space and are the same defaults hanzi-writer uses
  on mobile web with finger input. No tolerance changes needed initially;
  `StrokeMatcher.match(leniency:)` already exists as a one-line knob if
  finger input proves too strict in practice.

The work is therefore: target change + iPhone-first layout sizing +
verification on an iPhone simulator.

## Decisions

1. **Universal target** — `TARGETED_DEVICE_FAMILY = "1,2"` on the app target
   (Debug and Release). Test targets follow the app target.
2. **iPhone portrait-locked** — `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`
   becomes portrait only. Portrait is the only orientation that gives the
   square canvas full width on a phone. iPad orientations unchanged.
3. **iPhone-first sizing** — base fonts/paddings chosen for a ~390pt-wide
   screen; iPad gets extra whitespace via the existing centering/max-width
   behavior. No `horizontalSizeClass` layout branch.
4. **No matcher changes** — leniency stays 1.0. Revisit only if real finger
   use feels too strict.
5. **iPhone-first verification** — build and screenshot-check on an iPhone
   simulator as the primary gate; sanity-check iPad for regressions.

## Layout changes (iPhone-first sizing)

All in existing SwiftUI views; adjust only what a ~390pt-wide portrait screen
requires:

- **StartSessionView**: title 48pt → a single smaller base size chosen to
  fit compact width (no size-class branching); Stepper's 64pt horizontal
  padding reduced so it fits.
- **PracticeView**:
  - Flash character 100pt → sized to fit compact width (multi-character
    words like 記住 must not truncate).
  - Keyboard-fallback TextField 120pt font → sized so 2–4 character words
    fit the width.
  - Vertical stack tightened so the canvas sits in the natural writing zone
    and takes full width minus minimal horizontal padding — maximize the
    writing surface.
  - Character progress row (52pt boxes) verified for typical 1–4 character
    words on compact width.
- **HandwritingCanvasView**: no changes — it already sizes itself to the
  smaller of width/height and scales ink width (`side/24`) proportionally.
- **SummaryView / SettingsView**: verify on compact width; adjust only if
  something overflows.

## Error handling / edge cases

- Words whose characters lack stroke data already fall back to the keyboard
  panel; that path must also fit compact width.
- Session recovery banner on StartSessionView must fit compact width.

## Testing

- Existing unit tests (matcher, quiz, geometry, coordinates) are
  device-independent and must keep passing.
- Manual/simulator verification: iPhone 16 simulator — start screen,
  practice flow (flash → write → feedback), multi-character word, keyboard
  fallback, summary. Screenshot proof.
- iPad simulator smoke check: practice screen renders as before.

## Out of scope

- Separate compact/regular layout branches (`horizontalSizeClass`).
- Stroke-match tolerance tuning.
- Any backend or extension changes.
