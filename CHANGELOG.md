# Changelog

All notable changes to Claude Monitor are documented here.

## [1.1.0] - 2026-11-10

### Fixed

- Fixed a misleading "Full Disk Access required" state on macOS 26/27.
  `.Spotlight-V100` is additionally protected by macOS and cannot be read
  directly even with Full Disk Access; `mdutil -L` requires root.
- Added an explicit **Administrator Spotlight Read** action. macOS presents the
  administrator authorization prompt, and the app only runs
  `mdutil -L /System/Volumes/Data` read-only. Passwords are never received or
  stored by the app.
- Full Disk Access detection now probes real TCC-protected user paths instead
  of the root-only system index directories.
- Cached administrator Spotlight measurements are preserved across normal
  6-hour index refreshes.
- The setup and settings screens explain the macOS 26/27 protection and the
  additional authorization step.
- Sanitized demo-only paths and documented the ad-hoc code-signing/TCC
  re-authorization behavior.

### Added

- `mdutil -L` output parser with unit coverage.
- GitHub Actions CI for build and smoke tests.
- MIT license, changelog, release assets.

## [1.0.0] - 2026-11-08

- Initial release: menu bar panel, CPU/GPU/memory/disk metrics, power flow,
  Spotlight index scanning, daily storage anomaly detection, notifications,
  settings, vector mascot, and keyboard navigation.
