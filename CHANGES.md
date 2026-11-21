# Changes

## 0.9.2

- Fix: automatic release no longer requires 50 GB free. Releasing is what frees space, so with a nearly full disk
  every release was refused and downloads waited for space forever. The 50 GB reserve still applies to downloads.
- Uploaded files are noticed and released sooner: the app checks up to 200 files' iCloud status every few seconds (was 40).

## 0.9.1

- New **Turbo** toggle in the header and the Transfers menu (⇧⌘T). While on, the app copies 10 files at a time whether
  or not the Mac is in use, retries failed files sooner (2 s first, capped at 30 s) and waits only 20 s after a run of
  network failures. Free-space checks are unchanged. The setting is remembered between launches.

## 0.9.0 — first public release

- Copies a MEGA folder into iCloud Drive through your Mac, several files at a time, unattended.
- Quiet automatic retries; one failing file never stops the run.
- Frees local copies automatically once Apple confirms the upload.
- Progress for downloads and uploads, batches and individual files, with time-left estimates and optional speech.
- Resumes after quit, crash or power loss.
- Optional exclusion of Recycle Bin and system folders.
