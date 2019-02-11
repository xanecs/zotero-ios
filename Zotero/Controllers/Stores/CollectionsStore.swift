//
//  CollectionsStore.swift
//  Zotero
//
//  Created by Michal Rentka on 10/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift
import RxSwift

struct CollectionCellData {
    let identifier: String
    let name: String
    let hasChildren: Bool

    init(object: RCollection) {
        self.identifier = object.identifier
        self.name = object.name
        self.hasChildren = object.children.count > 0
    }
}

enum CollectionsAction {
    case load
}

enum CollectionsStoreError: Equatable {
    case cantLoadData
}

struct CollectionsState {
    let libraryId: Int
    let parentId: String?
    let title: String

    fileprivate(set) var cellData: [CollectionCellData]
    fileprivate(set) var error: CollectionsStoreError?

    // To avoid comparing the whole cellData arrays in == function, we just have a version which we increment
    // on each change and we'll compare just versions of cellData.
    fileprivate var version: Int
    fileprivate var collections: Results<RCollection>?
    fileprivate var collectionToken: NotificationToken?

    init(libraryId: Int, parentId: String?, title: String) {
        self.libraryId = libraryId
        self.parentId = parentId
        self.title = title
        self.cellData = []
        self.version = 0
    }
}

extension CollectionsState: Equatable {
    static func == (lhs: CollectionsState, rhs: CollectionsState) -> Bool {
        return lhs.error == rhs.error && lhs.version == rhs.version
    }
}

class CollectionsStore: Store {
    typealias Action = CollectionsAction
    typealias State = CollectionsState

    let dbStorage: DbStorage

    var updater: StoreStateUpdater<CollectionsState>

    init(initialState: CollectionsState, dbStorage: DbStorage) {
        self.dbStorage = dbStorage
        self.updater = StoreStateUpdater(initialState: initialState)
    }

    func handle(action: CollectionsAction) {
        switch action {
        case .load:
            self.loadData()
        }
    }

    private func reload(collections: Results<RCollection>) -> [CollectionCellData] {
        return collections.map(CollectionCellData.init)
    }

    private func loadData() {
        do {
            let request = ReadCollectionsDbRequest(libraryId: self.state.value.libraryId,
                                                   parentId: self.state.value.parentId)
            let collections = try self.dbStorage.createCoordinator().perform(request: request)
            let collectionToken = collections.observe({ [weak self] changes in
                guard let `self` = self else { return }
                switch changes {
                case .update(let objects, _, _, _):
                    let cellData = self.reload(collections: objects)
                    self.updater.updateState(action: { newState in
                        newState.cellData = cellData
                        newState.version += 1
                    })
                case .initial: break
                case .error(let error):
                    // TODO: - Log error?
                    self.updater.updateState { newState in
                        newState.error = .cantLoadData
                    }
                }
            })

            let cellData = self.reload(collections: collections)
            self.updater.updateState { newState in
                newState.collections = collections
                newState.version += 1
                newState.cellData = cellData
                newState.collectionToken = collectionToken
            }
        } catch let error {
            // TODO: - Log error?
            self.updater.updateState { newState in
                newState.error = .cantLoadData
            }
        }
    }
}
