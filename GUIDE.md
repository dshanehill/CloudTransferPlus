# Cloud Transfer+ user guide

## What Cloud Transfer+ is

Cloud Transfer+ is a **bridge**. It moves your files from MEGA to iCloud Drive, using your Mac in the middle.

It doesn't replace MEGA's own app. It's a **companion** to MEGA's free helper app, **MEGAcmd**:

- **MEGAcmd** signs you in to MEGA and downloads your files. Your MEGA password stays with MEGA's app.
- **Cloud Transfer+** decides what to copy, puts each file in iCloud Drive, checks it, retries anything that hiccups and
  shows you the progress.
- **iCloud** already works, because you're signed in to your Mac with your Apple ID. You don't enter it anywhere.

## Before you start

You need:

1. A Mac with macOS 14 or later.
2. **MEGAcmd** from MEGA (free).
3. iCloud Drive turned on: System Settings › your name › iCloud › iCloud Drive.
4. Enough iCloud storage for the files you're moving.

## Step 1: the first question

The first time you open Cloud Transfer+, it asks one question:

**"Do you already have MEGAcmd on this Mac?"**

- **Yes, I have it:** the app looks for it and connects it. Done.
- **No, not yet:** the app shows three steps and a button to MEGA's download page:
  1. Download MEGAcmd for Mac from [mega.io/cmd](https://mega.io/cmd).
  2. Open the download and drag MEGAcmd into Applications.
  3. Open MEGAcmd once and sign in to your MEGA account there.

  Then press **I've installed it**.

You only answer this once. If you skip it, you can connect MEGAcmd later under **Connections**.

## Step 2: pick your folders

In **Connections**:

1. **Choose MEGA folder…** Pick the MEGA folder to copy. You can open folders to go deeper.
2. **Choose iCloud folder…** Pick where the files should go in iCloud Drive.
3. Tick **iCloud has room** to confirm your iCloud plan can hold everything.

## Step 3: press Start

Press **Start transfers**. That's it. You can walk away.

- It copies several files at a time, and more while you're away from the Mac.
- **Stepping away?** Press **Turbo** (top right, or ⇧⌘T). It copies 10 files at a time even if someone is using the Mac,
  and retries hiccups sooner. The button turns orange while it's on; press it again to go back to normal. Turbo still
  checks free space before every file, so it can't fill your disk.
- It keeps your Mac awake while copying. The screen and screensaver can still turn on.
- A file that fails is retried quietly a few seconds later. One bad file never stops the run.
- Once Apple confirms a file is uploaded, the local copy is cleared to save disk space. The file stays in iCloud.

## Watching progress

The **Overview** shows:

- **All files:** the whole job, with a time-left estimate.
- **Batch:** the current group of 1,000 files.
- **Downloading from MEGA** and **Uploading to iCloud**, side by side, with the files in progress right now.

Turn on **Sounds** to hear a quiet tick while it works and your progress read out at every 10%.

## Pause, stop and resume

- **Pause after file:** finishes the current files, then waits.
- **Stop now:** stops straight away. Nothing is lost.
- **Resume transfers:** carries on exactly where it left off, even after a restart or power cut.

## Good to know

- Your MEGA files are **never deleted or changed**. Cloud Transfer+ only reads from MEGA.
- Keep your MEGA files until you've checked them in iCloud.
- If you change your MEGA password, open MEGAcmd and sign in again. Until you do, the app keeps waiting quietly.
- Keep your Mac plugged in and online. Closing a laptop lid (without an external display) or shutting down will pause
  the work until you open it again.

Cloud Transfer+ is an independent project and isn't made by MEGA or Apple.
