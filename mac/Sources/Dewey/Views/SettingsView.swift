import AppKit
import DeweyCore
import SwiftUI

/// The Settings tab: made the first time it opens, then kept with the folder (unsaved changes too).
struct SettingsTab: View {
    let folder: FolderModel

    var body: some View {
        Group {
            if let settings = folder.settings {
                FolderSettingsView(folder: folder, settings: settings)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { folder.makeSettings() }
    }
}

/// This folder's dewey.toml as a form: the folders the model files into, rules, how sure it must be,
/// and how the plan is laid out. Save writes only what differs from dewey's defaults.
struct FolderSettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case folders = "Folders", rules = "Rules", decisions = "Decisions", plan = "Plan"
        var id: String { rawValue }
    }

    let folder: FolderModel
    @Bindable var settings: FolderSettings
    @State private var page = Page.folders

    var body: some View {
        VStack(spacing: 0) {
            if let file = settings.file, !file.valid {
                BrokenSettingsView(settings: settings, file: file)
            } else if let draft = settings.draft {
                Picker("Settings", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 12)
                pageView(Binding(get: { settings.draft ?? draft }, set: { settings.draft = $0 }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = settings.error {
                Notice(systemImage: "exclamationmark.triangle.fill", tint: .red,
                       text: error.errorDescription ?? "\(error)") {
                    Button("Try Again") { Task { await settings.load() } }
                }
                .frame(minWidth: 480)
                .padding(20)
                Spacer()
            } else {
                ProgressView("Reading settings…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if settings.draft != nil, let error = settings.error {
                Notice(systemImage: "exclamationmark.triangle.fill", tint: .red,
                       text: "Not saved: " + (error.errorDescription ?? "\(error)")) {
                    Button("OK") { settings.clearError() }
                }
                .frame(minWidth: 480)  // wrapped text outside a scroll view: see ApplyView
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            if settings.file?.valid != false {  // a broken file has its own buttons
                Divider()
                footer
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .task { if settings.file == nil { await settings.load() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await settings.load() }  // dewey.toml may have been edited in a text editor
        }
    }

    @ViewBuilder
    private func pageView(_ draft: Binding<FolderConfig>) -> some View {
        let defaults = settings.defaults
        switch page {
        case .folders: CategoriesPage(draft: draft, defaults: defaults)
        case .rules: RulesPage(draft: draft, defaults: defaults)
        case .decisions: DecisionsPage(draft: draft, defaults: defaults)
        case .plan: PlanPage(draft: draft, defaults: defaults)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem = settings.problems.first {
                Label(problem + (settings.problems.count > 1 ? " (and \(settings.problems.count - 1) more)" : ""),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let notice = settings.notice {
                Text(notice).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(whereSaved).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let file = settings.file, file.exists {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                }
            }
            Button("Revert") { settings.revert() }
                .disabled(!settings.hasChanges)
                .help("Drop the changes made here since the last save")
            Button(settings.saving ? "Saving…" : "Save") {
                Task { if await settings.save() { folder.settingsSaved() } }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!settings.canSave)
        }
        .controlSize(.large)
    }

    private var whereSaved: String {
        guard let file = settings.file else { return "" }
        if file.exists { return "Saved in .dewey/dewey.toml, with only what differs from dewey's defaults." }
        if let source = file.source {
            return "Using \((source as NSString).abbreviatingWithTildeInPath). Saving writes this folder's own "
                + ".dewey/dewey.toml."
        }
        return "Using dewey's defaults. Saving writes .dewey/dewey.toml with only what you change."
    }
}

// MARK: - pages

/// A page's title and what it's for.
private struct PageIntro: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 480, maxWidth: .infinity, alignment: .leading)  // see ApplyView
    }
}

/// The folders the model can file into (`[categories]`), in order.
private struct CategoriesPage: View {
    @Binding var draft: FolderConfig
    let defaults: FolderConfig?
    /// No row selection: with it, the first click on a field selects the row instead of editing.
    @FocusState private var focus: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageIntro(title: "Folders for the model",
                      text: "For each file no rule claims, the model picks one of these by reading the descriptions: "
                          + "short and concrete works best. Leave “Goes to” empty to keep those files where they are.")
                .padding(.horizontal, 20)
            HStack(spacing: 8) {
                Text("Name").frame(width: 150, alignment: .leading)
                Text("Goes to").frame(width: 200, alignment: .leading)
                Text("Description (what the model reads)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 17)
            List {
                ForEach($draft.categories) { $c in
                    HStack(spacing: 8) {
                        TextField("Name", text: $c.key, prompt: Text("name"))
                            .focused($focus, equals: c.id)
                            .frame(width: 150)
                            .overlay(alignment: .trailing) {
                                if let why = problem(c) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                        .padding(.trailing, 4)
                                        .help(why)
                                }
                            }
                        TextField("Goes to", text: $c.path, prompt: Text("leave in place"))
                            .frame(width: 200)
                        TextField("Description", text: $c.desc, prompt: Text("what goes here, in a few words"))
                        Button("Remove", systemImage: "minus.circle") {
                            let id = c.id
                            draft.categories.removeAll { $0.id == id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove this folder (files the model would put here go elsewhere)")
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }
                .onMove { draft.categories.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack(spacing: 8) {
                Button("Add Folder", systemImage: "plus") {
                    let new = FolderConfig.Category()
                    draft.categories.append(new)
                    DispatchQueue.main.async { focus = new.id }  // once its row exists
                }
                Text("Drag a row to reorder.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Default Folders") { if let defaults { draft.categories = defaults.categories } }
                    .disabled(defaults == nil || defaults?.categories == draft.categories)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private func problem(_ c: FolderConfig.Category) -> String? {
        let key = c.key.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return "Needs a name" }
        if draft.categories.filter({ $0.key.trimmingCharacters(in: .whitespaces) == key }).count > 1 {
            return "Two folders have this name"
        }
        return nil
    }
}

/// `[[rules]]`: the list on the left (first match wins), the selected rule on the right.
private struct RulesPage: View {
    @Binding var draft: FolderConfig
    let defaults: FolderConfig?
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageIntro(title: "Rules",
                      text: "Rules run before the model, top to bottom: the first one that matches a file decides where "
                          + "it goes. Files no rule matches go to the model.")
                .padding(.horizontal, 20)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(draft.rules) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name.isEmpty ? "New rule" : r.name).fontWeight(.medium)
                                Text("\(r.matchSummary) → \(r.target.isEmpty ? "?" : r.target)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 2)
                            .tag(r.id)
                        }
                        .onMove { draft.rules.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    HStack(spacing: 8) {
                        Button("Add Rule", systemImage: "plus") {
                            let new = FolderConfig.Rule()
                            let at = selection.flatMap { id in draft.rules.firstIndex { $0.id == id } }.map { $0 + 1 }
                            draft.rules.insert(new, at: at ?? draft.rules.count)
                            selection = new.id
                        }
                        .labelStyle(.iconOnly)
                        .help("Add a rule below the selected one")
                        Button("Remove", systemImage: "minus") {
                            draft.rules.removeAll { $0.id == selection }
                            selection = nil
                        }
                        .labelStyle(.iconOnly)
                        .disabled(selection == nil)
                        Spacer()
                        Button("Restore Defaults") {
                            if let defaults {
                                draft.rules = defaults.rules
                                selection = nil
                            }
                        }
                        .disabled(defaults == nil || defaults?.rules == draft.rules)
                    }
                    .padding(8)
                }
                .frame(width: 320)
                Divider()
                if let i = draft.rules.firstIndex(where: { $0.id == selection }) {
                    RuleEditor(rule: $draft.rules[i], reviewDir: draft.plan.reviewDir)
                        .id(draft.rules[i].id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "list.number").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text(draft.rules.isEmpty ? "No rules: the model decides every file." : "Select a rule to edit it.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .top) { Divider() }
        }
    }
}

private struct RuleEditor: View {
    @Binding var rule: FolderConfig.Rule
    let reviewDir: String

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $rule.name, prompt: Text("screenshots"))
            }
            Section {
                ParsedField(title: "Extensions", prompt: ".pdf .docx", value: $rule.ext,
                            parse: Self.extensions, format: { ($0 ?? []).joined(separator: " ") })
                TextField("Name matches", text: $rule.nameRegex.orEmpty, prompt: Text("a regular expression"))
                TextField("Path matches", text: $rule.pathRegex.orEmpty, prompt: Text("a regular expression"))
                ParsedField(title: "At least (bytes)", prompt: "any size", value: $rule.minSize,
                            parse: Self.bytes, format: { $0.map(String.init) ?? "" })
                ParsedField(title: "At most (bytes)", prompt: "any size", value: $rule.maxSize,
                            parse: Self.bytes, format: { $0.map(String.init) ?? "" })
                Picker("From a camera", selection: $rule.hasCamera) {
                    Text("Doesn't matter").tag(Bool?.none)
                    Text("Yes (the photo says which camera)").tag(Bool?.some(true))
                    Text("No").tag(Bool?.some(false))
                }
            } header: {
                Text("Matches files")
            } footer: {
                Text("Every condition filled in has to match; empty ones are ignored. Patterns are Python regular "
                     + "expressions, matched anywhere in the name or path.")
            }
            Section {
                TextField("Folder", text: $rule.target, prompt: Text("Documents/PDFs"))
                TextField("Reason", text: $rule.reason.orEmpty, prompt: Text("shown in the plan"))
            } header: {
                Text("Goes to")
            } footer: {
                Text("{review} is the review folder (\(reviewDir.isEmpty ? "_Review" : reviewDir)). {year} and {month} "
                     + "come from the photo's date, a date in the name, or the file's date. {camera} is the camera.")
            }
        }
        .formStyle(.grouped)
    }

    /// ".pdf docx, .TXT" → [".pdf", ".docx", ".txt"]; nil when empty.
    static func extensions(_ text: String) -> [String]? {
        let list = text.split(whereSeparator: { $0 == " " || $0 == "," }).map { part -> String in
            let s = part.lowercased()
            return s.hasPrefix(".") ? s : "." + s
        }
        return list.isEmpty ? nil : list
    }

    static func bytes(_ text: String) -> Int64? {
        Int64(text.filter { !$0.isWhitespace && $0 != "," && $0 != "_" })
    }
}

/// The decider, and the two thresholds that turn its confidence into Move, Review or stay.
private struct DecisionsPage: View {
    @Binding var draft: FolderConfig
    let defaults: FolderConfig?

    var body: some View {
        Form {
            Section {
                Picker("Decide with", selection: $draft.decider.backend) {
                    Text("Laya").tag("systemone")
                    Text("A chat model (OpenAI-compatible server)").tag("chat")
                    Text("Rules only, no model").tag("none")
                }
                if draft.decider.backend != "none" {
                    TextField("Server", text: $draft.decider.url, prompt: Text("http://127.0.0.1:8000"))
                    TextField("Model", text: $draft.decider.model,
                              prompt: Text(draft.decider.backend == "chat" ? "mlx-community/Qwen3-4B-Instruct-2507-4bit"
                                                                          : "english"))
                }
                if draft.decider.backend == "chat" {
                    Toggle("Trust the chat model's own confidence", isOn: $draft.decider.trustChatConfidence)
                }
            } header: {
                Text("The model")
            } footer: {
                Text(backendNote)
            }
            Section {
                ThresholdRow(title: "Move without asking at", value: $draft.plan.autoConfidence, range: 0.5...1)
                ThresholdRow(title: "Ask me (Review) from", value: $draft.plan.reviewConfidence, range: 0...1)
                if draft.plan.reviewConfidence > draft.plan.autoConfidence {
                    Label("Review has to be at or below Move.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("How sure the model has to be")
            } footer: {
                Text("\(pct(draft.plan.autoConfidence)) or more: marked Move. \(pct(draft.plan.reviewConfidence)) "
                     + "to \(pct(draft.plan.autoConfidence)): marked Review, for you to check. Below "
                     + "\(pct(draft.plan.reviewConfidence)): left where it is.")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        guard let defaults else { return }
                        draft.decider = defaults.decider
                        draft.plan.autoConfidence = defaults.plan.autoConfidence
                        draft.plan.reviewConfidence = defaults.plan.reviewConfidence
                    }
                    .disabled(defaults == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var backendNote: String {
        switch draft.decider.backend {
        case "systemone": "Laya (or any Jev-compatible server) answers with a calibrated confidence. Dewey can start "
            + "laya-serve for you (Dewey > Settings…)."
        case "chat": "Any OpenAI-compatible server: mlx_lm.server, Ollama, LM Studio. Chat models rate their own "
            + "confidence, which isn't calibrated, so unless you trust it their answers stop just below Move and you "
            + "review them."
        default: "Only the rules decide. Files no rule matches stay where they are."
        }
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

private struct ThresholdRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value }, set: { value = ($0 * 100).rounded() / 100 }), in: range)
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// Where the plan puts things: destination, review folder, duplicates, subfolders, whole folders.
private struct PlanPage: View {
    @Binding var draft: FolderConfig
    let defaults: FolderConfig?

    var body: some View {
        Form {
            Section {
                LabeledContent("Organize into") {
                    HStack {
                        Text(draft.plan.dest.isEmpty ? "This folder" : (draft.plan.dest as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseDest() }
                        if !draft.plan.dest.isEmpty {
                            Button("Use This Folder") { draft.plan.dest = "" }
                        }
                    }
                }
                TextField("Review folder", text: $draft.plan.reviewDir, prompt: Text("_Review"))
                Picker("Of duplicates, keep in place", selection: $draft.plan.keepDuplicate) {
                    Text("The oldest copy").tag("oldest")
                    Text("The newest copy").tag("newest")
                    Text("The copy with the shortest path").tag("shortest_path")
                }
                Picker("Files in subfolders", selection: $draft.plan.maxDepth) {
                    ForEach(depths, id: \.self) { d in Text(Self.depthLabel(d)).tag(d) }
                }
            } header: {
                Text("Where files go")
            } footer: {
                Text("Duplicates, junk and empty files go to the review folder. Nothing is ever deleted.")
            }
            Section {
                Toggle("Move whole folders to a home for their kind", isOn: $draft.folders.move)
                ForEach($draft.folders.kinds) { $k in
                    TextField(k.label.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? k.kind, text: $k.path,
                              prompt: Text("leave in place"))
                }
                .disabled(!draft.folders.move)
            } header: {
                Text("Whole folders")
            } footer: {
                Text("A folder that stays whole gets one row in the plan, with a kind from what's inside it. Leave a "
                     + "kind empty to label those folders and leave them where they are.")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        guard let defaults else { return }
                        let (auto, review) = (draft.plan.autoConfidence, draft.plan.reviewConfidence)
                        draft.plan = defaults.plan
                        draft.plan.autoConfidence = auto  // those are on the Decisions page
                        draft.plan.reviewConfidence = review
                        draft.folders = defaults.folders
                    }
                    .disabled(defaults == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The usual choices, plus whatever dewey.toml says if it's something else.
    private var depths: [Int] {
        let usual = [0, 1, 2, 3, -1]
        return usual.contains(draft.plan.maxDepth) ? usual : [draft.plan.maxDepth] + usual
    }

    static func depthLabel(_ d: Int) -> String {
        switch d {
        case 0: "Leave subfolders whole (only loose files move)"
        case -1: "File every file, splitting folders up"
        case 1: "Files up to 1 folder deep may move"
        default: "Files up to \(d) folders deep may move"
        }
    }

    private func chooseDest() {
        let panel = NSOpenPanel()
        panel.title = "Organize into this folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { draft.plan.dest = url.path }
    }
}

// MARK: - a file dewey can't read

private struct BrokenSettingsView: View {
    let settings: FolderSettings
    let file: SettingsFile
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This folder's settings file has a mistake").font(.title2.bold())
            Notice(systemImage: "exclamationmark.triangle.fill", tint: .red, text: file.error ?? "")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(i + 1)").foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                                Text(line.isEmpty ? " " : line).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 1)
                            .background(i + 1 == errorLine ? Color.red.opacity(0.18) : .clear)
                            .id(i + 1)
                        }
                    }
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(.vertical, 10)
                    .padding(.trailing, 10)
                }
                .onAppear { if let l = errorLine { proxy.scrollTo(l, anchor: .center) } }
                .onChange(of: file.raw) { if let l = errorLine { proxy.scrollTo(l, anchor: .center) } }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Text("Until it's fixed, Scan & Plan and Apply stop with this error. Fix it in a text editor (Dewey checks "
                 + "again when you come back), or start over from dewey's defaults.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open in TextEdit") { openInTextEdit() }
                Button("Check Again") { Task { await settings.load(discarding: true) } }
                Spacer()
                Button("Start Over with Defaults…") { confirmReset = true }
            }
            .controlSize(.large)
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)  // see ApplyView
        .padding(20)
        .confirmationDialog("Start over with dewey's defaults?", isPresented: $confirmReset) {
            Button("Start Over") { Task { await settings.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current file is kept next to it as dewey.toml.bak.")
        }
    }

    private var lines: [Substring] { (file.raw ?? "").split(separator: "\n", omittingEmptySubsequences: false) }

    /// "… (at line 68, column 22)" from tomllib: the line to show.
    private var errorLine: Int? {
        guard let e = file.error, let r = e.range(of: #"at line \d+"#, options: .regularExpression) else { return nil }
        return Int(e[r].dropFirst("at line ".count))
    }

    private func openInTextEdit() {
        let url = URL(fileURLWithPath: file.source ?? file.path)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - helpers

/// A text field for a value that isn't text (a list, a number): what's typed stays as typed while
/// it parses to the same value; a change from elsewhere (Revert) rewrites it.
private struct ParsedField<Value: Equatable>: View {
    let title: String
    let prompt: String
    @Binding var value: Value
    let parse: (String) -> Value
    let format: (Value) -> String
    @State private var text = ""

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .onAppear { text = format(value) }
            .onChange(of: text) { _, t in
                let v = parse(t)
                if v != value { value = v }
            }
            .onChange(of: value) { _, v in
                if parse(text) != v { text = format(v) }
            }
    }
}

extension Binding where Value == String? {
    /// Empty text for nil, and nil for empty text.
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
