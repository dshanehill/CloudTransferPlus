import SwiftUI
import AppKit
import HarborCore
import HarborEngine

let ink = Color(red: 0.09, green: 0.14, blue: 0.23)
// Darker than before so secondary text meets WCAG AA contrast on white.
let muted = Color(red: 0.30, green: 0.34, blue: 0.41)
let accent = Color(red: 0.20, green: 0.31, blue: 0.85)
let canvas = Color(red: 0.96, green: 0.97, blue: 0.985)
func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal) }

/// Text size multiplier, set from View > Text Size (⌘+ / ⌘−). Stored in UserDefaults by TransferStore.
func fs(_ size: CGFloat) -> CGFloat { (size * uiScale).rounded() }

@main struct CloudTransferApp: App {
    @NSApplicationDelegateAdaptor(TransferLifecycle.self) private var lifecycle
    @StateObject private var store: TransferStore
    init() {
        #if INTERFACE_CHECK
        _store = StateObject(wrappedValue: InterfaceCheck.makeStore())
        #else
        // A single persistent live workspace; no environment flags or terminal launcher.
        // CLOUD_TRANSFER_TEST_WORKSPACE (absolute path) runs a separate, isolated history for controlled live tests,
        // so the user's main queue is never used as a test. Normal launches ignore it.
        let override = ProcessInfo.processInfo.environment["CLOUD_TRANSFER_TEST_WORKSPACE"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        let support = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cloud Transfer+/Live", isDirectory: true)
        _store = StateObject(wrappedValue: TransferStore(supportURL: support, feedback: SystemFeedback(), parallel: .adaptive(active: 3, idle: 6, idleAfter: 120), autoReleaseByDefault: true, quietRetries: true))
        #endif
    }
    var body: some Scene {
        WindowGroup("Cloud Transfer+") { Dashboard().environmentObject(store).onAppear { lifecycle.store = store }.frame(minWidth: 1180, minHeight: 760).preferredColorScheme(.light) }
            .defaultSize(width: 1440, height: 900)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) { Button("Export transfer report…") { store.exportReport() }.keyboardShortcut("e", modifiers: [.command, .shift]) }
                CommandMenu("Transfers") {
                    Button("Exclude Recycle Bin and System Files") { store.excludeSystemJunk() }.disabled(store.running || store.busy || store.demo)
                    Divider()
                    Button(store.turbo ? "Turn Turbo Off" : "Turn Turbo On") { store.turbo.toggle() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(store.demo)
                }
                CommandMenu("Sound") {
                    Button(store.soundsMuted ? "Turn Sounds On" : "Mute Sounds") { store.soundsMuted.toggle() }.keyboardShortcut("m", modifiers: [.command, .shift])
                    Button("Speak Progress Now") { store.speakProgressNow() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(store.soundsMuted)
                }
                CommandMenu("Text Size") {
                    Button("Bigger Text") { store.textScale = min(store.textScale + 0.15, 2.5) }.keyboardShortcut("+", modifiers: .command)
                    Button("Smaller Text") { store.textScale = max(store.textScale - 0.15, 0.8) }.keyboardShortcut("-", modifiers: .command)
                    Button("Default Text Size") { store.textScale = 1.25 }.keyboardShortcut("0", modifiers: .command)
                }
            }
    }
}

struct Dashboard: View {
    @EnvironmentObject var store: TransferStore
    @AppStorage("welcomeAnswered") private var welcomeAnswered = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 218 * min(uiScale, 1.6))
            VStack(spacing: 0) {
                header
                #if INTERFACE_CHECK
                Text("INTERFACE CHECK — simulated providers; no real cloud account").font(.headline).padding(8).frame(maxWidth: .infinity).background(.yellow)
                #endif
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if store.tab == "Connections" { connections }
                        else if store.tab == "Activity" { activity }
                        else { overview }
                    }.padding(30)
                }.background(canvas)
                footer
            }
        }
        .foregroundStyle(ink)
        .sheet(isPresented: $store.showingSourcePicker) { MEGAFolderPicker().environmentObject(store) }
        .sheet(isPresented: Binding(get: { !welcomeAnswered }, set: { if !$0 { welcomeAnswered = true } })) { WelcomeSheet { welcomeAnswered = true }.environmentObject(store) }
        .id(store.textScale) // redraw everything when the text size changes
        .alert(store.error != nil ? "Attention required" : "Done", isPresented: Binding(get: { store.error != nil || store.notice != nil }, set: { if !$0 { store.error = nil; store.notice = nil } })) {
            Button("OK") { store.error = nil; store.notice = nil }
        } message: { Text(store.error ?? store.notice ?? "") }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 52 * min(uiScale, 1.6), height: 52 * min(uiScale, 1.6)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) { Text("Cloud Transfer").font(.system(size: min(fs(17), 28), weight: .bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true); Text("PLUS").font(.system(size: fs(10), weight: .bold, design: .rounded)).tracking(3).foregroundStyle(Color.white.opacity(0.75)) }
                Text("+").font(.system(size: 24 * min(uiScale, 1.6), weight: .medium)).foregroundStyle(Color(red: 0.66, green: 0.74, blue: 1)).accessibilityHidden(true)
            }.padding(.top, 43).padding(.bottom, 42).padding(.horizontal, 20)
            Text("WORKSPACE").font(.system(size: fs(10), weight: .semibold)).tracking(1.8).foregroundStyle(.white.opacity(0.72)).padding(.horizontal, 25).padding(.bottom, 14)
            ForEach([("Overview", "square.grid.2x2"), ("Transfers", "arrow.left.arrow.right"), ("Activity", "clock.arrow.circlepath"), ("Connections", "externaldrive.connected.to.line.below")], id: \.0) { title, icon in
                Button { store.tab = title } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon).frame(width: 20).accessibilityHidden(true)
                        Text(title).font(.system(size: fs(13), weight: .medium)); Spacer()
                        if title == "Transfers" { Text("\(store.transfers.count)").font(.system(size: fs(10), weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3).background(.white.opacity(0.14), in: Capsule()) }
                    }
                    .foregroundStyle(store.tab == title ? .white : .white.opacity(0.82)).padding(.horizontal, 15).padding(.vertical, 12)
                    .background(store.tab == title ? .white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).padding(.horizontal, 13).padding(.bottom, 5)
                .accessibilityAddTraits(store.tab == title ? .isSelected : [])
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: "shield.lefthalf.filled").foregroundStyle(Color(red: 0.55, green: 0.9, blue: 0.78)).accessibilityHidden(true); Text("Originals preserved").font(.system(size: fs(12), weight: .semibold)) }
                Text("Cloud Transfer+ never deletes your MEGA originals.").font(.system(size: fs(11))).foregroundStyle(.white.opacity(0.8)).lineSpacing(4)
            }.padding(16).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)).padding(15)
            Divider().overlay(.white.opacity(0.15)).padding(.horizontal, 20)
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").font(.system(size: fs(17))).foregroundStyle(.white.opacity(0.85)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) { Text("This Mac").font(.system(size: fs(12), weight: .semibold)); Text("Local transfer engine").font(.system(size: fs(10))).foregroundStyle(.white.opacity(0.75)) }
                Spacer(); Circle().fill(.green).frame(width: 6, height: 6).accessibilityHidden(true)
            }.padding(22)
        }.foregroundStyle(.white).background(LinearGradient(colors: [Color(red: 0.085, green: 0.12, blue: 0.2), Color(red: 0.06, green: 0.085, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    var header: some View {
        HStack {
            Text("Workspace").foregroundStyle(muted); Image(systemName: "chevron.right").font(.system(size: fs(9))).foregroundStyle(muted).accessibilityHidden(true); Text(store.tab).fontWeight(.medium)
            Spacer()
            if !store.progressSummary.isEmpty {
                Text(store.progressSummary).font(.system(size: fs(12), weight: .semibold)).monospacedDigit().padding(.trailing, 10)
                    .accessibilityLabel(store.progressSummary.replacingOccurrences(of: "%", with: " percent"))
            }
            Button { store.speakProgressNow() } label: { Image(systemName: "waveform") }.buttonStyle(.plain).disabled(store.soundsMuted || store.demo)
                .help("Speak progress now (⇧⌘P)").accessibilityLabel("Speak progress now").padding(.trailing, 8)
            Button { store.soundsMuted.toggle() } label: {
                Label(store.soundsMuted ? "Sounds off" : "Sounds on", systemImage: store.soundsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: fs(11), weight: .medium))
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6).background(ink.opacity(0.06), in: Capsule())
            .help(store.soundsMuted ? "Turn sounds and spoken progress on (⇧⌘M)" : "Mute sounds and spoken progress (⇧⌘M)")
            .accessibilityLabel(store.soundsMuted ? "Sounds are off. Turn on" : "Sounds are on. Mute").padding(.trailing, 10)
            turboButton.padding(.trailing, 10)
            Label(store.demo ? "Demo workspace" : "Live workspace", systemImage: store.demo ? "sparkles" : "arrow.left.arrow.right").font(.system(size: fs(11), weight: .medium)).foregroundStyle(store.demo ? accent : Color(red: 0.62, green: 0.32, blue: 0.0)).padding(.horizontal, 12).padding(.vertical, 7).background((store.demo ? accent : .orange).opacity(0.1), in: Capsule())
            if store.running {
                Button(store.pauseRequested ? "Pausing…" : "Pause after file", action: store.pauseAfterFile).disabled(store.pauseRequested)
                Button("Stop now", action: store.stopNow).tint(.red)
            }
            Button { store.exportReport() } label: { Label("Export report", systemImage: "square.and.arrow.up").font(.system(size: fs(12), weight: .medium)) }.buttonStyle(.plain).padding(.leading, 18)
        }.font(.system(size: fs(12))).padding(.horizontal, 30).frame(minHeight: 68).background(.white).overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.07)).frame(height: 1) }
    }

    /// 0.9.1: one-click Turbo for when you step away. Orange and filled while on, so it's obvious from across the room.
    var turboButton: some View {
        let turboTint = Color(red: 0.85, green: 0.4, blue: 0.0)
        return Button { store.turbo.toggle() } label: {
            Label(store.turbo ? "Turbo on" : "Turbo", systemImage: store.turbo ? "bolt.fill" : "bolt")
                .font(.system(size: fs(11), weight: store.turbo ? .bold : .medium))
                .foregroundStyle(store.turbo ? .white : ink)
        }
        .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
        .background(store.turbo ? turboTint : ink.opacity(0.06), in: Capsule())
        .disabled(store.demo)
        .help(store.turbo ? "Turbo is on: \(TransferStore.turboWorkers) files at a time even while you use the Mac. Click to go back to normal (⇧⌘T)" : "Turbo: copy \(TransferStore.turboWorkers) files at a time and retry faster — for when you step away (⇧⌘T)")
        .accessibilityLabel("Turbo")
        .accessibilityValue(store.turbo ? "on" : "off")
        .accessibilityHint("Copies more files at once and retries faster. Best when you're away from the Mac.")
        .accessibilityAddTraits(.isToggle)
    }

    var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) { Text(store.tab == "Transfers" ? "Your transfer library" : "A clear view of every file.").font(.system(size: fs(28), weight: .bold)); Text("MEGA → iCloud Drive · Your Mac is the bridge.").font(.system(size: fs(13))).foregroundStyle(muted) }
                Spacer()
                if store.demo { Button("Set up transfers", action: { store.openWorkspace(); store.tab = "Connections" }).buttonStyle(PrimaryStyle()) }
                else if store.running {
                    HStack(spacing: 10) {
                        Button(store.pauseRequested ? "Pausing…" : "Pause after file", action: store.pauseAfterFile).disabled(store.pauseRequested).buttonStyle(PrimaryStyle())
                        Button("Stop now", action: store.stopNow).buttonStyle(PrimaryStyle(tint: Color(red: 0.7, green: 0.2, blue: 0.15)))
                    }
                }
                else if store.queuedCount == 0 && !store.transfers.isEmpty { Text("No files queued").font(.system(size: fs(12))).foregroundStyle(muted) }
                else {
                    VStack(alignment: .trailing, spacing: 8) {
                        // 0.6: Start is never a silent no-op. When setup is incomplete it is grey and pressing it explains what is missing.
                        let ready = store.startRequirements.isEmpty
                        Button(store.pauseRequested ? "Resume transfers" : "Start transfers") {
                            if ready { store.startTransfers() }
                            else { store.error = "Start can't begin yet:\n\n• " + store.startRequirements.joined(separator: "\n• ") + "\n\nUse the checklist on this page; each item has its own button." }
                        }.buttonStyle(PrimaryStyle(dimmed: !ready))
                        .accessibilityHint(ready ? "Starts copying one file at a time." : "Setup is not finished. Pressing explains what is missing.")
                        if !ready { Text("Finish the checklist below").font(.system(size: fs(11), weight: .medium)).foregroundStyle(Color(red: 0.62, green: 0.32, blue: 0.0)) }
                    }
                }
            }
            if !store.demo {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.controlStatus).font(.system(size: fs(13), weight: .semibold))
                    if !store.transfers.isEmpty {
                        Text(store.soundsMuted ? "Sounds are off." : "While copying, a quiet tick plays every few seconds. Progress and time left are spoken at every 10%, and when transfers start, pause, stop or finish.").font(.system(size: fs(11))).foregroundStyle(muted)
                    }
                    if !store.running && (store.queuedCount > 0 || store.transfers.isEmpty) { setupChecklist }
                    Text("Pause finishes the current file. Stop cancels this app's download and keeps partial files for review. Apple may continue uploading existing iCloud copies.").font(.system(size: fs(11))).foregroundStyle(muted)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
            }
            if !store.demo && !store.transfers.isEmpty { progressCard }
            banner
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: store.textScale > 1.5 ? 2 : 4), spacing: 16) {
                metric("TRANSFER SIZE", bytes(store.totalBytes), "\(store.transfers.count) files in this run", "square.stack.3d.up", accent)
                metric("UPLOAD REPORTED", bytes(store.uploadedBytes), "\(store.completed) files · Apple status", "checkmark.icloud", Color(red: 0.05, green: 0.5, blue: 0.35))
                metric("MAC SPACE AVAILABLE", store.freeSpaceKnown ? bytes(store.freeBytes) : "Unavailable", store.waitingForSpace ? "Waiting for space · 50 GB reserve" : "Live reading · 50 GB reserve", "internaldrive", Color(red: 0.2, green: 0.42, blue: 0.72))
                metric("NEEDS REVIEW", "\(store.reviewCount)", "Rechecked automatically", "exclamationmark.shield", Color(red: 0.66, green: 0.36, blue: 0.05))
            }
            if !store.demo { releaseCard }
            routeCard
            if store.textScale > 1.5 { VStack(alignment: .leading, spacing: 18) { library; inspector } }
            else { HStack(alignment: .top, spacing: 18) { library.frame(maxWidth: .infinity); inspector.frame(width: 260 * min(uiScale, 1.5)) } }
        }
    }

    /// Every Start requirement with its own fix, on the same page as Start.
    var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.startRequirements.isEmpty ? "All set — press Start transfers" : "Before you start").font(.system(size: fs(12), weight: .bold)).padding(.top, 4)
            checkRow(store.binaryFolder != nil, store.binaryFolder != nil ? "MEGA app connected" : "Connect the MEGA app (MEGAcmd)") { Button("Locate MEGA app…", action: store.chooseBinaries) }
            checkRow(!store.transfers.isEmpty, store.transfers.isEmpty ? "Choose the MEGA folder to copy" : "MEGA folder: \(store.selectedSourcePath ?? "chosen") · \(store.transfers.count) files") {
                Button("Choose MEGA folder…") { store.showingSourcePicker = true }.disabled(store.binaryFolder == nil)
            }
            checkRow(store.destination != nil, store.destination.map { _ in "iCloud folder: \(store.destinationDisplay)" } ?? "Choose the iCloud Drive folder to copy into") { Button("Choose iCloud folder…", action: store.chooseDestination) }
            capacityButton
            ForEach(store.startRequirements.filter { r in !["MEGAcmd", "iCloud destination", "MEGA folder", "iCloud storage"].contains(where: { r.contains($0) }) }, id: \.self) { r in
                HStack(spacing: 10) { statusIcon(false); Text(r).font(.system(size: fs(12), weight: .medium)) }
            }
        }.padding(14).background((store.startRequirements.isEmpty ? Color.green : Color.orange).opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 0.6.2: the storage confirmation is one large button; any click on it (or Space) ticks or unticks it.
    var capacityButton: some View {
        Button { store.capacityConfirmed.toggle() } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: store.capacityConfirmed ? "checkmark.square.fill" : "square").font(.system(size: fs(24)))
                    .foregroundStyle(store.capacityConfirmed ? Color(red: 0.08, green: 0.56, blue: 0.4) : ink)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.capacityConfirmed ? "Confirmed: iCloud has room for \(bytes(store.totalBytes))" : "Click to confirm iCloud has room for \(bytes(store.totalBytes))").font(.system(size: fs(13), weight: .semibold))
                    Text(store.capacityConfirmed ? "Click again to untick." : "Check System Settings › Apple Account › iCloud first. The app can't read your iCloud quota.").font(.system(size: fs(11))).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(store.capacityConfirmed ? Color(red: 0.08, green: 0.56, blue: 0.4) : accent, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.running || store.busy)
        .accessibilityLabel("iCloud has room for \(bytes(store.totalBytes))")
        .accessibilityValue(store.capacityConfirmed ? "confirmed" : "not confirmed")
        .accessibilityAddTraits(.isToggle)
    }

    func statusIcon(_ done: Bool) -> some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: fs(15))).foregroundStyle(done ? Color(red: 0.08, green: 0.56, blue: 0.4) : Color(red: 0.62, green: 0.32, blue: 0.0)).accessibilityHidden(true)
    }

    func checkRow<B: View>(_ done: Bool, _ title: String, @ViewBuilder action: () -> B) -> some View {
        HStack(spacing: 10) {
            statusIcon(done)
            Text(title).font(.system(size: fs(12), weight: .medium)).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel((done ? "Done: " : "Needed: ") + title)
            Spacer()
            if !done { action().font(.system(size: fs(11), weight: .semibold)).disabled(store.running || store.busy) }
        }
    }

    // MARK: 0.8 progress: overall, numbered batch, iCloud upload and each file in progress
    var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Progress").font(.system(size: fs(16), weight: .bold))
                Spacer()
                Text(store.progressSummary).font(.system(size: fs(13), weight: .semibold)).monospacedDigit()
            }
            progressBar("All files", value: fraction(store.copiedBytes, store.totalBytes),
                        detail: "\(store.copiedFiles.formatted()) of \(store.includedCount.formatted()) files\(store.excludedCount > 0 ? " (\(store.excludedCount) excluded)" : "") · \(bytes(store.copiedBytes)) of \(bytes(store.totalBytes)) copied to iCloud · \(store.percentText)",
                        tint: accent, height: 14)
            if let b = store.currentBatch {
                let eta = store.estimatedSeconds(files: b.remainingFiles, bytes: b.remainingBytes).map { "about \(ProgressTiming.format(seconds: $0, spoken: false)) left in this batch" } ?? (store.running ? "estimating batch time…" : "batch time is measured once transfers run")
                progressBar("Batch \(b.number) of \(b.count)  ·  files \(b.firstFile.formatted())–\(b.lastFile.formatted())", value: fraction(b.settledBytes, b.bytes),
                            detail: "\(b.settledFiles) of \(b.files) files copied · \(bytes(b.settledBytes)) of \(bytes(b.bytes))\(b.reviewFiles > 0 ? " · \(b.reviewFiles) need review" : "") · \(eta)", tint: Color(red: 0.35, green: 0.3, blue: 0.85), height: 10)
            }
            if !store.reviewItems.isEmpty { reviewPanel }
            // 0.8.4: download and upload shown side by side, both always visible.
            if store.textScale > 1.5 { VStack(alignment: .leading, spacing: 18) { downloadColumn; uploadColumn } }
            else { HStack(alignment: .top, spacing: 18) { downloadColumn.frame(maxWidth: .infinity, alignment: .topLeading); uploadColumn.frame(maxWidth: .infinity, alignment: .topLeading) } }
            HStack(spacing: 6) {
                Image(systemName: store.turbo ? "bolt.fill" : store.macIdle ? "moon.zzz.fill" : "speedometer").accessibilityHidden(true)
                Text(workerText).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: fs(11), weight: .medium)).foregroundStyle(muted)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    /// 0.8.5: what needs review, why, and one button to retry them all. The rest of the queue keeps going.
    var reviewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(store.reviewItems.count) file\(store.reviewItems.count == 1 ? "" : "s") need\(store.reviewItems.count == 1 ? "s" : "") a look", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: fs(14), weight: .bold)).foregroundStyle(Color(red: 0.62, green: 0.32, blue: 0.0))
                Spacer()
                Button("Show all") { store.filter = "Needs review"; store.tab = "Transfers" }.font(.system(size: fs(12), weight: .medium))
            }
            Text("The app rechecks these on its own every couple of minutes. A file already in the iCloud folder that differs from MEGA is never overwritten.").font(.system(size: fs(11))).foregroundStyle(muted)
            ForEach(store.reviewItems.prefix(5)) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text((t.entry.relativePath as NSString).lastPathComponent).font(.system(size: fs(12), weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(t.note).font(.system(size: fs(11))).foregroundStyle(muted).lineLimit(2)
                }.accessibilityElement(children: .combine)
            }
            if store.reviewItems.count > 5 { Text("and \(store.reviewItems.count - 5) more").font(.system(size: fs(11))).foregroundStyle(muted) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }

    func columnBox<C: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: fs(14), weight: .bold))
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(canvas, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
    }

    var downloadColumn: some View {
        columnBox("Downloading from MEGA", "arrow.down.circle.fill") {
            progressBar("Copied to this Mac and iCloud folder", value: fraction(store.copiedBytes, store.totalBytes), detail: downloadDetail, tint: accent, height: 12)
            Text("Working on now").font(.system(size: fs(12), weight: .bold))
            if store.activeFiles.isEmpty {
                Text(store.running ? (store.retryingLaterCount > 0 && store.queuedCount == store.retryingLaterCount ? "Starting the next file…" : "Starting the next file…") : store.pauseRequested ? "Paused — no downloads running." : "Not running — press Start transfers.").font(.system(size: fs(11))).foregroundStyle(muted)
            } else {
                ForEach(store.activeFiles.values.sorted { $0.started < $1.started }) { f in
                    progressBar(f.name, value: fraction(f.done, f.bytes), detail: "\(f.phase) · \(bytes(f.done)) of \(bytes(f.bytes))", tint: accent.opacity(0.8), height: 8)
                }
            }
        }
    }

    var uploadColumn: some View {
        columnBox("Uploading to iCloud", "arrow.up.circle.fill") {
            progressBar("Confirmed uploaded by Apple", value: fraction(store.uploadedBytes, max(store.copiedBytes, 1)), detail: uploadDetail, tint: Color(red: 0.05, green: 0.5, blue: 0.35), height: 12)
            Text("Uploading now").font(.system(size: fs(12), weight: .bold))
            if store.uploadingNow.isEmpty {
                Text(store.awaitingUploadFiles > 0 ? "\(store.awaitingUploadFiles.formatted()) files waiting for iCloud to pick them up." : "Nothing waiting to upload.").font(.system(size: fs(11))).foregroundStyle(muted)
            } else {
                ForEach(uploadingRows, id: \.id) { t in
                    let since = store.uploadingNow[t.id] ?? Date()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text((t.entry.relativePath as NSString).lastPathComponent).font(.system(size: fs(12), weight: .semibold)).lineLimit(1).truncationMode(.middle); Spacer(); Text(bytes(t.entry.expectedBytes)).font(.system(size: fs(12))).foregroundStyle(muted) }
                        ProgressView().progressViewStyle(.linear).tint(Color(red: 0.05, green: 0.5, blue: 0.35))
                        Text("Uploading for \(ProgressTiming.format(seconds: Date().timeIntervalSince(since), spoken: false))").font(.system(size: fs(11))).foregroundStyle(muted)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Uploading \((t.entry.relativePath as NSString).lastPathComponent), \(bytes(t.entry.expectedBytes))")
                }
                if store.uploadingNow.count > uploadingRows.count { Text("and \(store.uploadingNow.count - uploadingRows.count) more uploading").font(.system(size: fs(11))).foregroundStyle(muted) }
                Text("Apple reports each file as uploading or done, not a percentage.").font(.system(size: fs(10))).foregroundStyle(muted)
            }
        }
    }

    var downloadDetail: String {
        var text = "\(store.copiedFiles.formatted()) of \(store.includedCount.formatted()) files · \(bytes(store.copiedBytes)) of \(bytes(store.totalBytes))"
        if let speed = store.averageSpeed { text += " · \(bytes(Int64(speed)))/s" }
        if let s = store.estimatedSeconds(files: store.remainingFiles, bytes: store.remainingBytes) { text += " · about \(ProgressTiming.format(seconds: s, spoken: false)) left" }
        else if store.remainingFiles > 0 { text += store.running ? " · measuring speed…" : " · time is measured once transfers run" }
        return text
    }

    var uploadingRows: [Transfer] {
        let ids = store.uploadingNow.sorted { $0.value < $1.value }.prefix(6).map(\.key)
        return ids.compactMap { id in store.transfers.first { $0.id == id } }
    }

    var uploadDetail: String {
        var text = "\(store.completed.formatted()) of \(store.copiedFiles.formatted()) copied files uploaded · \(bytes(store.uploadedBytes)) of \(bytes(store.copiedBytes))"
        if store.awaitingUploadFiles > 0 { text += " · \(store.awaitingUploadFiles.formatted()) waiting" }
        if let r = store.uploadRate { text += " · \(bytes(Int64(r)))/s" }
        if let s = store.uploadSecondsLeft { text += " · about \(ProgressTiming.format(seconds: s, spoken: false)) to upload what's copied" }
        else if store.pendingUploadBytes > 0 { text += " · upload time is measured after a minute of uploads" }
        return text
    }

    var workerText: String {
        let release = store.autoRelease ? "Local copies are freed automatically after Apple reports each upload." : "Automatic release is off: copies stay on this Mac until released, which can slow Turbo once the disk fills."
        guard store.running else {
            if store.turbo { return "Turbo is on: copies \(TransferStore.turboWorkers) files at a time and retries faster, whether or not you're using the Mac. The Mac is kept awake while copying. " + release }
            return "Copies 3 files at a time while you use the Mac and 6 when it has been idle for 2 minutes. Press Turbo (⇧⌘T) before you step away for \(TransferStore.turboWorkers) at a time. The Mac is kept awake while copying. " + release
        }
        var text = store.turbo ? "Turbo: running up to \(store.workerLimit) files at a time with faster retries." : store.macIdle ? "Mac idle: running up to \(store.workerLimit) files at a time." : "Mac in use: running up to \(store.workerLimit) files at a time (6 when idle, \(TransferStore.turboWorkers) with Turbo)."
        if let speed = store.averageSpeed { text += " Download speed \(bytes(Int64(speed)))/s." }
        return text + " Kept awake while copying."
    }

    func fraction(_ part: Int64, _ whole: Int64) -> Double { whole > 0 ? min(1, max(0, Double(part) / Double(whole))) : 0 }

    func progressBar(_ title: String, value: Double, detail: String, tint: Color, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.system(size: fs(12), weight: .semibold)).lineLimit(1).truncationMode(.middle); Spacer(); Text("\(value > 0 && value < 0.1 ? String(format: "%.1f", value * 100) : String(Int(value * 100)))%").font(.system(size: fs(12), weight: .semibold)).monospacedDigit() }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.09))
                    // A visible sliver from the first byte, so early progress never looks like zero.
                    Capsule().fill(tint).frame(width: value > 0 ? max(height, geo.size.width * value) : 0)
                }
            }.frame(height: height)
            Text(detail).font(.system(size: fs(11))).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((value * 100).rounded())) percent. \(detail)")
    }

    var releaseCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Free up Mac space").font(.system(size: fs(14), weight: .semibold))
                Text("\(store.releasable.count) uploaded files (\(bytes(store.releasable.reduce(0) { $0 + $1.entry.expectedBytes }))) can have their local copies removed. They stay in iCloud and in MEGA.").font(.system(size: fs(11))).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                Toggle("Release automatically after Apple reports each upload (recommended, on by default)", isOn: Binding(get: { store.autoRelease }, set: { store.setAutoRelease($0) })).toggleStyle(.checkbox).font(.system(size: fs(11))).disabled(!store.transfersEnabled)
            }
            Spacer()
            Button("Release all uploaded…", action: store.releaseAll).disabled(!store.transfersEnabled || store.busy || store.releasable.isEmpty).font(.system(size: fs(12)))
        }.padding(20).card()
    }

    var banner: some View {
        HStack(spacing: 12) {
            Image(systemName: store.demo ? "info.circle.fill" : "shield.lefthalf.filled").foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.demo ? "Preview mode — sample transfer data" : "Live transfers — MEGA originals stay untouched").font(.system(size: fs(12), weight: .semibold))
                Text(store.demo ? "No real transfers. Disk space is live; file names, sizes and states are illustrative." : "Files up to 25 GB. One at a time. Upload status is not a cloud checksum verification.").font(.system(size: fs(11))).foregroundStyle(muted)
            }; Spacer()
            Text(store.demo ? "DEMO" : "LIVE").font(.system(size: fs(9), weight: .bold)).tracking(1).foregroundStyle(accent)
        }.padding(15).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }

    func metric(_ title: String, _ value: String, _ detail: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.system(size: fs(9), weight: .bold)).tracking(0.7).foregroundStyle(muted); Spacer(); Image(systemName: symbol).font(.system(size: fs(15))).foregroundStyle(color).accessibilityHidden(true) }
            Text(value).font(.system(size: fs(27), weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            Text(detail).font(.system(size: fs(10))).foregroundStyle(muted).lineLimit(store.textScale > 1.5 ? nil : 2)
        }.padding(19).frame(maxWidth: .infinity, alignment: .leading).card()
        .accessibilityElement(children: .combine)
    }

    var routeCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Transfer pipeline").font(.system(size: fs(14), weight: .semibold)); Spacer()
                Circle().fill(store.running ? Color.green : muted.opacity(0.5)).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(store.demo ? "Illustrative" : store.controlStatus).font(.system(size: fs(11))).foregroundStyle(muted)
            }
            if store.textScale > 1.5 {
                VStack(spacing: 16) {
                    cloudBadge("MEGA", subtitle: "Source · read only", letter: "M", color: Color(red: 0.8, green: 0.18, blue: 0.26))
                    Image(systemName: "arrow.down").foregroundStyle(muted).accessibilityHidden(true)
                    Label("This Mac · space-aware staging", systemImage: "laptopcomputer").font(.system(size: fs(12), weight: .medium))
                    Image(systemName: "arrow.down").foregroundStyle(muted).accessibilityHidden(true)
                    cloudBadge("iCloud Drive", subtitle: "Destination · Apple sync", letter: "icloud.fill", color: Color(red: 0.1, green: 0.46, blue: 0.85))
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 22) {
                    cloudBadge("MEGA", subtitle: "Source · read only", letter: "M", color: Color(red: 0.8, green: 0.18, blue: 0.26))
                    routeLine
                    VStack(spacing: 7) { Image(systemName: "laptopcomputer").font(.system(size: fs(26))).foregroundStyle(accent).accessibilityHidden(true); Text("This Mac").font(.system(size: fs(12), weight: .semibold)); Text("Space-aware staging").font(.system(size: fs(10))).foregroundStyle(muted) }.frame(width: 150)
                    routeLine
                    cloudBadge("iCloud Drive", subtitle: "Destination · Apple sync", letter: "icloud.fill", color: Color(red: 0.1, green: 0.46, blue: 0.85))
                }.frame(maxWidth: .infinity)
            }
            VStack(spacing: 8) {
                GeometryReader { geo in ZStack(alignment: .leading) { Capsule().fill(ink.opacity(0.08)); Capsule().fill(LinearGradient(colors: [accent, Color(red: 0.3, green: 0.6, blue: 0.95)], startPoint: .leading, endPoint: .trailing)).frame(width: geo.size.width * (store.totalBytes > 0 ? Double(store.uploadedBytes) / Double(store.totalBytes) : 0)) } }.frame(height: 6).accessibilityHidden(true)
                HStack { Text("\(store.completed) of \(store.transfers.count) files with upload reported"); Spacer(); Text("Cloud read-back: not performed") }.font(.system(size: fs(10))).foregroundStyle(muted)
            }
        }.padding(22).card()
    }

    var routeLine: some View { HStack(spacing: 6) { Rectangle().fill(ink.opacity(0.12)).frame(height: 1); Image(systemName: "chevron.right").font(.system(size: fs(10))).foregroundStyle(muted) }.frame(maxWidth: .infinity).accessibilityHidden(true) }

    func cloudBadge(_ title: String, subtitle: String, letter: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack { RoundedRectangle(cornerRadius: 13).fill(color.opacity(0.08)).frame(width: 48, height: 48); if letter == "M" { Text("M").font(.system(size: fs(25), weight: .bold)).foregroundStyle(color) } else { Image(systemName: letter).font(.system(size: fs(24))).foregroundStyle(color) } }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: fs(13), weight: .semibold)); Text(subtitle).font(.system(size: fs(10))).foregroundStyle(muted) }
        }.frame(minWidth: 210, maxWidth: store.textScale > 1.5 ? .infinity : 210, alignment: .leading)
    }

    var library: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("File activity").font(.system(size: fs(14), weight: .semibold))
                Text("\(store.transfers.count)").font(.system(size: fs(10), weight: .medium)).foregroundStyle(muted).padding(.horizontal, 7).padding(.vertical, 3).background(canvas, in: Capsule())
                Spacer(); Image(systemName: "magnifyingglass").foregroundStyle(muted).accessibilityHidden(true)
                TextField("Find a file", text: $store.search).textFieldStyle(.plain).font(.system(size: fs(11))).frame(width: 105 * uiScale)
            }.padding(18)
            HStack(spacing: 5) {
                ForEach(["All files", "Uploaded", "Queued", "Needs review", "Deferred"], id: \.self) { f in
                    Button { store.filter = f } label: { Text(f).font(.system(size: fs(10), weight: .medium)).padding(.horizontal, 11).padding(.vertical, 7).background(store.filter == f ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(store.filter == f ? accent : muted) }.buttonStyle(.plain)
                    .accessibilityAddTraits(store.filter == f ? .isSelected : [])
                }; Spacer()
            }.padding(.horizontal, 15).padding(.bottom, 12)
            HStack { Text("NAME"); Spacer(); Text("SIZE").frame(width: 60 * uiScale, alignment: .trailing); Text("STATUS").frame(width: 126 * uiScale, alignment: .leading) }.font(.system(size: fs(9), weight: .semibold)).tracking(0.8).foregroundStyle(muted).padding(.horizontal, 18).padding(.vertical, 10).background(canvas.opacity(0.8)).accessibilityHidden(true)
            if store.visible.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: fs(28))).foregroundStyle(muted).accessibilityHidden(true)
                    Text("No files to display").font(.system(size: fs(13), weight: .medium))
                    Text(store.transfers.isEmpty ? "Choose your MEGA source and iCloud destination to prepare a transfer." : "Try another filter or search.").font(.system(size: fs(11))).foregroundStyle(muted)
                }.frame(maxWidth: .infinity).padding(45)
            }
            ForEach(store.visible) { t in
                Button { store.selected = t.id } label: {
                    HStack(spacing: 11) {
                        Image(systemName: fileIcon(t.entry.relativePath)).font(.system(size: fs(17))).foregroundStyle(accent.opacity(0.8)).frame(width: 32, height: 36).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) { Text((t.entry.relativePath as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)).font(.system(size: fs(11), weight: .medium)).lineLimit(1); Text((t.entry.relativePath as NSString).deletingLastPathComponent).font(.system(size: fs(9))).foregroundStyle(muted).lineLimit(1).truncationMode(.middle) }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(bytes(t.entry.expectedBytes)).font(.system(size: fs(10))).foregroundStyle(muted).frame(width: 60 * uiScale, alignment: .trailing)
                        StatusBadge(stage: t.stage).frame(width: 126 * uiScale, alignment: .leading)
                    }.padding(.horizontal, 18).padding(.vertical, 11).background(store.selected == t.id ? accent.opacity(0.06) : .clear).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(store.selected == t.id ? .isSelected : [])
                Rectangle().fill(ink.opacity(0.06)).frame(height: 1).padding(.leading, 18).accessibilityHidden(true)
            }
            HStack { Image(systemName: "lock.shield").accessibilityHidden(true); Text("MEGA originals are never removed."); Spacer() }.font(.system(size: fs(10))).foregroundStyle(muted).padding(16)
        }.card()
    }

    var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("FILE DETAILS").font(.system(size: fs(9), weight: .bold)).tracking(1).foregroundStyle(muted)
            if let t = store.transfers.first(where: { $0.id == store.selected }) {
                Image(systemName: fileIcon(t.entry.relativePath)).font(.system(size: fs(30))).foregroundStyle(accent).padding(15).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
                Text((t.entry.relativePath as NSString).lastPathComponent).font(.system(size: fs(14), weight: .semibold)).lineLimit(3)
                StatusBadge(stage: t.stage)
                Divider()
                detail("File size", bytes(t.entry.expectedBytes))
                detail("Source", "MEGA · preserved")
                detail("Cloud verification", "Not performed")
                VStack(alignment: .leading, spacing: 6) { Text("LOCAL SHA-256").font(.system(size: fs(9), weight: .bold)).foregroundStyle(muted); Text(t.sha256 ?? "Not recorded yet").font(.system(size: fs(10), design: .monospaced)).foregroundStyle(muted).textSelection(.enabled) }
                Text(t.note).font(.system(size: fs(11))).foregroundStyle(muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if !store.demo {
                    if [.queued, .awaitingUpload, .needsReview].contains(t.stage) { Button("Defer this file") { store.skip(t) }.font(.system(size: fs(11), weight: .medium)).disabled(store.busy) }
                    if t.stage == .uploaded { Button("Release local copy…") { store.release(t) }.font(.system(size: fs(11), weight: .medium)).disabled(!store.transfersEnabled || store.busy) }
                    if t.stage == .excluded { Button("Include again") { store.includeAgain(t) }.font(.system(size: fs(11), weight: .medium)).disabled(store.busy) }
                    if t.stage == .skipped { Button("Include again") { store.retry(t) }.font(.system(size: fs(11), weight: .medium)).disabled(!store.transfersEnabled || store.running || store.busy) }
                }
            } else { Text("Select a file to inspect its transfer history and verification status.").font(.system(size: fs(12))).foregroundStyle(muted).lineSpacing(5) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    func detail(_ label: String, _ value: String) -> some View { HStack { Text(label).foregroundStyle(muted); Spacer(); Text(value).fontWeight(.medium) }.font(.system(size: fs(10))).accessibilityElement(children: .combine) }

    var connections: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Choose what to transfer.").font(.system(size: fs(28), weight: .bold))
            Text("No intermediary server. MEGA handles downloads; macOS handles iCloud uploads.").font(.system(size: fs(13))).foregroundStyle(muted)
            banner
            if !store.transfersEnabled { Label("Real transfers are locked in this review build. See the review guide before enabling transfers.", systemImage: "lock.fill").font(.system(size: fs(12), weight: .medium)).foregroundStyle(accent).padding(18).card() }
            if store.demo { Button("Open transfers", action: store.openWorkspace).buttonStyle(PrimaryStyle()) }
            else {
                // 0.6.1: each step shows a plain-language state, a green tick when done, and confirms every choice.
                setupCard("01", "MEGA source folder", "The MEGA folder to copy. Nothing is downloaded until you press Start.",
                          done: !store.transfers.isEmpty,
                          state: store.transfers.isEmpty ? "Not chosen yet" : "MEGA › \((store.selectedSourcePath ?? "/").split(separator: "/").joined(separator: " › "))  ·  \(store.transfers.count.formatted()) files  ·  \(bytes(store.totalBytes))",
                          confirmation: store.sourceConfirmation) {
                    Button(store.transfers.isEmpty ? "Choose MEGA folder…" : "Change MEGA folder…") { store.showingSourcePicker = true }
                        .buttonStyle(PrimaryStyle(dimmed: !store.transfers.isEmpty)).disabled(store.binaryFolder == nil)
                }
                setupCard("02", "iCloud destination", "The iCloud Drive folder to copy into. Existing files are never overwritten.",
                          done: store.destination != nil,
                          state: store.destination.map { _ in store.destinationDisplay } ?? "Not chosen yet",
                          confirmation: store.destinationConfirmation) {
                    Button(store.destination == nil ? "Choose iCloud folder…" : "Change iCloud folder…", action: store.chooseDestination)
                        .buttonStyle(PrimaryStyle(dimmed: store.destination != nil))
                }
                if store.destination != nil, !store.transfers.isEmpty {
                    Label("Files will be copied into: \(store.runFolderDisplay)", systemImage: "arrow.down.doc").font(.system(size: fs(12), weight: .medium)).foregroundStyle(muted)
                }
                HStack {
                    Label(store.binaryFolder == nil ? "MEGA connection required" : "MEGA connected", systemImage: store.binaryFolder == nil ? "exclamationmark.icloud" : "checkmark.circle.fill")
                        .font(.system(size: fs(12), weight: .medium)).foregroundStyle(store.binaryFolder == nil ? .orange : Color(red: 0.08, green: 0.56, blue: 0.4))
                    Spacer()
                }
                DisclosureGroup("Connection settings") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Use the official MEGAcmd installation and sign in through MEGA’s own interface.").font(.system(size: fs(11))).foregroundStyle(muted)
                        Button("Locate official MEGA app…", action: store.chooseBinaries)
                    }.padding(.vertical, 10)
                }.font(.system(size: fs(11))).foregroundStyle(muted)
                DisclosureGroup("Advanced: import an existing file list") {
                    Button("Import file list…", action: store.importManifest).disabled(!store.transfers.isEmpty || store.running || store.busy)
                        .padding(.vertical, 10)
                }.font(.system(size: fs(11))).foregroundStyle(muted)
                HStack(alignment: .top, spacing: 18) {
                    Text("03").font(.system(size: fs(13), weight: .semibold, design: .monospaced)).foregroundStyle(accent).padding(12).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                    capacityButton
                }.padding(23).card()
                // Start is available right here, so setup and starting happen on one page.
                HStack(spacing: 14) {
                    if store.running {
                        Button(store.pauseRequested ? "Pausing…" : "Pause after file", action: store.pauseAfterFile).buttonStyle(PrimaryStyle()).disabled(store.pauseRequested)
                        Button("Stop now", action: store.stopNow).buttonStyle(PrimaryStyle(tint: Color(red: 0.7, green: 0.2, blue: 0.15)))
                        Text(store.controlStatus).font(.system(size: fs(12), weight: .medium))
                    } else {
                        let ready = store.startRequirements.isEmpty
                        Button(store.pauseRequested ? "Resume transfers" : "Start transfers") {
                            if ready { store.startTransfers(); store.tab = "Overview" }
                            else { store.error = "Start can't begin yet:\n\n• " + store.startRequirements.joined(separator: "\n• ") }
                        }.buttonStyle(PrimaryStyle(dimmed: !ready))
                        Text(ready ? "Everything is set. Start copies one file at a time; MEGA originals are never touched." : "Still needed: " + store.startRequirements.joined(separator: " "))
                            .font(.system(size: fs(12), weight: .medium)).foregroundStyle(ready ? Color(red: 0.08, green: 0.56, blue: 0.4) : Color(red: 0.62, green: 0.32, blue: 0.0)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("MEGA originals are never modified or deleted. Apple-reported uploads and checksum verification are shown separately; uncertain files stay available for review.").font(.system(size: fs(11))).foregroundStyle(muted).lineSpacing(5)
        }
    }

    func setupCard<B: View>(_ number: String, _ title: String, _ description: String, done: Bool, state: String, confirmation: String?, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(number).font(.system(size: fs(13), weight: .semibold, design: .monospaced)).foregroundStyle(accent).padding(12).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: fs(15), weight: .semibold))
                Text(description).font(.system(size: fs(12))).foregroundStyle(muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    statusIcon(done)
                    Text(state).font(.system(size: fs(13), weight: .semibold)).foregroundStyle(done ? ink : Color(red: 0.62, green: 0.32, blue: 0.0)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                if let confirmation { Text(confirmation).font(.system(size: fs(11), weight: .medium)).foregroundStyle(Color(red: 0.08, green: 0.56, blue: 0.4)).accessibilityAddTraits(.updatesFrequently) }
            }
            Spacer(); button().font(.system(size: fs(11))).disabled(store.running || store.busy)
        }.padding(23).card()
    }

    var activity: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 7) { Text("An accountable transfer.").font(.system(size: fs(28), weight: .bold)); Text("A local record of progress, pauses and decisions.").font(.system(size: fs(13))).foregroundStyle(muted) }
                Spacer(); Button("Export report…", action: store.exportReport)
            }
            banner
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.events.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 14) { Circle().fill(accent.opacity(0.6)).frame(width: 6, height: 6).padding(.top, 5).accessibilityHidden(true); Text(event).font(.system(size: fs(12))).textSelection(.enabled); Spacer() }.padding(19)
                    Divider().opacity(0.4)
                }
            }.card()
        }
    }

    var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(store.demo ? accent : store.running ? .green : muted).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(store.demo ? "Demo · no real file activity" : store.controlStatus)
            Spacer(); Text("Cloud Transfer+ / Version 0.9.0"); Text("•").padding(.horizontal, 5).accessibilityHidden(true); Text("Local-first")
        }.font(.system(size: fs(10))).foregroundStyle(muted).padding(.horizontal, 30).frame(minHeight: 36).background(.white)
    }

    func fileIcon(_ path: String) -> String { let ext = (path as NSString).pathExtension.lowercased(); if ["jpg", "png", "dng", "jpeg", "heic"].contains(ext) { return "photo" }; if ["mov", "mp4", "m4v"].contains(ext) { return "film" }; if ext == "zip" { return "doc.zipper" }; return "doc.text" }
}

