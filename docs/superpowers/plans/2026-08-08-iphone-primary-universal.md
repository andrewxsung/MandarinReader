# iPhone-Primary Universal App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iPad-only MandarinReader app universal, with iPhone (finger input, portrait) as the primary device.

**Architecture:** No new code units. The handwriting canvas already accepts finger input via `DragGesture` and the stroke matcher works in a size-independent 1024×1024 data space. The work is: Xcode target settings (device family + iPhone portrait lock), then iPhone-first size adjustments in two SwiftUI views, then verification on the iPhone simulator (primary) and iPad simulator (regression smoke check).

**Tech Stack:** SwiftUI, xcodebuild, iOS Simulator (iPhone 17 primary, iPad Pro 11-inch smoke check). Spec: `docs/superpowers/specs/2026-08-08-iphone-primary-universal-design.md`

**Note on TDD:** Every task here is either build-settings or pure SwiftUI layout sizing, which has no unit-test seam in this codebase. The test gate is: the existing device-independent unit suite (StrokeMatcher, HandwritingQuiz, geometry, coordinates, API) must pass on an **iPhone** simulator destination — it previously only ever ran on iPad. Visual correctness is verified with simulator screenshots. Do not add new ObservableObject-based tests (see iOS gotchas in project memory: Xcode 26 crashes).

**Build/test commands used throughout** (run from repo root `/Users/andrewsung/MandarinReader`):

```bash
# Build for iPhone
xcodebuild -project ios/MandarinReader/MandarinReader.xcodeproj \
  -scheme MandarinReader \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Full unit test suite on iPhone
xcodebuild -project ios/MandarinReader/MandarinReader.xcodeproj \
  -scheme MandarinReader \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:MandarinReaderTests test
```

---

### Task 1: Universal device family + iPhone portrait lock

**Files:**
- Modify: `ios/MandarinReader/MandarinReader.xcodeproj/project.pbxproj`

The app target has two build configurations with `TARGETED_DEVICE_FAMILY = 2` (blocks A0EE64322F8C22CE00354FF3 /* Debug */ and A0EE64332F8C22CE00354FF3 /* Release */, around lines 426 and 463). The test targets already say `"1,2"` — do not touch them.

- [ ] **Step 1: Set device family to universal in both app configs**

In `project.pbxproj`, replace **both** occurrences of:

```
				TARGETED_DEVICE_FAMILY = 2;
```

with:

```
				TARGETED_DEVICE_FAMILY = "1,2";
```

(Exactly two occurrences exist; both belong to the app target. Verify with `grep -c 'TARGETED_DEVICE_FAMILY = 2;' ios/MandarinReader/MandarinReader.xcodeproj/project.pbxproj` → expect `0` after the edit.)

- [ ] **Step 2: Lock iPhone to portrait in both app configs**

Replace **both** occurrences of:

```
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
```

with:

```
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = UIInterfaceOrientationPortrait;
```

Leave `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` unchanged.

- [ ] **Step 3: Build for iPhone simulator**

Run the iPhone build command from the header.
Expected: `** BUILD SUCCEEDED **`. (Before this task, an iPhone destination would not even resolve.)

- [ ] **Step 4: Build for iPad simulator (regression)**

```bash
xcodebuild -project ios/MandarinReader/MandarinReader.xcodeproj \
  -scheme MandarinReader \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ios/MandarinReader/MandarinReader.xcodeproj/project.pbxproj
git commit -m "Make app universal (iPhone + iPad), portrait-locked on iPhone"
```

---

### Task 2: StartSessionView iPhone-first sizing

**Files:**
- Modify: `ios/MandarinReader/MandarinReader/Views/StartSessionView.swift`

Two compact-width problems: the 48pt bold title ("MandarinReader" ≈ 370pt wide at 48pt, overflows a 390pt screen) and the Stepper's 64pt horizontal padding (leaves ~262pt for its label + controls).

- [ ] **Step 1: Shrink the title**

Change:

```swift
                Text("MandarinReader")
                    .font(.system(size: 48, weight: .bold))
```

to:

```swift
                Text("MandarinReader")
                    .font(.system(size: 36, weight: .bold))
```

- [ ] **Step 2: Reduce Stepper padding**

Change:

```swift
                        .padding(.horizontal, 64)
```

to:

```swift
                        .padding(.horizontal, 24)
```

- [ ] **Step 3: Build for iPhone simulator**

