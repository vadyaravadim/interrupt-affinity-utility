# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released section below IS the GitHub Release body for that tag: `release.yml` copies the section
verbatim into the release and fails the release if the tag has no section here.

## [Unreleased]

### Added

- `-Status` prints every device with its current policy and cores and changes nothing. It needs no admin
  rights, so checking whether a pin survived a driver or Windows update no longer costs a UAC prompt and a
  grid you have to cancel.

### Changed

- A successful run now ends with one line linking to this repo and asking for a star, so people who got
  the one-liner from an article or a chatbot know where the tool lives. It is printed only when a device
  was pinned: not with `-Reset`.

### Fixed

- Selecting a device that was already pinned to the chosen cores - or, with `-Reset`, one that had no
  override - wrote another undo file and reported the device as updated (`[RESET]` for a device that had
  nothing to reset). Such devices are now skipped, and a run that changes nothing writes no undo file.
- Hardware that was removed from the PC (an old graphics card after an upgrade) still showed up in the
  list, and pinning it reported success while changing nothing. Only connected devices are listed now.

## [1.0.3] - 2026-09-23

### Added

- The banner shows the script version (`INTERRUPT AFFINITY UTILITY v1.0.3`), so you can tell at a glance
  whether the copy you are running is the current release - and a bug report that includes the output says
  which version it is about. A copy cloned or zipped from `main` rather than taken from a release says
  `dev build`.

### Changed

- The `irm ... | iex` one-liner, and the copy it saves into your user profile, now download the latest
  tagged release instead of whatever sits on `main`. Until now the one-liner ran - as Administrator - a
  file that had not been through the release checks and had no checksum or provenance behind it. It is
  now byte-for-byte the release asset, so `SHA256SUMS.txt` and `gh attestation verify` cover it too. The
  old command keeps working; swap the URL for the one in the README when convenient.
- A release is no longer published unless `lint` and `ascii-check` pass on the tagged commit.

### Fixed

- `Run.bat -ShowAll` and `Run.bat -Reset` now do what they say. `Run.bat` dropped everything typed after
  its name, so `Run.bat -Reset` quietly opened the normal pinning run instead of removing the override.
  The README now lists a working command for passing `-ShowAll` / `-Reset` under each install method.
- The "Out-GridView is not available" message no longer tells you to install the
  `Microsoft.PowerShell.GraphicalTools` module, and the README no longer claims PowerShell 7 needs it.
  PowerShell 7 on a desktop edition of Windows has `Out-GridView` built in; it is missing only on Server
  Core, where no module brings it back.

## [1.0.2] - 2026-09-05

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

- First release. Lists the latency-critical PCI devices - GPU, network, USB and audio controllers - with
  their current interrupt affinity policy in a grid, then pins the interrupts of the devices you pick to
  the cores you pick in a second grid. P-cores and E-cores are labeled on hybrid CPUs, and on an SMT CPU a
  physical-core column shows which logical processors are siblings of the same core. It writes the
  documented `DevicePolicy` / `AssignmentSetOverride` values and nothing else.
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
- Self-elevates through UAC and keeps the elevated window open on both success and error. Runs on Windows
  10 and Windows 11 with Windows PowerShell 5.1 or newer, and depends on nothing outside Windows.
- Validated on Windows 11 with Windows PowerShell 5.1 before release: 43 function-level tests plus a full
  elevated end-to-end run - pin, an external change made behind the tool's back, re-pin, apply the per-run
  undo, apply the original undo, then reset - including a real `reg.exe import` round-trip of every value
  type.

[Unreleased]: https://github.com/vadyaravadim/interrupt-affinity-utility/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/vadyaravadim/interrupt-affinity-utility/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/vadyaravadim/interrupt-affinity-utility/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/vadyaravadim/interrupt-affinity-utility/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/vadyaravadim/interrupt-affinity-utility/releases/tag/v1.0.0