struct StatusBadge: View {
    let stage: TransferStage
    var color: Color {
        switch stage {
        case .released, .uploaded: Color(red: 0.05, green: 0.46, blue: 0.32)
        case .needsReview: Color(red: 0.62, green: 0.32, blue: 0.02)
        case .queued, .skipped, .excluded: muted
        default: accent
        }
    }
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 4, height: 4).accessibilityHidden(true); Text(stage.label).font(.system(size: fs(9), weight: .medium)).lineLimit(1) }
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5).background(color.opacity(0.08), in: Capsule())
            .accessibilityLabel("Status: \(stage.label)")
    }
}

struct PrimaryStyle: ButtonStyle {
    var tint: Color = accent
    /// Grey but still pressable (used for Start when setup is incomplete, so pressing explains why).
    var dimmed = false
    func makeBody(configuration: Configuration) -> some View { PrimaryButtonBody(configuration: configuration, tint: tint, dimmed: dimmed) }
}

/// 0.6: the old style drew disabled buttons exactly like enabled ones, so a blocked Start looked live and did nothing.
private struct PrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let dimmed: Bool
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        let off = dimmed || !isEnabled
        configuration.label.font(.system(size: fs(12), weight: .semibold))
            .foregroundStyle(off ? Color(red: 0.25, green: 0.27, blue: 0.31) : .white)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background((off ? Color(red: 0.84, green: 0.85, blue: 0.87) : tint).opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension View { func card() -> some View { self.background(.white, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(ink.opacity(0.09), lineWidth: 1)).shadow(color: ink.opacity(0.025), radius: 8, x: 0, y: 3) } }

/// First launch: Cloud Transfer+ is a bridge that works alongside MEGA's own free helper app (MEGAcmd).
/// One plain yes/no question, then either "found it" or simple install steps.
struct WelcomeSheet: View {
    @EnvironmentObject var store: TransferStore
    var done: () -> Void
    @State private var answer: Bool? = nil
    @State private var found = false
    @State private var checked = false
    let megaPage = URL(string: "https://mega.io/cmd")!
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Cloud Transfer+").font(.system(size: fs(26), weight: .bold))
            Text("Cloud Transfer+ is a bridge between your MEGA account and iCloud Drive. It works together with MEGA's own free helper app, called MEGAcmd, which keeps your MEGA sign-in safe with MEGA. Your iCloud already works because you're signed in to this Mac.")
                .font(.system(size: fs(15))).fixedSize(horizontal: false, vertical: true)
            if answer == nil {
                Text("Do you already have MEGAcmd on this Mac?").font(.system(size: fs(18), weight: .semibold))
                HStack(spacing: 14) {
                    Button("Yes, I have it") { answer = true; check() }.buttonStyle(PrimaryStyle())
                    Button("No, not yet") { answer = false }.buttonStyle(PrimaryStyle(tint: Color(red: 0.25, green: 0.28, blue: 0.4)))
                }
            } else if found {
                Label("Found MEGAcmd and connected it.", systemImage: "checkmark.circle.fill").font(.system(size: fs(17), weight: .semibold)).foregroundStyle(Color(red: 0.08, green: 0.5, blue: 0.24))
                Text("If you haven't signed in to MEGA yet, open MEGAcmd from Applications once and sign in there. Then pick your MEGA folder and your iCloud folder, and press Start.").font(.system(size: fs(15))).fixedSize(horizontal: false, vertical: true)
                Button("Get started") { done() }.buttonStyle(PrimaryStyle())
            } else {
                if answer == true && checked { Text("MEGAcmd isn't in your Applications folder yet. These three steps fix that:").font(.system(size: fs(15), weight: .semibold)) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Download MEGAcmd for Mac from MEGA's website (free).")
                    Text("2. Open the download and drag MEGAcmd into Applications.")
                    Text("3. Open MEGAcmd once and sign in to your MEGA account there.")
                }.font(.system(size: fs(15))).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Open MEGA's download page") { NSWorkspace.shared.open(megaPage) }.buttonStyle(PrimaryStyle())
                    Button("I've installed it") { check() }.buttonStyle(PrimaryStyle(tint: Color(red: 0.25, green: 0.28, blue: 0.4)))
                }
                if checked && answer == false { Text("Still not found. Make sure MEGAcmd is in Applications, then press I've installed it again.").font(.system(size: fs(13))).foregroundStyle(Color(red: 0.62, green: 0.32, blue: 0.0)) }
                Button("Skip for now") { done() }.font(.system(size: fs(13)))
            }
        }.padding(32).frame(width: 640 * min(uiScale, 1.5), alignment: .leading)
    }
    private func check() { found = store.detectMEGAHelper(); checked = true }
}
