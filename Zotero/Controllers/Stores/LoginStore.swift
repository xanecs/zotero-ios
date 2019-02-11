//
//  LoginStore.swift
//  Zotero
//
//  Created by Michal Rentka on 03/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RxSwift

enum LoginError: Error {
    case invalidUsername
    case invalidPassword

    var localizedDescription: String {
        switch self {
        case .invalidPassword:
            return "Invalid password"
        case .invalidUsername:
            return "Invalid username"
        }
    }
}

enum LoginAction {
    case login(username: String, password: String)
    case hideError
}

enum LoginState {
    case error(Error)
    case loading
    case input
}

extension LoginState: Equatable {
    static func == (lhs: LoginState, rhs: LoginState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.input, .input):
            return true
        case (.error(let lError), .error(let rError)):
            return (lError as NSError) == (rError as NSError)
        default:
            return false
        }
    }
}

class LoginStore: Store {
    typealias Action = LoginAction
    typealias State = LoginState

    private let apiClient: ApiClient
    private let secureStorage: SecureStorage
    private let dbStorage: DbStorage
    private let disposeBag: DisposeBag

    var updater: StoreStateUpdater<LoginState>

    init(apiClient: ApiClient, secureStorage: SecureStorage, dbStorage: DbStorage) {
        self.apiClient = apiClient
        self.secureStorage = secureStorage
        self.dbStorage = dbStorage
        self.disposeBag = DisposeBag()
        self.updater = StoreStateUpdater(initialState: .input)
    }

    func handle(action: LoginAction) {
        switch action {
        case .hideError:
            self.updater.updateState { newState in
                newState = .input
            }
        case .login(let username, let password):
            self.handleLogin(username: username, password: password)
        }
    }

    private func isValid(username: String, password: String) -> Bool {
        if username.isEmpty {
            self.updater.updateState { newState in
                newState = .error(LoginError.invalidUsername)
            }
            return false
        }

        if password.isEmpty {
            self.updater.updateState { newState in
                newState = .error(LoginError.invalidPassword)
            }
            return false
        }

        return true
    }

    private func handleLogin(username: String, password: String) {
        guard self.isValid(username: username, password: password) else { return }

        self.updater.updateState { newState in
            newState = .loading
        }

        let request = LoginRequest(username: username, password: password)
        self.apiClient.send(request: request)
                      .observeOn(ConcurrentDispatchQueueScheduler(qos: .userInitiated))
                      .flatMap { response -> Single<(Int, String)> in
                          do {
                              let request = StoreUserDbRequest(loginResponse: response.0)
                              try self.dbStorage.createCoordinator().perform(request: request)
                              return Single.just((response.0.userId, response.0.key))
                          } catch let error {
                              return Single.error(error)
                          }
                      }
                      .subscribe(onSuccess: { data in
                          self.secureStorage.apiToken = data.1
                          self.apiClient.set(authToken: data.1)
                          NotificationCenter.default.post(name: .sessionChanged, object: data.0)
                      }, onError: { error in
                          self.updater.updateState(action: { newState in
                              newState = .error(error)
                          })
                      })
                      .disposed(by: self.disposeBag)
    }
}