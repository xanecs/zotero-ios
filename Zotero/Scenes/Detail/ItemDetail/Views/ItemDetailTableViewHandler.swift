//
//  ItemDetailTableViewHandler.swift
//  Zotero
//
//  Created by Michal Rentka on 21/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxSwift

protocol ItemDetailTableViewHandlerDelegate: AnyObject {
    func isDownloadingFromNavigationBar(for index: Int) -> Bool
}

/// Class for handling the `UITableView` of `ItemDetailViewController`. It takes care of showing appropriate data in the `tableView`, keeping track
/// of visible sections and reports actions that need to take place after user interaction with the `tableView`.
final class ItemDetailTableViewHandler: NSObject {
    /// Actions that need to take place when user taps on some cells
    enum Action {
        case openCreatorCreation
        case openCreatorEditor(ItemDetailState.Creator)
        case openNoteEditor(Note?)
        case openTagPicker
        case openTypePicker
        case openFilePicker
        case openUrl(String)
        case openDoi(String)
        case showAttachmentError(Error, Int)
        case trashAttachment(Attachment)
    }

    /// Sections that are shown in `tableView`
    enum Section: CaseIterable, Equatable, Hashable {
        case abstract, attachments, creators, dates, fields, notes, tags, title, type
    }

    enum Row: Hashable, Equatable {
        case add
        case abstract(value: String, collapsed: Bool)
        case attachment(attachment: Attachment, progress: CGFloat?, error: Error?, enabled: Bool)
        case creator(ItemDetailState.Creator)
        case dateAdded(Date)
        case dateModified(Date)
        case field(field: ItemDetailState.Field, multiline: Bool)
        case note(Note)
        case tag(Tag)
        case title(String)
        case type(String)

        func cellId(isEditing: Bool) -> String {
            switch self {
            case .abstract:
                if isEditing {
                    return "ItemDetailAbstractEditCell"
                } else {
                    return "ItemDetailAbstractCell"
                }
            case .attachment:
                return "ItemDetailAttachmentCell"
            case .note:
                return "ItemDetailNoteCell"
            case .tag:
                return "ItemDetailTagCell"
            case .field(_, let multiline):
                if isEditing {
                    if multiline {
                        return "ItemDetailFieldMultilineEditCell"
                    } else {
                        return "ItemDetailFieldEditCell"
                    }
                } else {
                    return "ItemDetailFieldCell"
                }
            case .type, .dateAdded, .dateModified, .creator:
                return "ItemDetailFieldCell"
            case .title:
                return "ItemDetailTitleCell"
            case .add:
                return "ItemDetailAddCell"
            }
        }

        static func == (lhs: ItemDetailTableViewHandler.Row, rhs: ItemDetailTableViewHandler.Row) -> Bool {
            switch (lhs, rhs) {
            case (.add, .add):
                return true
            case (.abstract(let lValue, let lCollapsed), .abstract(let rValue, let rCollapsed)):
                return lValue == rValue && lCollapsed == rCollapsed
            case (.attachment(let lAttachment, let lProgress, let lError, let lEnabled), .attachment(let rAttachment, let rProgress, let rError, let rEnabled)):
                return lAttachment == rAttachment && lProgress == rProgress && lError?.localizedDescription == rError?.localizedDescription && lEnabled == rEnabled
            case (.creator(let lCreator), .creator(let rCreator)):
                return lCreator == rCreator
            case (.dateAdded(let lDate), .dateAdded(let rDate)):
                return lDate == rDate
            case (.dateModified(let lDate), .dateModified(let rDate)):
                return lDate == rDate
            case (.field(let lField, let lMultiline), .field(let rField, let rMultiline)):
                return lField == rField && lMultiline == rMultiline
            case (.note(let lNote), .note(let rNote)):
                return lNote == rNote
            case (.tag(let lTag), .tag(let rTag)):
                return lTag == rTag
            case (.title(let lValue), .title(let rValue)):
                return lValue == rValue
            case (.type(let lValue), .type(let rValue)):
                return lValue == rValue
            default:
                return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .add:
                hasher.combine(0)
            case .abstract(let value, let collapsed):
                hasher.combine(1)
                hasher.combine(value)
                hasher.combine(collapsed)
            case .attachment(let attachment, let progress, let error, let enabled):
                hasher.combine(2)
                hasher.combine(attachment)
                hasher.combine(progress)
                hasher.combine(error?.localizedDescription)
                hasher.combine(enabled)
            case .creator(let creator):
                hasher.combine(3)
                hasher.combine(creator)
            case .dateAdded(let date):
                hasher.combine(4)
                hasher.combine(date)
            case .dateModified(let date):
                hasher.combine(5)
                hasher.combine(date)
            case .field(let field, let multiline):
                hasher.combine(6)
                hasher.combine(field)
                hasher.combine(multiline)
            case .note(let note):
                hasher.combine(7)
                hasher.combine(note)
            case .tag(let tag):
                hasher.combine(8)
                hasher.combine(tag)
            case .title(let value):
                hasher.combine(9)
                hasher.combine(value)
            case .type(let value):
                hasher.combine(10)
                hasher.combine(value)
            }
        }
    }

