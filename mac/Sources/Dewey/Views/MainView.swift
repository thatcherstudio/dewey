import DeweyCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.checkedOnce {
            ProgressView("Checking setup…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.showsMain {
            MainView()
        } else {
            SetupView()
                .toolbar { ToolbarItem(placement: .primaryAction) { LayaStatusView() } }
        }
    }
}

/// Sidebar of folders; the detail shows the selected folder (or the setup checks).
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            Group {
                switch model.selection {
                case .setup:
                    SetupView()
                        .navigationTitle("Setup")
                case .folder(let path):
                    FolderDetail(folder: model.folder(path))
                        .id(path)
                case nil:
                    NoFolderView()
                }
            }
            .toolbar { ToolbarItem(placement: .primaryAction) { LayaStatusView() } }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Folders") {
                ForEach(model.folders.paths, id: \.self) { path in
                    let folder = model.folder(path)
                    FolderRow(folder: folder)
                        .tag(SidebarItem.folder(path))
                        .contextMenu {
                            Button("Show in Finder") { folder.showInFinder() }
                            Divider()
                            Button("Remove from Sidebar") { model.removeFolder(path) }
                                .disabled(folder.isRunning)
                        }
                }
                .onMove { model.folders.move(fromOffsets: $0, toOffset: $1) }
            }
            Section("Dewey") {
                HStack {
                    Label("Setup", systemImage: "wrench.and.screwdriver")
                    Spacer()
                    if !model.layaServe.isOK {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("laya-serve isn't installed: plans use rules and duplicates only.")
                    }
                }
                .tag(SidebarItem.setup)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.chooseFolders()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a folder to organize (⌘O). You can also drop folders here.")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
            }
        }
    }
}

struct FolderRow: View {
    let folder: FolderModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.exists ? "folder" : "questionmark.folder")
                .foregroundStyle(folder.exists ? Color.accentColor : .orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name).lineLimit(1)
                Text(folder.parentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if folder.isRunning {
                ProgressView().controlSize(.small)
            } else if folder.hasUnsavedChanges || folder.hasUnsavedSettings {
                Circle().fill(.blue).frame(width: 7, height: 7)
                    .help(folder.hasUnsavedChanges ? "Unsaved changes to the plan" : "Unsaved settings")
            }
        }
        .help(folder.exists ? folder.displayPath : "\(folder.displayPath) isn't there any more")
    }
}

/// No folder yet (or none selected).
struct NoFolderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(model.folders.paths.isEmpty ? "Add a folder to organize" : "Choose a folder")
                .font(.title2.bold())
            Text("Downloads, Desktop, an old backup: Dewey catalogs it, finds duplicates and suggests where "
                 + "each file belongs. Nothing moves until you approve it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Add Folder…") { model.chooseFolders() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("or drop a folder on the sidebar")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One folder: a run screen while there is one (Scan & Plan, Move, Undo), otherwise its tabs.
struct FolderDetail: View {
    @Bindable var folder: FolderModel

    var body: some View {
        Group {
            if let session = folder.session {
                RunView(folder: folder, session: session)
            } else if let run = folder.moveRun {
                MoveRunView(folder: folder, run: run)
            } else if let run = folder.undoRun {
                UndoRunView(folder: folder, run: run)
            } else {
                switch folder.tab {
                case .overview: OverviewView(folder: folder)
                case .review: ReviewTab(folder: folder)
                case .apply: ApplyTab(folder: folder)
                case .history: HistoryView(folder: folder)
                case .settings: SettingsTab(folder: folder)
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationSubtitle(folder.parentPath)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $folder.tab) {
                    ForEach(FolderModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(folder.showsRun)
                .help(folder.showsRun ? "Finish or close the run first" : "")
            }
        }
        .task { await folder.refresh() }
    }
}

/// A rounded box used by the overview cards and run results.
struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
