# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released section below IS the GitHub Release body for that tag: `release.yml` copies the section
verbatim into the release and fails the release if the tag has no section here.

## [Unreleased]

### Fixed

- The copy a piped `irm ... | iex` run saves into your user profile was written with a UTF-8 BOM, which
  then broke running that saved copy through `irm | iex` again - the parser chokes on the leading byte
  order mark. It is now written without one.

## [1.0.1] - 2026-07-19

### Added

- The tool runs from a one-line `irm ... | iex` command. A piped run has no file on disk, and this tool
  writes its undo files next to the script, so the run saves itself into your user profile first and reruns
  from there - the `.reg` files land beside it and survive, which they would not have in `%TEMP%`. An
  existing copy that differs is kept as `.bak` rather than overwritten, and `-ShowAll` / `-Reset` carry
  through the rerun and the UAC prompt.
- Published to the PowerShell Gallery: `Install-Script interrupt-affinity-utility`.
- Every tagged release ships a `SHA256SUMS.txt` alongside the script plus a signed build-provenance
  attestation, so you can verify the file you downloaded is the one the workflow built from this source.

### Fixed

- The script is now pure ASCII with no BOM, and a CI check keeps it that way: a BOM would break
  `irm | iex`, and non-ASCII in a BOM-less file turns into mojibake when Windows PowerShell 5.1 runs it
  with `-File`.

## [1.0.0] - 2026-07-18

### Added

- First release. Lists your PCI devices with their current interrupt affinity policy in a grid, then pins
  the interrupts of the devices you pick to the cores you pick in a second grid - P-cores and E-cores are
  labeled on hybrid CPUs. It writes the documented `DevicePolicy` / `AssignmentSetOverride` values and
  nothing else.
- `-Reset` removes the override from the selected devices and restores the machine default; `-ShowAll`
  includes the bridges and abstract controllers that are hidden by default.
- Two undo files, written before any change: `affinity_undo_<stamp>.reg` reverts that one run, and the
  cumulative `affinity_undo_original.reg` records each device's state the first time this tool ever touched
  it - so one file restores the machine to how it was before you started, however many runs ago that was.
- The undo files round-trip a value in its original registry type, including string and multi-string values
  written by some other tool, so reverting restores exactly what was there rather than a DWORD
  approximation.
- The scan survives registry values it did not write: a `DevicePolicy` that is non-numeric or out of range
  is shown as `Unknown (...)` instead of aborting the whole scan, and an `AssignmentSetOverride` in an
  unreadable type is shown as `Unreadable (...)` instead of quietly passing for "no override".
- Device names with a literal semicolon are no longer truncated, and the indirect-string prefix is stripped
  only from values that actually have one.
- Intel SST audio controllers (`IntcAudioBus`) are in the default device list, not just under `-ShowAll`.
- Reports a clear, up-front error when `Out-GridView` is unavailable - PowerShell 7 ships without it and
  Server Core has none at all - instead of failing halfway through the run.
- Self-elevates through UAC and keeps the elevated window open on both success and error. Zero external
  dependencies, Windows PowerShell 5.1+.

[Unreleased]: https://github.com/vadyaravadim/interrupt-affinity-utility/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/vadyaravadim/interrupt-affinity-utility/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/vadyaravadim/interrupt-affinity-utility/releases/tag/v1.0.0
