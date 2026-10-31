import AppKit

final class CleanupWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private struct Row {
        let target: CacheTarget
        var size: UInt64?
        var checked: Bool
        var cleaned = false
    }

    private var rows: [Row] = []
    private let tableView = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: tr("Calcul des tailles…"))
    private let cleanButton = NSButton(title: tr("Nettoyer la sélection"), target: nil, action: nil)
    private var isWorking = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = tr("Nettoyage du disque")
        window.center()
        self.init(window: window)
        buildInterface()
        loadTargets()
    }

    // MARK: - Interface

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        headerLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView

        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset
        let column = NSTableColumn(identifier: .init("main"))
        column.width = 540
        tableView.addTableColumn(column)

        cleanButton.target = self
        cleanButton.action = #selector(cleanSelection)
        cleanButton.bezelStyle = .rounded
        cleanButton.keyEquivalent = "\r"

        let close = NSButton(title: tr("Fermer"), target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded

        let buttons = NSStackView(views: [statusLabel, NSView(), close, cleanButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [headerLabel, scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        updateHeader()
    }

    private func updateHeader() {
        let disk = DiskCleanup.diskSpace()
        let percent = Int(disk.usedRatio * 100)
        headerLabel.stringValue =
            tr("Disque : %@ libres sur %@ — occupé à %lld %%",
                formatBytes(disk.free), formatBytes(disk.total), percent)
        headerLabel.textColor = disk.isTight ? .systemOrange : .labelColor
    }

    // MARK: - Données

    private func loadTargets() {
        rows = DiskCleanup.allTargets().map {
            Row(target: $0, size: nil, checked: $0.checkedByDefault)
        }
        tableView.reloadData()
        updateCleanButton()

        // `du` sur des dizaines de Go prend plusieurs secondes : hors du thread principal,
        // avec affichage au fil de l'eau.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for index in self.rows.indices {
                let target = self.rows[index].target
                let size = DiskCleanup.size(of: target)
                DispatchQueue.main.async {
                    guard index < self.rows.count else { return }
                    self.rows[index].size = size
                    self.sortRows()
                    self.tableView.reloadData()
                    self.updateCleanButton()
                }
            }
            DispatchQueue.main.async { self.statusLabel.stringValue = "" }
        }
    }

    /// Les données signalées restent en bas : elles ne sont pas nettoyables ici.
    private func sortRows() {
        rows.sort { a, b in
            let aData = a.target.kind == .data
            let bData = b.target.kind == .data
            if aData != bData { return !aData }
            return (a.size ?? 0) > (b.size ?? 0)
        }
    }

    private var selectedSize: UInt64 {
        rows.filter { $0.checked && !$0.cleaned }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    private func updateCleanButton() {
        let total = selectedSize
        cleanButton.isEnabled = total > 0 && !isWorking
        cleanButton.title =
            total > 0
            ? tr("Nettoyer la sélection (%@)", formatBytes(total)) : tr("Nettoyer la sélection")
    }

    // MARK: - Tableau

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let model = rows[row]
        let container = NSView()

        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
        check.tag = row
        check.state = model.checked ? .on : .off
        check.isEnabled = model.target.isRemovable && !model.cleaned && !isWorking

        let name = NSTextField(labelWithString: model.target.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)

        let detailText =
            model.cleaned
            ? tr("Nettoyé")
            : model.target.isSymlinked
                ? tr("Lien symbolique : ignoré, pour ne pas vider le dossier visé")
                : model.target.detail
        let detail = NSTextField(labelWithString: detailText)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = model.target.isRemovable ? .secondaryLabelColor : .systemOrange

        let sizeText: String
        if model.cleaned {
            sizeText = "—"
        } else if let size = model.size {
            sizeText = formatBytes(size)
        } else {
            sizeText = "…"
        }
        let sizeLabel = NSTextField(labelWithString: sizeText)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.alignment = .right
        sizeLabel.textColor = model.cleaned ? .tertiaryLabelColor : .labelColor

        for view in [check, name, detail, sizeLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            check.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
            name.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(
                lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -8),
            sizeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            sizeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])
        return container
    }

    @objc private func toggleRow(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        rows[sender.tag].checked = sender.state == .on
        updateCleanButton()
    }

    // MARK: - Nettoyage

    @objc private func cleanSelection() {
        let selected = rows.filter { $0.checked && !$0.cleaned && $0.target.isRemovable }
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = tr(
            count: selected.count, one: "Vider 1 cache ?", other: "Vider %lld caches ?")
        alert.informativeText =
            selected.map { "• \($0.target.name) — \($0.size.map(formatBytes) ?? "?")" }
            .joined(separator: "\n") + "\n\n"
            + tr(
                "Le contenu est supprimé définitivement (pas de passage par la corbeille). "
                    + "Ces caches se reconstruisent tout seuls ; le prochain build sera plus lent.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("Vider"))
        alert.addButton(withTitle: tr("Annuler"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isWorking = true
        statusLabel.stringValue = tr("Nettoyage…")
        updateCleanButton()
        tableView.reloadData()

        let targets = selected.map(\.target)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var freed: UInt64 = 0
            var errors: [String] = []
            for target in targets {
                let result = DiskCleanup.clean(target)
                freed &+= result.freed
                errors.append(contentsOf: result.errors.prefix(3))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isWorking = false
                for index in self.rows.indices where targets.contains(where: {
                    $0.path == self.rows[index].target.path
                }) {
                    self.rows[index].cleaned = true
                    self.rows[index].checked = false
                }
                self.updateHeader()
                self.tableView.reloadData()
                self.updateCleanButton()
                self.statusLabel.stringValue =
                    errors.isEmpty
                    ? tr("%@ libérés", formatBytes(freed))
                    : tr("%@ libérés", formatBytes(freed)) + " · "
                        + tr(
                            count: errors.count, one: "1 élément verrouillé",
                            other: "%lld éléments verrouillés")
            }
        }
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
