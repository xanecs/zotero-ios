//
//  VersionsRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 04/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct VersionsRequest<Key: Decodable&Hashable>: ApiResponseRequest {
    typealias Response = [Key: Int]

    let groupType: SyncGroupType
    let objectType: SyncObjectType
    let version: Int?

    var path: String {
        return "\(self.groupType.apiPath)/\(self.objectType.apiPath)"
    }

    var httpMethod: ApiHttpMethod {
        return .get
    }

    var encoding: ApiParameterEncoding {
        return .url
    }

    var parameters: [String : Any]? {
        var parameters: [String: Any] = ["format": "versions"]
        if let version = self.version {
            parameters["since"] = version
        }
        return parameters
    }
}