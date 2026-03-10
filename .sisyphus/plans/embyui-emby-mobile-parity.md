## Goal

Improve `lib/emby_exclusive_ui.dart` so the Emby-exclusive surface feels closer to the real Emby mobile app while preserving Glacier's own identity as an Android-first unified media browser.

## Repo-grounded constraints

- Keep Glacier as the host product instead of cloning Emby branding or assets.
- Reuse the existing Emby data and playback pipeline in `lib/emby_read_scheme.dart`, `lib/emby.dart`, and `lib/video.dart`.
- Favor mobile-first, low-jank interactions and stable fallbacks.

## Planned changes

1. Home screen
   - Add a stronger hero area centered on continue-watching content.
   - Preserve current tab model, but make the visual hierarchy closer to Emby mobile: hero -> continue watching -> latest sections -> favorites/search.
   - Reuse existing resume and section data instead of adding new API requirements.

2. Series detail
   - Make the page more Emby-like by strengthening the hero metadata area, action strip, continue-watching block, and season/episode affordances.
   - Add explicit next-up style guidance using the existing continue episode list.
   - Keep navigation routed through `VideoPlayerPage` and existing folder/detail pages.

3. Movie detail
   - Upgrade metadata presentation and action layout.
   - Add richer contextual rows using already available metadata fields.

4. Shared polish
   - Add reusable chips/section wrappers/stat rows where it reduces duplication.
   - Fix any obvious text/encoding glitches encountered in the touched views.

## Verification

1. Run diagnostics on modified Dart files.
2. Run `flutter test`.
3. Run `flutter analyze`.
4. Run `flutter build apk --debug` if the project builds in this environment.
