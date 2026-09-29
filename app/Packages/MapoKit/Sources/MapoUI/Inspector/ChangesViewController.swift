import AppKit
import MapoClient
import MapoProtocol

/// The Changes segment (UX §5.3, PLAN T4.3): the files changed against HEAD in the repository of the last
/// focused tab, from `git.status`, with a summary row, the size warning and one row per file. It refreshes
/// on `fs.changed` and `git.changed` under the repository (R-GIT-3). Selecting a row shows its diff in the
/// workspace's file pane without taking focus; Return or a double-click opens the file.
public final class ChangesViewController: NSViewController {
    private let client: MapoClient
    private let summary = ChangesSummaryView()
    private let warning = ChangesWarningView()
    private let list = ChangesListView()
    private let scroll = NSScrollView()
    private let stateView = ChangesStateView()

    /// The folder followed (the focused tab's cwd).
    private var folder: String?
    private var changes: GitChanges?
    private var rows: [ChangesRowView] = []
    private var selectedPath: String?
    private var state: ChangesState = .noTerminal
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var loadingTimer: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var connectedBoot: String?
    /// Folders this segment watches: the repository root and the folders of changed files (at most 50).
    private var watched: Set<String> = []

    /// Called with `totals.files` after every refresh, for the segment's badge.
    var onCountChange: ((Int) -> Void)?

    public init(client: MapoClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChangesViewController is built in code")
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        list.setAccessibilityElement(true)
        list.setAccessibilityRole(.list)
        list.setAccessibilityLabel("Changes")
        list.onMove = { [weak self] delta in self?.move(delta) }
        list.onReturn = { [weak self] in self?.openSelectedFile() }
        stateView.onRetry = { [weak self] in self?.refresh(showLoading: true) }
        for view in [summary, warning, scroll, stateView] as [NSView] { root.addSubview(view) }
        view = root
        show(.noTerminal)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        client.addEventListener { [weak self] event in self?.handle(event) }
        observeContinuously(self) { $0.follow() }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutContent()
    }

    // MARK: Following the focused tab

    private var targetFolder: String? {
        let store = client.store
        guard let workspaceId = store.activeWorkspaceId,
            let tabId = store.focusedTabId(inWorkspace: workspaceId), let tab = store.tabs[tabId]
        else { return nil }
        let cwd = tab.cwd.isEmpty ? (tab.launch?.cwd ?? "") : tab.cwd
        return cwd.isEmpty ? nil : cwd
    }

    private func follow() {
        let boot: String? = if case .connected(let bootId) = client.store.connection { bootId } else { nil }
        var target = targetFolder
        // A focused file or diff pane keeps the last focused tab's repository (R-FS-2).
        if target == nil, let workspaceId = client.store.activeWorkspaceId,
            client.store.focusedPane(inWorkspace: workspaceId).content.isFile
        {
            target = folder
        }
        let reconnected = boot != connectedBoot
        connectedBoot = boot
        // Watches are per connection: a new one starts with none.
        if reconnected { watched.removeAll() }
        guard target != folder || (reconnected && boot != nil) else { return }
        let rooted = target != folder
        folder = target
        if rooted {
            changes = nil
            selectedPath = nil
        }
        refresh(showLoading: rooted)
    }

    // MARK: Loading