    // Identifier for section view
    private static let sectionId = "ItemDetailSectionView"
    private static let cellIds: [String] = ["ItemDetailAddCell", "ItemDetailFieldCell", "ItemDetailFieldEditCell", "ItemDetailFieldMultilineEditCell", "ItemDetailTagCell", "ItemDetailNoteCell",
                                            "ItemDetailAttachmentCell", "ItemDetailAbstractCell", "ItemDetailAbstractEditCell"]

    private unowned let viewModel: ViewModel<ItemDetailActionHandler>
    private unowned let tableView: UITableView
    private let disposeBag: DisposeBag
    let observer: PublishSubject<Action>

    private var sections: [Section] = []
    // Width of title for field cells when editing is enabled (all fields are visible)
    private var maxTitleWidth: CGFloat = 0
    // Width of title for field cells when editing is disabled (only non-empty fields are visible)
    private var maxNonemptyTitleWidth: CGFloat = 0
    private var dataSource: DiffableDataSource<Section, Row>!
    private weak var fileDownloader: AttachmentDownloader?
    weak var delegate: ItemDetailTableViewHandlerDelegate?

    var attachmentSection: Int {
        return self.sections.firstIndex(of: .attachments) ?? 0
    }

    init(tableView: UITableView, containerWidth: CGFloat, viewModel: ViewModel<ItemDetailActionHandler>, fileDownloader: AttachmentDownloader?) {
        self.tableView = tableView
        self.viewModel = viewModel
        self.fileDownloader = fileDownloader
        self.observer = PublishSubject()
        self.disposeBag = DisposeBag()

        super.init()

        self.sections = self.sections(for: viewModel.state.data, isEditing: viewModel.state.isEditing)
        let (titleWidth, nonEmptyTitleWidth) = self.calculateTitleWidths(for: viewModel.state.data)
        self.maxTitleWidth = titleWidth
        self.maxNonemptyTitleWidth = nonEmptyTitleWidth
        self.setupTableView()
        self.setupKeyboardObserving()
    }

    // MARK: - Actions

    func sourceDataForCell(at indexPath: IndexPath) -> (UIView, CGRect?) {
        return (self.tableView, self.tableView.cellForRow(at: indexPath)?.frame)
    }

    func reload(state: ItemDetailState, animated: Bool) {
        var snapshot = DiffableDataSourceSnapshot<Section, Row>(isEditing: state.isEditing)
        for section in self.sections(for: state.data, isEditing: state.isEditing) {
            snapshot.append(section: section)
            snapshot.append(objects: self.rows(for: section, state: state), for: section)
        }
        let animation: DiffableDataSourceAnimation = animated ? .animate(reload: .automatic, insert: .automatic, delete: .automatic) : .none
        self.dataSource.apply(snapshot: snapshot, animation: animation, completion: nil)
    }

//    func updateAttachmentCell(with attachment: Attachment, at index: Int) {
//        guard let section = self.sections.firstIndex(of: .attachments) else { return }
//        let indexPath = IndexPath(row: index, section: section)
//        guard let cell = self.tableView.cellForRow(at: indexPath) as? ItemDetailAttachmentCell else { return }
//        self.setup(attachmentCell: cell, at: indexPath.row)
//    }

    /// Recalculates title width for current data.
    /// - parameter data: New data that change the title width.
//    func reloadTitleWidth(from data: ItemDetailState.Data) {
//        let (titleWidth, nonEmptyTitleWidth) = self.calculateTitleWidths(for: data)
//        self.maxTitleWidth = titleWidth
//        self.maxNonemptyTitleWidth = nonEmptyTitleWidth
//    }
//
//    /// Reloads given section (without header or footer) in `tableView`.
//    /// - parameter section: Section to reload.
//    func reload(section: Section) {
//        guard let section = self.sections.firstIndex(of: section) else { return }
//        let rows = self.tableView(self.tableView, numberOfRowsInSection: section)
//        let indexPaths = (0..<rows).map({ IndexPath(row: $0, section: section) })
//        self.tableView.reloadRows(at: indexPaths, with: .none)
//    }
//
//    /// Reloads all sections based on given state.
//    /// - parameter state: New state that changes sections.
//    func reloadSections(to state: ItemDetailState, animated: Bool) {
//        if !animated {
//            self.sections = self.sections(for: state.data, isEditing: state.isEditing)
//            self.tableView.reloadData()
//            return
//        }
//
//        let sections = self.sections(for: state.data, isEditing: state.isEditing)
//        let (insertions, deletions) = sections.difference(from: self.sections).separated
//        let reloads = Set(0..<self.sections.count).subtracting(Set(deletions))
//        self.sections = sections
//
//        self.tableView.performBatchUpdates({
//            if !deletions.isEmpty {
//                self.tableView.deleteSections(IndexSet(deletions), with: .automatic)
//            }
//            if !reloads.isEmpty {
//                self.tableView.reloadSections(IndexSet(reloads), with: .automatic)
//            }
//            if !insertions.isEmpty {
//                self.tableView.insertSections(IndexSet(insertions), with: .automatic)
//            }
//            self.tableView.setEditing(state.isEditing, animated: true)
//        }, completion: nil)
//    }
//
//    /// Reloads `tableView` based on diff.
//    /// - parameter diff: Diff that changes the `tableView`.
//    func reload(with diff: ItemDetailState.Diff) {
//        guard let section = self.section(from: diff) else { return }
//        let insertions = diff.insertions.map({ IndexPath(row: $0, section: section) })
//        let deletions = diff.deletions.map({ IndexPath(row: $0, section: section) })
//        let reloads = diff.reloads.map({ IndexPath(row: $0, section: section) })
//
//        self.tableView.performBatchUpdates({
//            if !deletions.isEmpty {
//                self.tableView.deleteRows(at: deletions, with: .automatic)
//            }
//            if !reloads.isEmpty {
//                self.tableView.reloadRows(at: reloads, with: .automatic)
//            }
//            if !insertions.isEmpty {
//                self.tableView.insertRows(at: insertions, with: .automatic)
//            }
//        }, completion: nil)
//    }

