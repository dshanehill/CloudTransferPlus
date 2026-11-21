# HANDOVER — Cloud Transfer+ (21 Nov 2026, 11:15 Manila)

Read this first. The owner is partially blind and uses VoiceOver: keep instructions short and keyboard-only, and do the
work yourself (he does not want to run commands).

## The one thing to know

**The app on the Mac is in a mixed state.**

- **Running right now:** Cloud Transfer+ **0.9.14** (window footer says "Version 0.9.14"). It is **paused**: the previous
  assistant pressed "Stop work and stay open" while trying to restart it. Progress is saved; **Resume transfers**
  continues it.
- **On disk:** `/Applications/Cloud Transfer+.app` was **overwritten** with a build of *this* repo's `main`
  (`CFBundleShortVersionString` **0.9.0**, build 23, plus Turbo and a release fix). The original 0.9.14 bundle is gone
  from disk (only Time Machine, if any, could restore it).
- **Do not quit the running app** until a correct 0.9.14-based build is installed. If it quits, the 0.9.0-based build
  opens, and it may not read 0.9.14's saved state (`~/Library/Application Support/Cloud Transfer+/`) correctly.

## Where the 0.9.14 source is

Not found yet. It is **not on GitHub**:

- `dshanehill/CloudTransferPlus` (this public repo): 0.9.0 before today's changes.
- `dshanehill/cloud-transfer-plus` (private): newest is **0.9.3** (`main`, branch `claude/interrupted-copies-0.9.3`).
- `dshanehill/cloud-transfer-plus-public` (private): 0.8.x.
- `~/Downloads/Cloud Transfer+ Test/`: launch scripts, old zips and an old HANDOVER only, no source.

So 0.9.14 was built from a local folder on the Mac. Not yet searched: `~/Documents`, `~/Desktop` (need folder access).
Ask the owner, or the agent that built 0.9.14, where it is.

## The problem the owner reported

With under 20 GB free: the MEGA side says "waiting for free space", the iCloud side says "All caught up — Apple has
confirmed every copied file", and **no local copies are being released**, so the disk never frees up.

Owner's requirements, in his words: release a file **as soon as it is uploaded**, don't hold it for no reason, and
don't let the disk fill to ~10 GB free.

### Cause found in the 0.9.0 code (check whether 0.9.14 has the same)

1. `TransferStore.releaseOne` in `Sources/HarborEngine/Store.swift` refused every release unless **50 GB**
   (`Safety.reserve`) was already free:
   `guard available >= Safety.reserve else { throw ... "Insufficient disk reserve for local verification" }`.
   Releasing frees space and needs none, so below 50 GB free it is a deadlock: nothing is released and downloads wait
   forever. Each refused file was set to "needs review" with that note.
2. `refreshUploads` only checked **40** files' iCloud status per 3-second tick, so on big runs, uploaded files waited
   minutes to be noticed.
3. Downloads only start when free ≥ 50 GB + 2 × file size + 1 GB (`Safety.requiredSpace`). With < 20 GB free,
   downloads stay paused until releases bring free space above that. Lowering the 50 GB reserve is the owner's call.

The previous assistant also told the owner Turbo "can't stall on disk space" without checking the release path. It
did stall.

## Changes made today in this repo (port these onto 0.9.14, don't use this repo's build)

All merged into `main` here; the GitHub build passes (`swift run SafetyChecks`, `swift run EngineChecks`).

- **PR #1, Turbo** (branch `turbo`, version 0.9.1 in this repo's `CHANGES.md`)
  - `Store.swift`: `@Published var turbo` (saved in UserDefaults key `turbo`), `static let turboWorkers = 10`;
    `refreshWorkerLimit()` raises `workerLimit` to 10 when Turbo is on; Turbo also shortens the retry backoff
    (2 s start, 30 s cap) and the network cooldown (20 s).
  - `App.swift`: header button `turboButton` (orange "Turbo on" when active, VoiceOver toggle trait), menu item
    Transfers › Turn Turbo On/Off (⇧⌘T), `workerText` mentions Turbo.
  - `Tests/EngineChecks/Runner.swift`: three Turbo checks.
- **PR #2, release fix** (branch `fix-release-space`, version 0.9.2 in this repo's `CHANGES.md`)
  - Removed the 50 GB guard from `releaseOne` (the checksum check and Apple's upload status check stay).
  - `refreshUploads` checks up to **200** files per tick (was 40).
  - New `LowSpace` fixture (5 GB free) and a check that release works below the reserve.

Note: version numbers 0.9.1 and 0.9.2 in this repo clash with the private repo's own 0.9.1–0.9.3. Use new numbers
after 0.9.14.

## How the previous build was installed (works while the app is running)

1. The GitHub Actions run uploads `Cloud-Transfer-Plus` (a zip containing `Cloud-Transfer-Plus.zip`).
2. Unzip twice, then **check `Contents/Info.plist` version is ≥ 0.9.14 before installing.**
3. For each of `Contents/MacOS/CloudTransferPlus`, `Contents/Info.plist`, `Contents/Resources/AppIcon.icns` and
   `Contents/_CodeSignature/CodeResources`: copy to `<file>.new` inside the installed bundle, then `mv -f` over the
   original. The rename leaves the running process's binary untouched.
4. Quit the app (Cloud Transfer+ › Quit). If transfers are active it shows "Transfer work is still active": choose
   **Stop work and stay open**, quit again, then reopen. The app resumes from its saved state.

## Leftovers

- `~/Downloads/Cloud-Transfer-Plus.zip` and `~/Downloads/Cloud-Transfer-Plus (1).zip`: today's 0.9.0-based builds.
  Delete them; don't install them.

## Next steps

1. Find the 0.9.14 source. Confirm its version and that it matches the running app.
2. Check `releaseOne` / `refreshUploads` there for the same 50 GB guard and 40-file limit; apply the fix and add Turbo
   if the owner still wants it.
3. Build, check the version, install as above, restart the app, and confirm in the Activity log that files move to
   "released" and free space goes up.
4. Then settle the 50 GB download reserve with the owner.