Run the iPhone build command from the header.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/MandarinReader/MandarinReader/Views/StartSessionView.swift
git commit -m "Size start screen for compact width"
```

---

### Task 3: PracticeView iPhone-first sizing

**Files:**
- Modify: `ios/MandarinReader/MandarinReader/Views/PracticeView.swift`

Two compact-width problems, both in fixed 100pt+ font sizes: the flash character (a 4-character word at 100pt ≈ 400pt, overflows) and the keyboard-fallback TextField (120pt: any 3+ character word overflows). The canvas, progress row, and controls already fit — do not change them.

- [ ] **Step 1: Make the flash character fit any word on compact width**

In `infoBar(for:)`, change:

```swift
            if session.phase == .flash && flashVisible {
                Text(word.traditional)
                    .font(.system(size: 100, weight: .regular))
                    .transition(.opacity)
            }
```

to:

```swift
            if session.phase == .flash && flashVisible {
                Text(word.traditional)
                    .font(.system(size: 80, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            }
```

- [ ] **Step 2: Shrink the keyboard-fallback TextField font**

In `keyboardPanel`, change:

```swift
            TextField("", text: $input)
                .font(.system(size: 120, weight: .regular))
```

to:

```swift
            TextField("", text: $input)
                .font(.system(size: 72, weight: .regular))
```

(TextField cannot use `minimumScaleFactor`; 72pt fits a 4-character word in ~326pt inside the panel's padding on a 390pt screen.)

- [ ] **Step 3: Build for iPhone simulator**

Run the iPhone build command from the header.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/MandarinReader/MandarinReader/Views/PracticeView.swift
git commit -m "Size practice screen text for compact width"
```

---

### Task 4: Unit suite passes on iPhone destination

**Files:** none modified.

- [ ] **Step 1: Run the full unit suite on the iPhone simulator**

Run the test command from the header.
Expected: `** TEST SUCCEEDED **` — all existing tests (StrokeMatcherTests, HandwritingQuizTests, HanziGeometryTests, CanvasCoordinatesTests, SVGPathParserTests, APIClientTests, AppSettingsTests, SessionViewModelTests, ModelsTests, StrokeDataStoreTests) pass unmodified.

If anything fails, stop and diagnose before proceeding (superpowers:systematic-debugging); these tests are device-independent, so a failure means a real regression, not a device quirk.

---

### Task 5: Visual verification — iPhone primary, iPad smoke check

**Files:** none planned — only modified if a screenshot reveals an overflow, in which case fix in the responsible view and commit with an explanatory message.

Use the iOS Simulator MCP tool (`mcp__Claude_Code_iOS_Simulator__control`): `attach` first so the user can watch, then `launch` with the built app, then `screenshot` for proof. If the MCP tool is unavailable, fall back to `xcrun simctl` (`boot`, `install`, `launch`, `io screenshot`). Bundle id: `com.andrewsung.MandarinReader`.

- [ ] **Step 1: Launch on iPhone 17 simulator and screenshot the start screen**

Verify: title fits on one line, Stepper + Start Practice button fully visible, no clipping. Also tap the gear icon and screenshot the Settings sheet (spec: verify-only, adjust only on overflow), then dismiss it.

- [ ] **Step 2: Walk the practice flow with finger-style taps/drags**

The backend is likely not running; expect the queue fetch to fail — that still verifies the start screen renders and the error message fits. If the backend at the configured URL is reachable, go further: start a session, screenshot the flash phase (character fits), draw a stroke on the canvas with a `touch_path` drag (verifies finger input registers), and screenshot the writing phase showing the canvas at full width.

- [ ] **Step 3: Verify portrait lock**

Rotate the iPhone simulator (Device → Rotate Left, or `simctl` has no rotation — use the panel/Simulator menu). Screenshot: the app must stay portrait.

- [ ] **Step 4: iPad smoke check**

Launch on iPad Pro 11-inch (M5) simulator, screenshot the start screen. Verify: layout centered, nothing regressed (title may simply look slightly smaller than before — acceptable per spec).

- [ ] **Step 5: Share screenshots with the user**

Send the iPhone start-screen, practice/flash (if reachable), and iPad screenshots via SendUserFile with a one-line caption each.

- [ ] **Step 6: Commit (only if fixes were made during verification)**

```bash
git add -A ios/MandarinReader/MandarinReader/Views
git commit -m "Fix compact-width overflow found in simulator verification"
```