    // MARK: - Helpers
//
//    private func section(from diff: ItemDetailState.Diff) -> Int? {
//        switch diff {
//        case .attachments:
//            if let index = self.sections.firstIndex(of: .attachments) {
//                return index
//            }
//        case .creators:
//            if let index = self.sections.firstIndex(of: .creators) {
//                return index
//            }
//        case .notes:
//            if let index = self.sections.firstIndex(of: .notes) {
//                return index
//            }
//        case .tags:
//            if let index = self.sections.firstIndex(of: .tags) {
//                return index
//            }
//        }
//        return nil
//    }

//    private func updateCellHeightsAndScroll(to indexPath: IndexPath) {
//        UIView.setAnimationsEnabled(false)
//        self.tableView.beginUpdates()
//        self.tableView.endUpdates()
//
//        let cellFrame =  self.tableView.rectForRow(at: indexPath)
//        let cellBottom = cellFrame.maxY - self.tableView.contentOffset.y
//        let tableViewBottom = self.tableView.superview!.bounds.maxY - self.tableView.contentInset.bottom
//        let safeAreaTop = self.tableView.superview!.safeAreaInsets.top
//
//        // Scroll either when cell bottom is below keyboard or cell top is not visible on screen
//        if cellBottom > tableViewBottom || cellFrame.minY < (safeAreaTop + self.tableView.contentOffset.y) {
//            // Scroll to top if cell is smaller than visible screen, so that it's fully visible, otherwise scroll to bottom.
//            let position: UITableView.ScrollPosition = cellFrame.height + safeAreaTop < tableViewBottom ? .top : .bottom
//            self.tableView.scrollToRow(at: indexPath, at: position, animated: false)
//        }
//        UIView.setAnimationsEnabled(true)
//    }

    // MARK: - Data Helpers

    /// Creates array of visible sections for current state data.
    /// - parameter data: New data.
    /// - parameter isEditing: Current editing table view state.
    /// - returns: Array of visible sections.
    private func sections(for data: ItemDetailState.Data, isEditing: Bool) -> [Section] {
        if isEditing {
            if data.isAttachment {
                return [.title, .type, .fields, .dates, .tags, .attachments]
            } else {
                // Each section is visible during editing, except dates section. Dates are filled automatically and the user can't change them manually.
                return [.title, .type, .creators, .fields, .dates, .abstract, .notes, .tags, .attachments]
            }
        }

        var sections: [Section] = [.title]
        // Item type is always visible
        sections.append(.type)
        if !data.creators.isEmpty {
            sections.append(.creators)
        }
        if !data.fieldIds.isEmpty {
            sections.append(.fields)
        }
        sections.append(.dates)
        if let abstract = data.abstract, !abstract.isEmpty {
            sections.append(.abstract)
        }
        if !data.notes.isEmpty {
            sections.append(.notes)
        }
        if !data.tags.isEmpty {
            sections.append(.tags)
        }
        if !data.attachments.isEmpty {
            sections.append(.attachments)
        }
        return sections
    }

    private func rows(for section: Section, state: ItemDetailState) -> [Row] {
        switch section {
        case .abstract:
            return [.abstract(value: (state.data.abstract ?? ""), collapsed: state.abstractCollapsed)]

        case .attachments:
            return state.data.attachments.enumerated().map({ idx, attachment in
                let enabled = self.delegate?.isDownloadingFromNavigationBar(for: idx) == false
                var progress: CGFloat?
                var error: Error?

                if enabled {
                    (progress, error) = self.fileDownloader?.data(for: attachment.key, libraryId: attachment.libraryId) ?? (nil, nil)
                }

                return .attachment(attachment: attachment, progress: progress, error: error, enabled: enabled)
            })

        case .creators:
            return state.data.creatorIds.compactMap({ creatorId in
                guard let creator = state.data.creators[creatorId] else { return nil }
                return .creator(creator)
            })

        case .dates:
            return [.dateAdded(state.data.dateAdded), .dateModified(state.data.dateModified)]

        case .fields:
            return state.data.fieldIds.compactMap({ fieldId in
                guard let field = state.data.fields[fieldId] else { return nil }
                return .field(field: field, multiline: (fieldId == FieldKeys.Item.extra))
            })

        case .notes:
            return state.data.notes.map({ note in
                return .note(note)
            })

        case .tags:
            return state.data.tags.map({ tag in
                return .tag(tag)
            })

        case .title:
            return [.title(state.data.title)]

        case .type:
            return [.type(state.data.localizedType)]
        }
    }

