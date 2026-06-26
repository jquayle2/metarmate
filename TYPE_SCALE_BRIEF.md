# MetarMate — Type Scale + Row Spacing Polish Brief

## Goal
On the Nearest (and Alerts, which shares the row) list:
1. Raise the minimum text size by one step — what renders at the smallest iOS Dynamic Type setting should look like today's second-smallest. In effect, shift the whole type scale up one notch so the FLOOR is one level higher. (Do NOT just enlarge everything at all settings — large settings already overflow; the point is to lift the bottom.)
2. Reduce the vertical gap between airport rows — at larger Dynamic Type sizes the rows balloon with too much space between them.
3. Fix the "Sorted by distance · Updated X sec ago" subtitle in NearestAirportsView — it wraps/garbles at large Dynamic Type sizes.

## Where things live
- `MetarMate/Views/SharedComponents.swift` — `AirportRowView` (starts ~line 113). This row is SHARED by both the Nearest list and the Alerts list, so changes here affect both — that's desired (keeps them consistent).
- `MetarMate/Views/NearestAirportsView.swift` — the `nearestSubtitle` computed view (the "Sorted by distance…" line) and the List row insets.

## How the row is currently built (semantic styles — they DO scale with Dynamic Type)
- ICAO: `.system(.headline …).weight(.bold)`
- IATA: fixed `.system(size: 11)`
- Airport name: `.subheadline`
- Weather summary (sky/vis/wind), "Advisory weather only", "METAR unavailable", distance: `.caption` / `.caption2`
- Row vertical padding: `.padding(.vertical, 8)` on the inner HStack, plus `.padding(.vertical, 6)` on the category strip.

## Task 1 — raise the type floor (step each line up one semantic level)
Preferred approach: bump each semantic style up one step so the whole scale (including the minimum) rises one notch:
- `.caption2` -> `.caption`
- `.caption`  -> `.subheadline`
- `.subheadline` (airport name) -> `.body` OR `.callout` (pick whichever keeps one-line fit; callout is slightly smaller than body)
- ICAO `.headline` -> `.title3` is likely too big; leave ICAO at `.headline` (it's already prominent) UNLESS it looks unbalanced after the body lines grow — use judgment.
- The fixed IATA `.system(size: 11)` should become a semantic style too (e.g. `.caption2`) so it scales with the rest instead of staying pinned at 11pt.
Apply the same to the Alerts `WatchRow` freshness/failing-factors lines so the two lists stay matched (check AlertsView.swift — if WatchRow reuses AirportRowView pieces, this may be automatic; if it has its own `.caption2` lines, bump them too).

Alternative if stepping styles looks wrong: clamp the list with `.dynamicTypeSize(.small ... .accessibility3)` to lift the floor. But stepping the styles is preferred because it's a true one-notch shift across the whole range.

## Task 2 — tighten inter-row spacing
- Reduce `.padding(.vertical, 8)` on the row's inner HStack to ~4-5.
- Check the List `.listRowInsets` in NearestAirportsView and AlertsView; if they add extra vertical inset, trim so rows sit closer.
- Goal: rows feel compact at large Dynamic Type, not floaty. Verify at both smallest and a large accessibility size.

## Task 3 — fix the subtitle wrap/garble
In `NearestAirportsView.nearestSubtitle`: the single-line HStack of `.caption` text ("Sorted by distance · Updated X sec ago") garbles at large sizes.
- Allow it to wrap to two lines gracefully (remove any implicit single-line constraint / give it room), OR
- Apply `.minimumScaleFactor(0.8)` and `.lineLimit(1)` so it shrinks instead of garbling, OR
- Drop the "· " separator to a line break at large sizes.
Pick the cleanest; wrapping to two lines is usually fine for a subtitle.

## Constraints (do not regress)
- COLOR AXES unchanged: category strip = category colors; wind text = amber/red wind palette; verdict badge (alerts) = red/green. Only font SIZES change here, not colors.
- Keep `.lineLimit(1)` on the weather summary and airport name so they truncate cleanly rather than wrapping mid-row (the name already truncates with "…" — that's fine and expected).
- Test at BOTH the smallest Dynamic Type and a large accessibility size before committing.

## Build / commit
- `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5`
- Commit points: (a) type-floor step-up, (b) row spacing, (c) subtitle fix. Or one combined commit if cleaner.
- No `#` in terminal commands; single-line, chain with && or ;.

## Files expected to change
- MetarMate/Views/SharedComponents.swift (AirportRowView fonts + padding)
- MetarMate/Views/NearestAirportsView.swift (subtitle, row insets)
- MetarMate/Views/AlertsView.swift (WatchRow fonts, if not auto-covered)


---

## Clarification: spacing must be tightened on BOTH Nearest AND Alerts equally
Row fonts are shared via AirportRowView, so Task 1 covers both lists automatically. But inter-row SPACING comes from two sources and is only partly shared:
- `.padding(.vertical, 8)` inside AirportRowView — shared, trimming helps both lists.
- Per-list `.listRowInsets` — set separately in each view. Alerts currently uses `EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 16)`; Nearest sets its own.

Requirement: treat Nearest and Alerts as EQUAL targets for the spacing tightening. After the change, the row-to-row gap should look the same on both lists at the same Dynamic Type size. Explicitly trim the listRowInsets in BOTH NearestAirportsView and AlertsView (not just Nearest), and verify side by side that the two lists have matching, compact spacing at both a small and a large Dynamic Type setting. Do not leave Alerts looser than Nearest or vice versa.
