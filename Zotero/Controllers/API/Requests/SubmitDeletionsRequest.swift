//
//  SubmitDeletionsRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 06/05/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct SubmitDeletionsRequest: ApiRequest {
    let libraryType: SyncController.Library
    let objectType: SyncController.Object
    let keys: [String]
    let version: Int

    var path: String {
        return "\(self.libraryType.apiPath)/\(self.objectType.apiPath)"
    }

    var httpMethod: ApiHttpMethod {
        return .delete
    }

    var encoding: ApiParameterEncoding {
        return .url
    }

    var parameters: [String : Any]? {
        let joinedKeys = self.keys.joined(separator: ",")
        switch self.objectType {
        case .group:
            return nil
        case .collection:
            return ["collectionKey": joinedKeys]
        case .item, .trash:
            return ["itemKey": joinedKeys]
        case .search:
            return ["searchKey": joinedKeys]
        case .tag:
            return nil
        }
    }

    var headers: [String : String]? {
        return ["If-Unmodified-Since-Version": self.version.description]
    }
}