    /// Returns width of title for field cells for both editing and non-editing states.
    /// - parameter data: New data.
    /// - returns: Max field title width for editing and non-editing state.
    private func calculateTitleWidths(for data: ItemDetailState.Data) -> (CGFloat, CGFloat) {
        var maxTitle = ""
        var maxNonEmptyTitle = ""

        data.fields.values.forEach { field in
            if field.name.count > maxTitle.count {
                maxTitle = field.name
            }

            if !field.value.isEmpty && field.name.count > maxNonEmptyTitle.count {
                maxNonEmptyTitle = field.name
            }
        }

        let extraFields = [L10n.itemType, L10n.dateModified, L10n.dateAdded, L10n.abstract] + data.creators.values.map({ $0.localizedType })
        extraFields.forEach { name in
            if name.count > maxTitle.count {
                maxTitle = name
            }
            if name.count > maxNonEmptyTitle.count {
                maxNonEmptyTitle = name
            }
        }

        let maxTitleWidth = ceil(maxTitle.size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]).width)
        let maxNonemptyTitleWidth = ceil(maxNonEmptyTitle.size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]).width)
        return (maxTitleWidth, maxNonemptyTitleWidth)
    }

    // MARK: - Delegate Helpers

    /// Base count of objects in each section. "Base" means just count of actual objects in data arrays, without additional rows shown in tableView.
