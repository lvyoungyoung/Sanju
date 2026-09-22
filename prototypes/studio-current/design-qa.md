# Design QA

final result: passed

## Source And Scope

- Selected visual reference: `../three-design-directions/previews/03-studio-home.jpg` and `03-studio-study.jpg`.
- Functional reference: current Swift views listed in `README.md`.
- Implementation: `http://127.0.0.1:8766/`.
- This is a style-preserving functional remix, not a pixel clone of the old concept. Removing invented features and restoring current information architecture is intentional.

## Evidence

- Full side-by-side comparison: `previews/visual-comparison.jpg`, rendered from `visual-comparison.html`.
- Final study view: `previews/study-desktop.jpg`.
- Other inspected views: `previews/new-desktop.jpg`, `previews/result-desktop.jpg`, `previews/memory-detail-desktop.jpg`, `previews/profile-desktop.jpg`, `previews/exercise-desktop.jpg`, `previews/completion-desktop.jpg`.
- Responsive checks: `previews/mobile-home.jpg`, `previews/mobile-empty-topic.jpg`, `previews/mobile-320.jpg`.
- Desktop browser: 1400 × 1100 CSS px; App screen measured 393 × 852 CSS px at scale 1; screenshots 1400 × 1100 pixels.
- Old reference: 390 × 844 pixels; normalized to 393 × 852 for the comparison board. The old concept has no status bar. New native device chrome is excluded from fidelity judgments.
- The comparison board displays the reference and the rendered App crop together at the same width. Main cards, text, navigation, and progress details are legible at this scale; no additional enlarged crop was needed.
- At 390 × 844 and 320 × 740 browser viewports the template scales the device. No horizontal document overflow, broken images, or hidden bottom navigation controls were observed. These checks are for preview usability, not 1:1 iOS screenshots.

## Five Fidelity Surfaces

1. Typography: Avenir Next / PingFang stack retained; clear 34px page titles, 20px sections, 18–19px English sentences, and restrained secondary labels. Longer existing homepage copy intentionally uses a smaller size than the old short concept slogan.
2. Layout: 24px content insets, 25–28px cards, rounded 19px actions, 8px progress bars, light separators, and the concept's pill-like navigation retained. Existing functional grouping replaces the concept's invented content.
3. Color: warm white `#fcfbf8`, orange `#f16b3b`, dark ink `#282a25`, pale apricot and blue retained. Learning overview restored to the stronger orange/white emphasis of option 3.
4. Assets: existing photos and current App collage reused. No stock substitutions or fabricated decorative SVG art. Radix icon library supplies standard UI icons. Photo sizes are constrained; no load errors observed.
5. Copy/content: current two sentence groups, existing actions, daily counters, generation preferences, reminder, Widget and About content represented. No direct sentence learning button, map, word/phrase tabs, or invented photo filters are introduced.

## Findings And Fix History

- P1, fixed: opening/closing input sheets could scroll the outer device viewport, clipping headers and exposing the dismissed keyboard. A prototype-scoped clipping rule leaves inner MobileScroll scrolling intact. Re-tested tag selection, manual typing, dismissing sheets, learning close, and tab changes; outer viewport scroll remains zero.
- P2, fixed: shared button reset overrode the background/border of profile entry cards and the enabled color of switches. Specific component selectors now restore intended styling. Final profile screenshot inspected after the fix.
- P2, fixed: initial learning overview was too pale relative to option 3's focal card. Final comparison uses orange background and white action while retaining the real daily counters.
- P2, fixed: resetting demo state during refresh could leave the spinner visible because its timer was canceled. Navigation/reset now explicitly clears refresh state.
- P3, resolved: duplicate accessible names in the demo photo picker removed by marking images decorative beside their text labels.

No actionable P0/P1/P2 visual issues remain within this prototype's scope.

## Interaction Verification

- Choose photo -> immediate reading state -> preview -> generate -> three sentences in each of two groups -> one new memory; available count changes 24 to 23.
- Memory detail has two groups, playback/favorite actions, no main tab bar, and previous/next controls.
- First create-sheet opening shows three recommendations; chosen recommendation becomes one noneditable input chip; creation enters matching then detail.
- Manual topic with no sample match creates a valid empty detail page.
- Wrong word does not advance; correct completion records once. Closing study returns to its originating detail.
- Completing the three due favorite sentences updates today from 1 to 4; returning shows updated per-sentence counts. Repeating an already studied sentence does not add a second count that day.
- Custom topic study and favorite study use different scope counters.
- Auto-speak toggle persists locally; returned to enabled after QA.
- Beginner starter difficulty disables elegant style and resets selection to plain.
- About is a pushed page; switching tabs then returning to Profile resets to the Profile root.
- Guest create action opens email login; purchase sheet clearly states demo-only status and does not invent a StoreKit price.
- Refresh spinner coexists with four existing topic cards; offline photo selection is disabled.
- Keyboard context menu opens delete confirmation; cancel retains all three topics.
- Browser console: no error-level entries on desktop and small-screen flows.

## Build Checks

- `npm run build`: passed, including TypeScript and integrity checks for 28 protected runtime files.
- `node --test tests/demo-data.test.mjs`: 6/6 passed.
- No iOS build needed: no App or backend source files were edited by this task.

## Remaining Scope Limits

Backend AI, native payments/authentication, full SRS scheduling, OS notifications/photos permissions, dark mode, and English localization are not implemented in this review prototype. Browser TTS availability depends on installed local voices; audible playback is not claimed as verified. See README for demo boundaries.
