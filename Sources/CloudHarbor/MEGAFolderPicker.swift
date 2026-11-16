import SwiftUI
import HarborCore
import HarborEngine

struct MEGAFolderPicker: View {
    @EnvironmentObject var store: TransferStore
    @Environment(\.dismiss) private var dismiss
    @State private var current = "/"
    @State private var currentHandle: String?
    @State private var knownHandles: [String: String] = [:]
    @State private var folders: [RemoteFolder] = []
    @State private var selection: String?
    @State private var loading = false
    @State private var problem: String?
    @State private var requestID = UUID()
    private var chosen: RemoteFolder? { folders.first { $0.id == selection } }
    private var chosenPath: String { chosen?.path ?? current }
    private var crumbs: [(String, String)] {
        var path = ""
        return [("MEGA", "/")] + current.split(separator: "/").map { part in path += "/" + part; return (String(part), path) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "folder.badge.gearshape").font(.system(size: 30)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Choose a MEGA folder").font(.system(size: 23, weight: .bold))
                    Text("Browse your folders. Selecting a source does not start a download.").font(.system(size: 13)).foregroundStyle(muted)
                }
                Spacer()
            }
            HStack {
                Button { open(parent(current)) } label: { Label("Up", systemImage: "arrow.up") }.disabled(current == "/" || loading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { i, crumb in
                            if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(muted).accessibilityHidden(true) }
                            Button(crumb.0) { open(crumb.1) }.buttonStyle(.plain).foregroundStyle(accent).disabled(loading)
                        }
                    }.padding(.vertical, 7)
                }
                Button { open(current) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh folders").accessibilityLabel("Refresh MEGA folders").disabled(loading)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(canvas)
                if loading {
                    VStack(spacing: 12) { ProgressView(); Text("Reading your MEGA folders…").foregroundStyle(muted) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let problem {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.icloud").font(.system(size: 30)).foregroundStyle(.orange)
                        Text(problem).multilineTextAlignment(.center).foregroundStyle(muted).frame(maxWidth: 470)
                        Button("Try again") { open(current) }
                    }.padding(25)
                } else if folders.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder").font(.system(size: 32)).foregroundStyle(accent)
                        Text("No subfolders").font(.system(size: 16, weight: .semibold))
                        Text("You can choose this folder to include its files.").foregroundStyle(muted)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(folders) { folder in
                                HStack(spacing: 4) {
                                    Button { selection = folder.id } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "folder.fill").font(.system(size: 23)).foregroundStyle(accent).accessibilityHidden(true)
                                            Text(folder.name).font(.system(size: 15)).lineLimit(2)
                                            Spacer(minLength: 0)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 15).padding(.leading, 16).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("Select \(folder.name)")
                                        .accessibilityAddTraits(selection == folder.id ? .isSelected : [])
                                    Button { open(folder.path, handle: folder.id) } label: {
                                        Image(systemName: "chevron.right").foregroundStyle(muted).frame(width: 38, height: 48).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("Open \(folder.name)")
                                }.background(selection == folder.id ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { open(folder.path, handle: folder.id) })
                                Divider().padding(.leading, 50)
                            }
                        }.padding(8)
                    }

                }
            }.frame(minHeight: 300)
            VStack(alignment: .leading, spacing: 7) {
                Text("BACKUP SOURCE").font(.system(size: 10, weight: .bold)).foregroundStyle(muted).tracking(1)
                Text(chosenPath == "/" ? "All of MEGA" : chosenPath).font(.system(size: 13, weight: .medium)).textSelection(.enabled).lineLimit(3)
                if store.hasActiveFiles { Text("Finish or defer the current run before choosing a different source.").font(.system(size: 12)).foregroundStyle(.orange) }
                else if !store.transfers.isEmpty { Text("Using a new source will ask you to archive the completed run’s history. Existing files stay untouched.").font(.system(size: 12)).foregroundStyle(muted) }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open selected folder") { if let chosen { open(chosen.path, handle: chosen.id) } }.disabled(chosen == nil || loading || problem != nil)
                Button("Use this folder") { let root = chosenPath; let handle = chosen?.id ?? currentHandle; dismiss(); store.prepareSourceFolder(root, handle: handle) }
                    .buttonStyle(PrimaryStyle()).keyboardShortcut(.defaultAction)
                    .disabled(loading || problem != nil || store.hasActiveFiles)
            }
        }.padding(26).frame(minWidth: 700, idealWidth: 780, minHeight: 610).foregroundStyle(ink).background(.white)
            .task { open("/") }
            .onDisappear { requestID = UUID() }
    }
    private func parent(_ path: String) -> String { let value = (path as NSString).deletingLastPathComponent; return value.isEmpty ? "/" : value }
    private func open(_ path: String, handle: String? = nil) {
        guard let client = store.client else { problem = "Connect the official MEGA client first."; return }
        if let handle { knownHandles[path] = handle }
        currentHandle = handle ?? knownHandles[path]
        let pinnedHandle = currentHandle
        let id = UUID(); requestID = id; current = path; selection = nil; loading = true; problem = nil; folders = []
        Task {
            do { let result = try await client.folders(in: path, handle: pinnedHandle); guard requestID == id else { return }; folders = result }
            catch { guard requestID == id else { return }; problem = error.localizedDescription }
            if requestID == id { loading = false }
        }
    }
}