//    private func baseCount(in section: Section) -> Int {
//        switch section {
//        case .abstract, .title, .type:
//            return 1
//        case .dates:
//            return 2
//        case .creators:
//            return self.viewModel.state.data.creatorIds.count
//        case .fields:
//            return self.viewModel.state.data.fieldIds.count
//        case .attachments:
//            return self.viewModel.state.data.attachments.count
//        case .notes:
//            return self.viewModel.state.data.notes.count
//        case .tags:
//            return self.viewModel.state.data.tags.count
//        }
//    }
//
//    /// Count of rows for each section. This count includes all rows, including additional rows for some sections (add buttons while editing).
//    private func count(in section: Section, isEditing: Bool, isAttachment: Bool) -> Int {
//        switch section {
//        case .tags:
//            // +1 for add button
//            return self.baseCount(in: section) + (isEditing ? 1 : 0)
//        case .creators, .notes, .attachments:
//            // +1 for add button
//            return self.baseCount(in: section) + ((!isAttachment && isEditing) ? 1 : 0)
//        case .abstract, .title, .type, .dates, .fields:
//            return self.baseCount(in: section)
//        }
//    }
//
//    private func cellData(for indexPath: IndexPath, isEditing: Bool) -> (Section, String) {
//        let section = self.sections[indexPath.section]
//        let cellId: String
//
//        switch section {
//        case .title:
//            cellId = section.cellId(isEditing: isEditing, needsMultiline: false)
//        case .fields:
//            let isAttachment = self.viewModel.state.data.isAttachment
//            let fieldId = self.viewModel.state.data.fieldIds[indexPath.row]
//            cellId = section.cellId(isEditing: (!isAttachment && isEditing), needsMultiline: (fieldId == FieldKeys.Item.extra))
//        case .abstract, .type, .dates:
//            let isAttachment = self.viewModel.state.data.isAttachment
//            cellId = section.cellId(isEditing: (!isAttachment && isEditing), needsMultiline: false)
//        case .creators, .attachments, .notes, .tags:
//            if indexPath.row < self.baseCount(in: section) {
//                cellId = section.cellId(isEditing: isEditing, needsMultiline: false)
//            } else {
//                cellId = ItemDetailTableViewHandler.addCellId
//            }
//        }
//
//        return (section, cellId)
//    }

    private func createContextMenu(for attachment: Attachment) -> UIMenu? {
        guard !self.viewModel.state.data.isAttachment else { return nil }

        var actions: [UIAction] = []

        if case .file(_, _, let location, _) = attachment.type, location == .local {
            actions.append(UIAction(title: L10n.ItemDetail.deleteAttachmentFile, image: UIImage(systemName: "trash"), attributes: []) { [weak self] action in
                self?.viewModel.process(action: .deleteAttachmentFile(attachment))
            })
        }

        actions.append(UIAction(title: L10n.ItemDetail.trashAttachment, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] action in
            self?.viewModel.process(action: .trashAttachment(attachment))
        })

        return UIMenu(title: "", children: actions)
    }

    private func createContextMenu(for field: ItemDetailState.Field) -> UIMenu? {
        guard ((field.key == FieldKeys.Item.doi || field.baseField == FieldKeys.Item.doi) || (field.key == FieldKeys.Item.url || field.baseField == FieldKeys.Item.url)) else { return nil }
        return UIMenu(title: "", children: [UIAction(title: L10n.copy, handler: { _ in
            UIPasteboard.general.string = field.value
        })])
    }

    // MARK: - DataSource Helpers

    private func setup(cell: UITableViewCell, section: Section, row: Row, isFirst: Bool, isLast: Bool, isEditing: Bool) {
        let titleWidth = isEditing ? self.maxTitleWidth : self.maxNonemptyTitleWidth
        var isAdd: Bool = false

        switch row {
        case .add:
            isAdd = true

            if let cell = cell as? ItemDetailAddCell {
                switch section {
                case .creators:
                    cell.setup(with: L10n.ItemDetail.addCreator)
                case .tags:
                    cell.setup(with: L10n.ItemDetail.addTag)
                case .notes:
                    cell.setup(with: L10n.ItemDetail.addNote)
                case .attachments:
                    cell.setup(with: L10n.ItemDetail.addAttachment)
                default: break
                }
            }

        case .abstract(let value, let collapsed):
            if let cell = cell as? ItemDetailAbstractEditCell {
                cell.setup(with: value)
                cell.textObservable.subscribe(onNext: { [weak self] abstract in
                    guard isEditing else { return }
                    self?.viewModel.process(action: .setAbstract(abstract))
//                        self?.updateCellHeightsAndScroll(to: indexPath)
                }).disposed(by: cell.newDisposeBag)
            } else if let cell = cell as? ItemDetailAbstractCell {
                cell.setup(with: value, isCollapsed: collapsed)
            }

        case .attachment(let attachment, let progress, let error, let enabled):
            if let cell = cell as? ItemDetailAttachmentCell {
                cell.selectionStyle = self.canTap(attachmentType: attachment.type, isEditing: isEditing) ? .gray : .none
                cell.setup(with: attachment, progress: progress, error: error, enabled: enabled)
            }

        case .creator(let creator):
            if let cell = cell as? ItemDetailFieldCell {
                cell.setup(with: creator, titleWidth: titleWidth)
            }

        case .dateAdded(let date):
            if let cell = cell as? ItemDetailFieldCell {
                let date = Formatter.dateAndTime.string(from: date)
                cell.setup(with: date, title: L10n.dateAdded, titleWidth: titleWidth)
            }

        case .dateModified(let date):
            if let cell = cell as? ItemDetailFieldCell {
                let date = Formatter.dateAndTime.string(from: date)
                cell.setup(with: date, title: L10n.dateModified, titleWidth: titleWidth)
            }

        case .field(let field, let multiline):
            if let cell = cell as? ItemDetailFieldCell {
                cell.setup(with: field, titleWidth: titleWidth)
            } else if let cell = cell as? ItemDetailFieldEditCell {
                cell.setup(with: field, titleWidth: titleWidth)
                cell.textObservable.subscribe(onNext: { [weak self] value in
//                    self?.viewModel.process(action: .setFieldValue(id: fieldId, value: value))
                }).disposed(by: cell.newDisposeBag)
            } else if let cell = cell as? ItemDetailFieldMultilineEditCell {
                cell.setup(with: field, titleWidth: titleWidth)
                cell.textObservable.subscribe(onNext: { [weak self] value in
//                    self?.viewModel.process(action: .setFieldValue(id: fieldId, value: value))
//                    self?.updateCellHeightsAndScroll(to: indexPath)
                }).disposed(by: cell.newDisposeBag)
            }

        case .note(let note):
            if let cell = cell as? ItemDetailNoteCell {
                cell.setup(with: note)
            }

        case .tag(let tag):
            if let cell = cell as? ItemDetailTagCell {
                cell.setup(tag: tag, isEditing: isEditing)
            }

        case .title(let title):
            if let cell = cell as? ItemDetailTitleCell {
                cell.setup(with: title, isEditing: isEditing)
                cell.textObservable.subscribe(onNext: { [weak self] title in
                    guard isEditing else { return }
                    self?.viewModel.process(action: .setTitle(title))
//                    self?.updateCellHeightsAndScroll(to: indexPath)
                }).disposed(by: cell.newDisposeBag)
            }

        case .type(let type):
            if let cell = cell as? ItemDetailFieldCell {
                cell.setup(with: type, title: L10n.itemType, titleWidth: titleWidth)
            }
        }

        let (separatorInsets, layoutMargins, accessoryType) = self.cellLayoutData(for: section, isFirstRow: isFirst, isLastRow: isLast, isAddCell: isAdd, isEditing: isEditing)
        cell.separatorInset = separatorInsets
        cell.layoutMargins = layoutMargins
        cell.contentView.layoutMargins = layoutMargins
        if isEditing {
            cell.editingAccessoryType = accessoryType
        } else {
            cell.accessoryType = accessoryType
        }
    }

    private func canTap(attachmentType: Attachment.Kind, isEditing: Bool) -> Bool {
        guard !isEditing else { return false }
        switch attachmentType {
        case .file(_, _, _, let linkType) where linkType == .linkedFile:
            return false
        case .file, .url:
            return true
        }
    }

    private func cellLayoutData(for section: Section, isFirstRow: Bool, isLastRow: Bool, isAddCell: Bool, isEditing: Bool)
                                                                                        -> (separatorInsets: UIEdgeInsets, layoutMargins: UIEdgeInsets, accessoryType: UITableViewCell.AccessoryType) {
        var hasSeparator = true
        var accessoryType: UITableViewCell.AccessoryType = .none

        switch section {
        case .abstract, .title, .notes: break
        case .attachments: break
            // TODO: implement attachment metadata screen
//            if !isAddCell {
//                accessoryType = .detailButton
//            }
        case .tags, .type, .fields:
            if !isAddCell {
                hasSeparator = isEditing
            }
        case .creators:
            if !isAddCell {
                if isEditing {
                    accessoryType = .disclosureIndicator
                }
                hasSeparator = isEditing
            }
        case .dates:
            hasSeparator = isEditing && !isLastRow
        }

        let layoutMargins = ItemDetailLayout.insets(for: section, isEditing: isEditing, isFirstRow: isFirstRow, isLastRow: isLastRow)
        let leftSeparatorInset: CGFloat = hasSeparator ? self.separatorLeftInset(for: section, isEditing: isEditing, leftMargin: layoutMargins.left) :
                                                         max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let separatorInsets = UIEdgeInsets(top: 0, left: leftSeparatorInset, bottom: 0, right: 0)
        return (separatorInsets, layoutMargins, accessoryType)
    }

    private func separatorLeftInset(for section: Section, isEditing: Bool, leftMargin: CGFloat) -> CGFloat {
        switch section {
        case .notes, .attachments, .tags:
            return ItemDetailLayout.iconWidth + (isEditing ? 40 : 0) + leftMargin
        case .abstract, .creators, .dates, .fields, .title, .type:
            return 0
        }
    }

    // MARK: - Setups

    /// Sets `tableView` dataSource, delegate and registers appropriate cells and sections.
    private func setupTableView() {
//        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.keyboardDismissMode = UIDevice.current.userInterfaceIdiom == .phone ? .interactive : .none
        self.tableView.tableFooterView = UIView()
        self.tableView.separatorInsetReference = .fromAutomaticInsets
        self.tableView.layoutMargins = .zero
        self.tableView.separatorInset = .zero

        ItemDetailTableViewHandler.cellIds.forEach { cellId in
            self.tableView.register(UINib(nibName: cellId, bundle: nil), forCellReuseIdentifier: cellId)
        }
        self.tableView.register(UINib(nibName: ItemDetailTableViewHandler.sectionId, bundle: nil), forHeaderFooterViewReuseIdentifier: ItemDetailTableViewHandler.sectionId)

        self.dataSource = DiffableDataSource(tableView: self.tableView,
                                             dequeueAction: { tableView, indexPath, section, row in
                                                 return tableView.dequeueReusableCell(withIdentifier: row.cellId(isEditing: tableView.isEditing), for: indexPath)
                                             }, setupAction: { [weak self] cell, indexPath, section, row in
                                                 guard let `self` = self else { return }
                                                 let isLast = indexPath.row == (self.dataSource.tableView(self.tableView, numberOfRowsInSection: indexPath.section) - 1)
                                                 self.setup(cell: cell, section: section, row: row, isFirst: (indexPath.row == 0), isLast: isLast, isEditing: self.tableView.isEditing)
                                             })
    }

    private func setupTableView(with keyboardData: KeyboardData) {
        var insets = self.tableView.contentInset
        insets.bottom = keyboardData.endFrame.height
        self.tableView.contentInset = insets
    }

    private func setupKeyboardObserving() {
        NotificationCenter.default
                          .keyboardWillShow
                          .observe(on: MainScheduler.instance)
                          .subscribe(onNext: { [weak self] notification in
                              if let data = notification.keyboardData {
                                  self?.setupTableView(with: data)
                              }
                          })
                          .disposed(by: self.disposeBag)

        NotificationCenter.default
                          .keyboardWillHide
                          .observe(on: MainScheduler.instance)
                          .subscribe(onNext: { [weak self] notification in
                              if let data = notification.keyboardData {
                                  self?.setupTableView(with: data)
                              }
                          })
                          .disposed(by: self.disposeBag)
    }
}

