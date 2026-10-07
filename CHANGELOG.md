# Changelog

Versions are listed in ascending order, matching the in-app About page. Earlier history remains available in the app; 0.4.1 is the release prepared for this repository.

## 0.4.0 — 2026-10-07 (local release)

- Corrected preview cropping, oversized empty areas, low-resolution image sizing, and scrolling for large window lists.
- Used stable window identities so same-title windows do not share thumbnails.
- Kept the last successful thumbnail when capture fails; bounded background capture work and memory use.
- Removed stale previews when hovering an app without windows.
- Introduced native Liquid Glass on macOS 26+, interactive glass on macOS 27, and frosted fallback material.
- Implemented configurable window-switching shortcuts and experimental active-app Dock-click minimization.
- Replaced feature checkboxes with native switches and added login startup, menu bar visibility, and language controls.
- Improved menu updates, preference validation, and ascending release notes.

## 0.4.1 — 2026-10-07

### Window interaction

- Added mouse-press or mouse-release selection; release is the default and supports cancelling by moving outside the pressed thumbnail.
- Added a single Close all windows of this app command through the preview's context menu. Apps retain control of unsaved-document prompts.
- Expanded window discovery to include other Spaces and retained usable cached thumbnails for minimized and off-desktop windows.
- Gave cross-Space activation priority over experimental Dock-click minimization.

### Settings and appearance

- Restored the visible Settings title; disabled minimize and zoom buttons for the fixed-size settings window.
- Kept rectangular native page navigation at the top and added a subtle content border and background.
- Added 0.05-second adjustment buttons to duration fields and ended editing on background clicks.
- Animated fade-duration rows and coordinated window-height changes.
- Accelerated pop dismissal continuously and hid the whole panel at the animation endpoint.
- Resampled current-desktop, visible, unminimized windows after theme or material changes, while keeping inactive caches.

### About and documentation

- Standardized the main heading as DockPeek V0.4.1 and removed the duplicate version label.
- Made About text selectable and added AI credits, an email feedback link, and a matching GitHub button in a fixed footer outside the scrolling release notes.
- Made English the default for new installations without overwriting existing language choices.
- Added English documentation, screenshots, installation and source downloads, and the MIT License.

Cross-Space activation and close requests use public macOS APIs and remain subject to target-app and system behavior. Moving third-party windows to the current Space is intentionally unavailable.