    /// Reads `git.status` for the followed folder; a newer refresh supersedes an older one.
    private func refresh(showLoading: Bool) {
        generation += 1
        let generation = generation
        refreshTask?.cancel()
        loadingTimer?.cancel()
        guard let folder else {
            updateWatches(nil)
            show(.noTerminal)
            onCountChange?(0)
            return
        }
        guard client.store.isConnected else { return }
        if showLoading || state == .noTerminal {
            loadingTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.show(.loading)
            }
        }
        let client = client
        refreshTask = Task { [weak self] in
            let result: Result<GitChanges, Error>
            do { result = .success(try await client.gitStatus(path: folder)) } catch { result = .failure(error) }
            guard let self, self.generation == generation else { return }
            self.loadingTimer?.cancel()
            switch result {
            case .success(let changes):
                self.apply(changes)
            case .failure(let error as RPCError) where error.kind == .notFound:
                self.changes = nil
                self.updateWatches(nil)
                self.onCountChange?(0)
                self.show(.notRepository)
            case .failure(let error):
                self.changes = nil
                self.onCountChange?(0)
                self.show(.error, error: (error as? RPCError)?.message ?? "\(error)")
            }
        }
    }

    /// Refreshes shortly after a burst of events.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        let generation = generation
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.refresh(showLoading: false)
        }
    }

    private func apply(_ new: GitChanges) {
        let old = changes
        changes = new
        updateWatches(new)
        onCountChange?(new.totals.files)
        summary.configure(new)
        if let warn = new.warn { warning.configure(warn) }
        warning.isHidden = new.warn == nil
        if old?.files != new.files || old?.root != new.root {
            for row in rows { row.removeFromSuperview() }
            rows = new.files.map { file in
                let row = ChangesRowView(file, absolutePath: absolute(file.path, root: new.root))
                row.onPress = { [weak self, weak row] doubleClick in
                    guard let self, let row else { return }
                    self.view.window?.makeFirstResponder(self.list)
                    self.select(row.file.path, showDiff: !doubleClick)
                    if doubleClick { self.openSelectedFile() }
                }
                list.addSubview(row)
                return row
            }
            if let selectedPath, !new.files.contains(where: { $0.path == selectedPath }) { self.selectedPath = nil }
            updateSelection()
        }
        show(new.files.isEmpty ? .clean : .ready)
    }

    // MARK: Watches

    /// Watches the repository root (its `HEAD`, index and refs come with it) and the folders holding changed
    /// files, so edits, commits and branch switches refresh the list even while Files shows another folder.
    private func updateWatches(_ changes: GitChanges?) {
        var wanted = Set<String>()
        if let changes {
            wanted.insert(changes.root)
            for file in changes.files {
                guard wanted.count < 50 else { break }
                let folder = (absolute(file.path, root: changes.root) as NSString).deletingLastPathComponent
                if FileManager.default.fileExists(atPath: folder) { wanted.insert(folder) }
            }
        }
        for folder in watched.subtracting(wanted) { send("fs.unwatch", folder) }
        for folder in wanted.subtracting(watched) { send("fs.watch", folder) }
        watched = wanted
    }

    private func send(_ method: String, _ path: String) {
        let client = client
        Task {
            do {
                _ = try await client.call(method, FsPathParams(path: path), as: EmptyObject.self)
            } catch {
                MapoLog.shared.debug("changes: \(method) \(path) failed: \(error)")
            }
        }
    }

    // MARK: Events (R-GIT-3)

    private func handle(_ event: Event) {
        let root = changes?.root ?? folder
        guard let root else { return }
        switch event.payload {
        case .fsChanged(let change):
            if change.root == root || change.root.hasPrefix(root + "/") { scheduleRefresh() }
        case .gitChanged(let change):
            if change.root == root || root.hasPrefix(change.root + "/") || folder == change.root { scheduleRefresh() }
        default:
            break
        }
    }

    // MARK: Selection

    private func select(_ path: String, showDiff: Bool) {
        selectedPath = path
        updateSelection()
        if showDiff { openDiff(path, delay: .zero) }
    }

    private func move(_ delta: Int) {
        guard let files = changes?.files, !files.isEmpty else { return }
        let index =
            selectedPath.flatMap { path in files.firstIndex { $0.path == path } } ?? (delta > 0 ? -1 : files.count)
        let next = min(max(index + delta, 0), files.count - 1)
        selectedPath = files[next].path
        updateSelection()
        if let row = rows.first(where: { $0.file.path == files[next].path }) { list.scrollToVisible(row.frame) }
        // ↑ and ↓ step through diffs, debounced 100 ms (UX §5.3).
        openDiff(files[next].path, delay: .milliseconds(100))
    }

    private func updateSelection() {
        for row in rows { row.isSelected = row.file.path == selectedPath }
    }

    private func openDiff(_ relativePath: String, delay: Duration) {
        guard let root = changes?.root else { return }
        let client = client
        let path = absolute(relativePath, root: root)
        diffTask?.cancel()
        diffTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            do {
                try await client.openDiff(root: root, path: path)
            } catch {
                MapoLog.shared.info("changes: diff.open \(path) failed: \(error)")
                NSSound.beep()
            }
        }
    }

    /// Return or a double-click: the file opens in the editor, which takes focus. A deleted file beeps.
    private func openSelectedFile() {
        guard let root = changes?.root, let selectedPath else { return }
        let path = absolute(selectedPath, root: root)
        let client = client
        Task {
            do {
                let opened = try await client.openFile(path: path)
                FileEditors.focusWhenShown(opened.path)
            } catch {
                MapoLog.shared.info("changes: open \(path): file.open failed: \(error)")
                NSSound.beep()
            }
        }
    }

    private func absolute(_ relativePath: String, root: String) -> String {
        root.hasSuffix("/") ? root + relativePath : "\(root)/\(relativePath)"
    }

    // MARK: States and layout

    private func show(_ new: ChangesState, error: String? = nil) {
        state = new
        let ready = new == .ready
        summary.isHidden = changes == nil
        if changes == nil { warning.isHidden = true }
        scroll.isHidden = !ready
        stateView.isHidden = ready
        if !ready { stateView.configure(new, path: folder ?? "", error: error) }
        layoutContent()
    }

    private func layoutContent() {
        let bounds = view.bounds
        let width = bounds.width
        var y = bounds.height
        if !summary.isHidden {
            y -= 36
            summary.frame = NSRect(x: 0, y: y, width: width, height: 36)
        }
        if !warning.isHidden {
            let height = warning.height(for: width)
            y -= height
            warning.frame = NSRect(x: 0, y: y, width: width, height: height)
        }
        scroll.frame = NSRect(x: 0, y: 8, width: width, height: max(0, y - 8))
        stateView.frame = NSRect(x: 0, y: 0, width: width, height: max(0, y))
        let listWidth = scroll.contentSize.width
        list.frame = NSRect(
            x: 0, y: 0, width: listWidth,
            height: max(scroll.contentSize.height, CGFloat(rows.count) * ChangesRowView.height))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: 0, y: CGFloat(index) * ChangesRowView.height, width: listWidth, height: ChangesRowView.height)
        }
    }
}