//extension ItemDetailTableViewHandler: UITableViewDataSource {
//    func numberOfSections(in tableView: UITableView) -> Int {
//        return self.sections.count
//    }
//
//    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
//        return self.count(in: self.sections[section], isEditing: self.viewModel.state.isEditing, isAttachment: self.viewModel.state.data.isAttachment)
//    }
//
//    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
//        switch self.sections[section] {
//        case .notes, .attachments, .tags:
//            return ItemDetailLayout.sectionHeaderHeight + ItemDetailLayout.separatorHeight
//        default:
//            return 0
//        }
//    }
//
//    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
//        switch self.sections[section] {
//        case .notes:
//            let view = tableView.dequeueReusableHeaderFooterView(withIdentifier: ItemDetailTableViewHandler.sectionId) as? ItemDetailSectionView
//            view?.setup(with: L10n.ItemDetail.notes)
//            return view
//        case .attachments:
//            let view = tableView.dequeueReusableHeaderFooterView(withIdentifier: ItemDetailTableViewHandler.sectionId) as? ItemDetailSectionView
//            view?.setup(with: L10n.ItemDetail.attachments)
//            return view
//        case .tags:
//            let view = tableView.dequeueReusableHeaderFooterView(withIdentifier: ItemDetailTableViewHandler.sectionId) as? ItemDetailSectionView
//            view?.setup(with: L10n.ItemDetail.tags)
//            return view
//        default:
//            return nil
//        }
//    }
//
//    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
//        let isEditing = self.viewModel.state.isEditing
//        let isAttachment = self.viewModel.state.data.isAttachment
//        let section = self.sections[indexPath.section]
//        let isLastRow = indexPath.row == (self.count(in: section, isEditing: isEditing, isAttachment: isAttachment) - 1)
//        let layoutMargins = ItemDetailLayout.insets(for: section, isEditing: isEditing, isFirstRow: (indexPath.row == 0), isLastRow: isLastRow)
//        cell.layoutMargins = layoutMargins
//        cell.contentView.layoutMargins = layoutMargins
//    }
//
//    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
//        let isEditing = self.viewModel.state.isEditing
//        let isAttachment = self.viewModel.state.data.isAttachment
//        let (section, cellId) = self.cellData(for: indexPath, isEditing: isEditing)
//        let cell = tableView.dequeueReusableCell(withIdentifier: cellId, for: indexPath)
//
//        let (separatorInsets, layoutMargins, accessoryType) = self.cellLayoutData(for: section, isEditing: isEditing, isAttachment: isAttachment,
//                                                                                  isAddCell: (cell is ItemDetailAddCell), indexPath: indexPath)
//        cell.separatorInset = separatorInsets
//        cell.layoutMargins = layoutMargins
//        cell.contentView.layoutMargins = layoutMargins
//        if tableView.isEditing {
//            cell.editingAccessoryType = accessoryType
//        } else {
//            cell.accessoryType = accessoryType
//        }
//
//        switch section {
//        case .abstract:
//            if let cell = cell as? ItemDetailAbstractEditCell {
//                cell.setup(with: (self.viewModel.state.data.abstract ?? ""))
//                cell.textObservable.subscribe(onNext: { [weak self] abstract in
//                    guard isEditing else { return }
//                    self?.viewModel.process(action: .setAbstract(abstract))
//                    self?.updateCellHeightsAndScroll(to: indexPath)
//                }).disposed(by: cell.newDisposeBag)
//            } else if let cell = cell as? ItemDetailAbstractCell {
//                cell.setup(with: (self.viewModel.state.data.abstract ?? ""), isCollapsed: self.viewModel.state.abstractCollapsed)
//            }
//
//        case .title:
//            if let cell = cell as? ItemDetailTitleCell {
//                cell.setup(with: self.viewModel.state.data.title, isEditing: isEditing)
//                cell.textObservable.subscribe(onNext: { [weak self] title in
//                    guard isEditing else { return }
//                    self?.viewModel.process(action: .setTitle(title))
//                    self?.updateCellHeightsAndScroll(to: indexPath)
//                }).disposed(by: cell.newDisposeBag)
//            }
//
//        case .attachments:
//            if let cell = cell as? ItemDetailAttachmentCell {
//                self.setup(attachmentCell: cell, at: indexPath.row)
//            } else if let cell = cell as? ItemDetailAddCell {
//                cell.setup(with: L10n.ItemDetail.addAttachment)
//            }
//
//        case .notes:
//            if let cell = cell as? ItemDetailNoteCell {
//                cell.setup(with: self.viewModel.state.data.notes[indexPath.row])
//            } else if let cell = cell as? ItemDetailAddCell {
//                cell.setup(with: L10n.ItemDetail.addNote)
//            }
//
//        case .tags:
//            if let cell = cell as? ItemDetailTagCell {
//                cell.setup(tag: self.viewModel.state.data.tags[indexPath.row], isEditing: isEditing)
//            } else if let cell = cell as? ItemDetailAddCell {
//                cell.setup(with: L10n.ItemDetail.addTag)
//            }
//
//        case .type:
//            if let cell = cell as? ItemDetailFieldCell {
//                cell.setup(with: self.viewModel.state.data.localizedType, title: L10n.itemType, titleWidth: self.titleWidth)
//            }
//
//        case .fields:
//            let fieldId = self.viewModel.state.data.fieldIds[indexPath.row]
//            if let field = self.viewModel.state.data.fields[fieldId] {
//                if let cell = cell as? ItemDetailFieldCell {
//                    cell.setup(with: field, titleWidth: self.titleWidth)
//                } else if let cell = cell as? ItemDetailFieldEditCell {
//                    cell.setup(with: field, titleWidth: self.titleWidth)
//                    cell.textObservable.subscribe(onNext: { [weak self] value in
//                        self?.viewModel.process(action: .setFieldValue(id: fieldId, value: value))
//                    }).disposed(by: cell.newDisposeBag)
//                } else if let cell = cell as? ItemDetailFieldMultilineEditCell {
//                    cell.setup(with: field, titleWidth: self.titleWidth)
//                    cell.textObservable.subscribe(onNext: { [weak self] value in
//                        self?.viewModel.process(action: .setFieldValue(id: fieldId, value: value))
//                        self?.updateCellHeightsAndScroll(to: indexPath)
//                    }).disposed(by: cell.newDisposeBag)
//                }
//            }
//
//        case .creators:
//            if let cell = cell as? ItemDetailFieldCell {
//                let creatorId = self.viewModel.state.data.creatorIds[indexPath.row]
//                if let creator = self.viewModel.state.data.creators[creatorId] {
//                    cell.setup(with: creator, titleWidth: self.titleWidth)
//                }
//            } else if let cell = cell as? ItemDetailAddCell {
//                cell.setup(with: L10n.ItemDetail.addCreator)
//            }
//
//        case .dates:
//            if let cell = cell as? ItemDetailFieldCell {
//                switch indexPath.row {
//                case 0:
//                    let date = Formatter.dateAndTime.string(from: self.viewModel.state.data.dateAdded)
//                    cell.setup(with: date, title: L10n.dateAdded, titleWidth: self.titleWidth)
//                case 1:
//                    let date = Formatter.dateAndTime.string(from: self.viewModel.state.data.dateModified)
//                    cell.setup(with: date, title: L10n.dateModified, titleWidth: self.titleWidth)
//                default: break
//                }
//            }
//        }
//
//        return cell
//    }
//}

extension ItemDetailTableViewHandler: UITableViewDelegate {
//    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
//        let section = self.sections[indexPath.section]
//        switch section {
//        case .creators:
//            return indexPath.row < self.baseCount(in: section)
//        default:
//            return false
//        }
//    }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        let section = self.sections[proposedDestinationIndexPath.section]
        if section != .creators { return sourceIndexPath }
//        if proposedDestinationIndexPath.row == self.baseCount(in: section) { return sourceIndexPath }
        return proposedDestinationIndexPath
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let sourceSection = self.sections[sourceIndexPath.section]
        let destinationSection = self.sections[destinationIndexPath.section]
        guard sourceSection == .creators && destinationSection == .creators else { return }
        self.viewModel.process(action: .moveCreators(from: IndexSet([sourceIndexPath.row]), to: destinationIndexPath.row))
    }

//    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
//        let section = self.sections[indexPath.section]
//        let rows = self.baseCount(in: section)
//
//        switch section {
//        case .attachments:
//            return !self.viewModel.state.data.isAttachment && indexPath.row < rows
//        case .creators, .notes, .tags:
//            return self.viewModel.state.isEditing && indexPath.row < rows
//        case .title, .abstract, .fields, .type, .dates:
//            return false
//        }
//    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard self.viewModel.state.isEditing && editingStyle == .delete else { return }

        switch self.sections[indexPath.section] {
        case .creators:
            self.viewModel.process(action: .deleteCreators([indexPath.row]))
        case .tags:
            self.viewModel.process(action: .deleteTags([indexPath.row]))
        case .attachments:
            self.viewModel.process(action: .deleteAttachments([indexPath.row]))
        case .notes:
            self.viewModel.process(action: .deleteNotes([indexPath.row]))
        case .title, .abstract, .fields, .type, .dates: break
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !self.viewModel.state.isEditing else { return nil }

        let section = self.sections[indexPath.section]
        switch section {
        case .attachments:
            let attachment = self.viewModel.state.data.attachments[indexPath.row]
            let trashAction = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completed in
                self?.observer.on(.next(.trashAttachment(attachment)))
                completed(true)
            }
            trashAction.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [trashAction])
        case .title, .abstract, .fields, .type, .dates, .creators, .notes, .tags:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !self.viewModel.state.isEditing else { return nil }

        switch self.sections[indexPath.section] {
        case .attachments:
            guard indexPath.row < self.viewModel.state.data.attachments.count else { return nil }
            let attachment = self.viewModel.state.data.attachments[indexPath.row]
            return self.createContextMenu(for: attachment).flatMap({ menu in UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { _ in menu }) })

        case .fields:
            guard indexPath.row < self.viewModel.state.data.fields.count else { return nil }
            let fieldId = self.viewModel.state.data.fieldIds[indexPath.row]
            let field = self.viewModel.state.data.fields[fieldId]
            return field.flatMap({ self.createContextMenu(for: $0) }).flatMap({ menu in UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { _ in menu }) })

        case .abstract, .creators, .dates, .notes, .tags, .title, .type:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch self.sections[indexPath.section] {
        case .attachments:
            if self.viewModel.state.isEditing {
                if indexPath.row == self.viewModel.state.data.attachments.count {
                    self.observer.on(.next(.openFilePicker))
                }
            } else {
                let attachment = self.viewModel.state.data.attachments[indexPath.row]
                if let error = self.fileDownloader?.data(for: attachment.key, libraryId: attachment.libraryId).error {
                    self.observer.on(.next(.showAttachmentError(error, indexPath.row)))
                } else {
                    self.viewModel.process(action: .openAttachment(indexPath.row))
                }
            }
        case .notes:
            if self.viewModel.state.isEditing && indexPath.row == self.viewModel.state.data.notes.count {
                self.observer.on(.next(.openNoteEditor(nil)))
            } else {
                let note = self.viewModel.state.data.notes[indexPath.row]
                self.observer.on(.next(.openNoteEditor(note)))
            }
        case .tags:
            if self.viewModel.state.isEditing && indexPath.row == self.viewModel.state.data.tags.count {
                self.observer.on(.next(.openTagPicker))
            }
        case .creators:
            guard self.viewModel.state.isEditing else { return }

            if indexPath.row == self.viewModel.state.data.creators.count {
                self.observer.on(.next(.openCreatorCreation))
            } else {
                let id = self.viewModel.state.data.creatorIds[indexPath.row]
                if let creator = self.viewModel.state.data.creators[id] {
                    self.observer.on(.next(.openCreatorEditor(creator)))
                }
            }
        case .type:
            if self.viewModel.state.isEditing && !self.viewModel.state.data.isAttachment{
                self.observer.on(.next(.openTypePicker))
            }
        case .fields:
            let fieldId = self.viewModel.state.data.fieldIds[indexPath.row]
            if let field = self.viewModel.state.data.fields[fieldId] {
                guard field.isTappable else { return }
                switch field.key {
                case FieldKeys.Item.Attachment.url:
                    self.observer.on(.next(.openUrl(field.value)))
                case FieldKeys.Item.doi:
                    self.observer.on(.next(.openDoi(field.value)))
                default: break
                }
            }
        case .abstract:
            if !self.viewModel.state.isEditing {
                self.viewModel.process(action: .toggleAbstractDetailCollapsed)
            }
        case .title, .dates: break
        }
    }
}
