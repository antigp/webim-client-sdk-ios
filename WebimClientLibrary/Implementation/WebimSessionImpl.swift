//
//  WebimSessionImpl.swift
//  WebimClientLibrary
//
//  Created by Nikita Lazarev-Zubov on 02.08.17.
//  Copyright © 2017 Webim. All rights reserved.
//

import Foundation
import UIKit


// MARK: - Constants

fileprivate enum UserDefaultsName: String {
    case GUID = "ru.webim.WebimClientSDKiOS.guid"
    case MAIN = "ru.webim.WebimClientSDKiOS.visitor."
}

fileprivate enum UserDefaultsMainPrefix: String {
    case AUTHORIZATION_TOKEN = "auth_token"
    case DEVICE_TOKEN = "push_token"
    case HISTORY_ENDED = "history_ended"
    case HISTORY_DB_NAME = "history_db_name"
    case HISTORY_MAJOR_VERSION = "history_major_version"
    case HISTORY_REVISION = "history_revision"
    case PAGE_ID = "page_id"
    case SESSION_ID = "session_id"
    case VISITOR = "visitor"
    case VISITOR_EXT = "visitor_ext"
}

fileprivate enum UserDefaultsGUIDPrefix: String {
    case UUID = "guid"
}


// MARK: -
final class WebimSessionImpl {
    
    // MARK: - Constants
    private enum Settings: String {
        case PLATFORM = "ios"
        case DEFAULT_PAGE_TITLE = "iOS Client"
    }
    
    
    // MARK: - Properties
    var accessChecker: AccessChecker
    var client: WebimClient
    var clientStarted: Bool?
    var messageStream: MessageStreamImpl
    fileprivate var historyPoller: HistoryPoller
    fileprivate var sessionDestroyer: SessionDestroyer
    
    
    // MARK: - Initialization
    fileprivate init(withAccessChecker accessChecker: AccessChecker,
                     sessionDestroyer: SessionDestroyer,
                     webimClient client: WebimClient,
                     historyPoller: HistoryPoller,
                     messageStream: MessageStreamImpl) {
        self.accessChecker = accessChecker
        self.sessionDestroyer = sessionDestroyer
        self.client = client
        self.historyPoller = historyPoller
        self.messageStream = messageStream
    }
    
    
    // MARK: - Methods
    
    static func newInstanceWith(accountName: String,
                                location: String,
                                appVersion: String?,
                                visitorFields: ProvidedVisitorFields?,
                                pageTitle: String?,
                                fatalErrorHandler: FatalErrorHandler?,
                                arePushNotificationsEnabled: Bool,
                                deviceToken: String?,
                                isLocalHistoryStoragingEnabled: Bool?,
                                isVisitorDataClearingEnabled: Bool?) throws -> WebimSessionImpl? {
        let queue = DispatchQueue.global(qos: .userInteractive)
        
        let userDefaultsKey = UserDefaultsName.MAIN.rawValue + ((visitorFields == nil) ? "anonymous" : visitorFields!.getID())
        let userDefaults = UserDefaults.standard.dictionary(forKey: userDefaultsKey)
        
        if isVisitorDataClearingEnabled == true {
            clearVisitorDataFor(userDefaultsKey: userDefaultsKey)
        }
        
        checkSavedSessionFor(userDefaultsKey: userDefaultsKey,
                             newProvidedVisitorFields: visitorFields)
        
        let sessionDestroyer = SessionDestroyer()
        
        let visitorJSON = userDefaults?[UserDefaultsMainPrefix.VISITOR.rawValue] ?? nil
        
        let visitorFieldsJSON = (visitorFields == nil) ? nil : visitorFields?.getJSONString()
        
        let serverURLString = InternalUtils.createServerURLStringBy(accountName: accountName)!
        
        let currentChatMessageMapper: MessageFactoriesMapper = CurrentChatMapper(withServerURLString: serverURLString)
        
        let sessionID = userDefaults?[UserDefaultsMainPrefix.SESSION_ID.rawValue] ?? nil
        
        let pageID = userDefaults?[UserDefaultsMainPrefix.PAGE_ID.rawValue] ?? nil
        let authorizationToken = userDefaults?[UserDefaultsMainPrefix.AUTHORIZATION_TOKEN.rawValue] ?? nil
        let authorizationData = (pageID == nil) ? nil : AuthorizationData(pageID: pageID as! String,
                                                                          authorizationToken: authorizationToken as! String?)
        
        let deltaCallback = DeltaCallback(withCurrentChatMessageMapper: currentChatMessageMapper)

        var webimClient: WebimClient? = nil
        webimClient = try WebimClientBuilder()
            .set(baseURL: serverURLString)
            .set(location: location)
            .set(appVersion: appVersion)
            .set(visitorFieldsJSONString: visitorFieldsJSON)
            .set(deltaCallback: deltaCallback)
            .set(sessionParametersListener: SessionParametersListenerImpl(withUserDefaultsKey: userDefaultsKey))
            .set(internalErrorListener: DestroyIfNotErrorListener(sessionDestroyer: sessionDestroyer,
                                                                  internalErrorListener: ErrorHandlerToInternalAdapter(fatalErrorHandler: fatalErrorHandler)))
            .set(visitorJSONString: visitorJSON as! String?)
            .set(sessionID: sessionID as! String?)
            .set(authorizationData: authorizationData)
            .set(completionHandlerExecutor: ExecIfNotDestroyedHandlerExecutor(withSessionDestroyer: sessionDestroyer,
                                                                              queue: queue))
            .set(platform: Settings.PLATFORM.rawValue)
            .set(title: (pageTitle != nil) ? pageTitle! : Settings.DEFAULT_PAGE_TITLE.rawValue)
            .set(deviceToken: deviceToken)
            .set(deviceID: getDeviceID())
            .build() as WebimClient
        
        var historyStorage: HistoryStorage
        var historyMetaInformationStoragePreferences: HistoryMetaInformationStorage
        if isLocalHistoryStoragingEnabled == true {
            var dbName = userDefaults?[UserDefaultsMainPrefix.HISTORY_DB_NAME.rawValue] as? String
            
            if dbName == nil {
                dbName = "webim_" + ClientSideID.generateClientSideID() + ".db"
                if var userDefaults = UserDefaults.standard.dictionary(forKey: userDefaultsKey) {
                    userDefaults[UserDefaultsMainPrefix.HISTORY_DB_NAME.rawValue] = dbName
                    UserDefaults.standard.set(userDefaults,
                                              forKey: userDefaultsKey)
                } else {
                    UserDefaults.standard.setValue([UserDefaultsMainPrefix.HISTORY_DB_NAME.rawValue : dbName],
                                                   forKey: userDefaultsKey)
                }
            }
            
            historyMetaInformationStoragePreferences = HistoryMetaInformationStoragePreferences(withUserDefaultsKey: userDefaultsKey)
            
            historyStorage = SQLiteHistoryStorage(withName: dbName!,
                                                  serverURL: serverURLString,
                                                  reachedHistoryEnd: historyMetaInformationStoragePreferences.isHistoryEnded(),
                                                  queue: queue)
            
            let historyMajorVersion = historyStorage.getMajorVersion()
            if (userDefaults?[UserDefaultsMainPrefix.HISTORY_MAJOR_VERSION.rawValue] as? Int) != historyMajorVersion {
                if var userDefaults = UserDefaults.standard.dictionary(forKey: userDefaultsKey) {
                    userDefaults.removeValue(forKey: UserDefaultsMainPrefix.HISTORY_REVISION.rawValue)
                    userDefaults.removeValue(forKey: UserDefaultsMainPrefix.HISTORY_ENDED.rawValue)
                    userDefaults.removeValue(forKey: UserDefaultsMainPrefix.HISTORY_MAJOR_VERSION.rawValue)
                    UserDefaults.standard.setValue(userDefaults,
                                                   forKey: userDefaultsKey)
                }
            }
        } else {
            historyStorage = MemoryHistoryStorage()
            historyMetaInformationStoragePreferences = MemoryHistoryMetaInformationStorage()
        }
        
        let accessChecker = AccessChecker(with: Thread.current,
                                          sessionDestroyer: sessionDestroyer)
        
        let webimActions = webimClient!.getActions()
        let historyMessageMapper: MessageFactoriesMapper = HistoryMapper(withServerURLString: serverURLString)
        let messageHolder = MessageHolder(withAccessChecker: accessChecker,
                                          remoteHistoryProvider: RemoteHistoryProvider(withWebimActions: webimActions!,
                                                                                       historyMessageMapper: historyMessageMapper,
                                                                                       historyMetaInformation: historyMetaInformationStoragePreferences),
                                          historyStorage: historyStorage,
                                          reachedEndOfRemoteHistory: historyMetaInformationStoragePreferences.isHistoryEnded())
        let messageStream = MessageStreamImpl(withCurrentChatMessageFactoriesMapper: currentChatMessageMapper,
                                              sendingMessageFactory: SendingFactory(withServerURLString: serverURLString),
                                              operatorFactory: OperatorFactory(withServerURLString: serverURLString),
                                              accessChecker: accessChecker,
                                              webimActions: webimActions!,
                                              messageHolder: messageHolder,
                                              messageComposingHandler: MessageComposingHandler(withWebimActions: webimActions!,
                                                                                               queue: queue),
                                              locationSettingsHolder: LocationSettingsHolder(withUserDefaults: userDefaultsKey))
        
        deltaCallback.set(messageStream: messageStream,
                          messageHolder: messageHolder)
        
        let historyPoller = try HistoryPoller(withSessionDestroyer: sessionDestroyer,
                                              queue: queue,
                                              historyMessageMapper: historyMessageMapper,
                                              webimActions: webimActions!,
                                              messageHolder: messageHolder,
                                              historyMetaInformationStorage: historyMetaInformationStoragePreferences)
        
        sessionDestroyer.add(action: { () -> Void in
            webimClient?.stop()
        })
        sessionDestroyer.add(action: { () -> Void in
            historyPoller.pause()
        })
        
        return WebimSessionImpl(withAccessChecker: accessChecker,
                                sessionDestroyer: sessionDestroyer,
                                webimClient: webimClient!,
                                historyPoller: historyPoller,
                                messageStream: messageStream)
    }
    
    // Deletes local message history SQLite DB file.
    private static func clearVisitorDataFor(userDefaultsKey: String) {
        let dbName = UserDefaults.standard.dictionary(forKey: userDefaultsKey)?[UserDefaultsMainPrefix.HISTORY_DB_NAME.rawValue] ?? nil
        if dbName != nil {
            let dbFileName = dbName as! String
            let dbFileURL = URL(fileURLWithPath: dbFileName)
            let fileManager = FileManager.default
            
            do {
                try fileManager.removeItem(at: dbFileURL)
            } catch {
                print("Error deleting DB file at \(dbFileURL) or file doesn't exist.")
            }
        }
    }
    
    private static func checkSavedSessionFor(userDefaultsKey: String,
                                             newProvidedVisitorFields: ProvidedVisitorFields?) {
        let newVisitorFieldsJSONString = (newProvidedVisitorFields == nil) ? nil : newProvidedVisitorFields?.getJSONString()
        let previousVisitorFieldsJSONString = UserDefaults.standard.dictionary(forKey: userDefaultsKey)?[UserDefaultsMainPrefix.VISITOR_EXT.rawValue] as? String
        
        let previousProvidedVisitorFields: ProvidedVisitorFields?
        if previousVisitorFieldsJSONString != nil {
            previousProvidedVisitorFields = ProvidedVisitorFields(withJSONString: previousVisitorFieldsJSONString!)
        } else {
            previousProvidedVisitorFields = nil
        }
        
        if (newProvidedVisitorFields == nil)
            || (previousProvidedVisitorFields?.getID() != newProvidedVisitorFields?.getID()) {
            clearVisitorDataFor(userDefaultsKey: userDefaultsKey)
        }
        
        if newVisitorFieldsJSONString != previousVisitorFieldsJSONString {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }
    }
    
    private static func getDeviceID() -> String {
        let userDefaults = UserDefaults.standard.dictionary(forKey: UserDefaultsName.GUID.rawValue)
        var uuidString = userDefaults?[UserDefaultsGUIDPrefix.UUID.rawValue] ?? nil
        
        if uuidString == nil {
            uuidString = UIDevice.current.identifierForVendor!.uuidString
            if var userDefaults = UserDefaults.standard.dictionary(forKey: UserDefaultsName.GUID.rawValue) {
                userDefaults[UserDefaultsGUIDPrefix.UUID.rawValue] = uuidString
                UserDefaults.standard.set(userDefaults,
                                          forKey: UserDefaultsName.GUID.rawValue)
            } else {
                UserDefaults.standard.setValue([UserDefaultsGUIDPrefix.UUID.rawValue : uuidString],
                                               forKey: UserDefaultsName.GUID.rawValue)
            }
        }
        
        return uuidString as! String
    }   
    
}

// MARK: - WebimSession
extension WebimSessionImpl: WebimSession {
    
    func resume() throws {
        try checkAccess()
        
        if clientStarted != true {
            client.start()
            clientStarted = true
        }
        
        client.resume()
        try historyPoller.resume()
    }
    
    func pause() throws {
        if sessionDestroyer.isDestroyed() {
            return
        }
        
        try checkAccess()
        
        client.pause()
        historyPoller.pause()
    }
    
    func destroy() throws {
        if sessionDestroyer.isDestroyed() {
            return
        }
        
        try checkAccess()
        
        sessionDestroyer.destroy()
    }
    
    func getStream() -> MessageStream {
        return messageStream
    }
    
    
    // MARK: Private methods
    private func checkAccess() throws {
        try accessChecker.checkAccess()
    }
    
}


// MARK: - Private classes

// MARK: -
final private class HistoryPoller {
    
    // MARK: - Constants
    private enum TimeInterval: Int64 {
        case HISTORY_POLL = 60000 // ms
    }
    
    
    // MARK: - Properties
    private let historyMessageMapper: MessageFactoriesMapper
    private let historyMetaInformationStorage: HistoryMetaInformationStorage
    private let queue: DispatchQueue
    private let messageHolder: MessageHolder
    private let sessionDestroyer: SessionDestroyer
    private let webimActions: WebimActions
    private var dispatchWorkItem: DispatchWorkItem?
    private var historySinceCompletionHandler: ((_ messageList: [MessageImpl], _ deleted: Set<String>, _ hasMore: Bool, _ isInitial: Bool, _ revision: String?) throws -> ())?
    private var lastPollingTime = -TimeInterval.HISTORY_POLL.rawValue
    private var lastRevision: String?
    private var running: Bool?
    
    
    // MARK: - Initialization
    init(withSessionDestroyer sessionDestroyer: SessionDestroyer,
         queue: DispatchQueue,
         historyMessageMapper: MessageFactoriesMapper,
         webimActions: WebimActions,
         messageHolder: MessageHolder,
         historyMetaInformationStorage: HistoryMetaInformationStorage) throws {
        self.sessionDestroyer = sessionDestroyer
        self.queue = queue
        self.historyMessageMapper = historyMessageMapper
        self.webimActions = webimActions
        self.messageHolder = messageHolder
        self.historyMetaInformationStorage = historyMetaInformationStorage
    }
    
    
    // MARK: - Methods
    
    func pause() {
        if dispatchWorkItem != nil {
            dispatchWorkItem!.cancel()
        }
        
        dispatchWorkItem = nil
        running = false
    }
    
    func resume() throws {
        pause()
        
        running = true
        
        self.historySinceCompletionHandler = try createHistorySinceCompletionHandler()
        
        let uptime = Int64(ProcessInfo.processInfo.systemUptime) * 1000
        if (uptime - lastPollingTime) > TimeInterval.HISTORY_POLL.rawValue {
            requestHistory(since: lastRevision,
                           completion: historySinceCompletionHandler!)
        } else {
            // Setting next history polling in TimeInterval.HISTORY_POLL after lastPollingTime.
            
            let currentDispatchTime = DispatchTime.now()
            let dispatchTime = DispatchTime(uptimeNanoseconds: (UInt64((lastPollingTime * 1000) + (TimeInterval.HISTORY_POLL.rawValue * 1000)) - currentDispatchTime.uptimeNanoseconds))
            
            dispatchWorkItem = DispatchWorkItem() {
                self.requestHistory(since: self.lastRevision,
                                    completion: self.historySinceCompletionHandler!)
            }
            
            queue.asyncAfter(deadline: dispatchTime,
                             execute: dispatchWorkItem!)
        }
    }
    
    
    // MARK: Private methods
    
    private func createHistorySinceCompletionHandler() throws -> (_ messageList: [MessageImpl], _ deleted: Set<String>, _ hasMore: Bool, _ isInitial: Bool, _ revision: String?) throws -> () {
        return { (messageList: [MessageImpl], deleted: Set<String>, hasMore: Bool, isInitial: Bool, revision: String?) throws in
            if self.sessionDestroyer.isDestroyed() {
                return
            }
            
            self.lastPollingTime = Int64(ProcessInfo.processInfo.systemUptime) * 1000
            
            self.lastRevision = revision
            
            if isInitial
                && !hasMore {
                self.messageHolder.set(reachedEndOfLocalHistory: true)
                self.historyMetaInformationStorage.set(historyEnded: true)
            }
            
            try self.messageHolder.receiveHistoryUpdateWith(messages: messageList,
                                                            deleted: deleted,
                                                            completion: {
                                                                // Revision is saved after history was saved only.
                                                                // I.e. if history will not be saved, then revision will not be overwritten. History will be re-requested.
                                                                self.historyMetaInformationStorage.set(revision: revision)
            })
            
            if self.running != true {
                if !isInitial
                    && hasMore {
                    self.lastPollingTime = -TimeInterval.HISTORY_POLL.rawValue
                }
                
                return
            }
            
            if !isInitial
                && hasMore {
                try self.requestHistory(since: revision,
                                        completion: self.createHistorySinceCompletionHandler())
            } else {
                self.dispatchWorkItem = DispatchWorkItem() {
                    do {
                        try self.requestHistory(since: revision,
                                                completion: self.createHistorySinceCompletionHandler())
                    } catch {
                        print("Requesting history failed.")
                    }
                }
                let interval = Int(TimeInterval.HISTORY_POLL.rawValue)
                self.queue.asyncAfter(deadline: (.now() + .milliseconds(interval)),
                                      execute: self.dispatchWorkItem!)
            }
        }
    }
    
    private func requestHistory(since: String?,
                                completion: @escaping (_ messageList: [MessageImpl], _ deleted: Set<String>, _ hasMore: Bool, _ isInitial: Bool, _ revision: String?) throws -> ()) {
        webimActions.requestHistory(since: since) { data in
            if data == nil {
                try completion([MessageImpl](), Set<String>(), false, (since == nil), since)
            } else {
                let json = try? JSONSerialization.jsonObject(with: data!,
                                                             options: [])
                if let historySinceResponseDictionary = json as? [String: Any?] {
                    let historySinceResponse = HistorySinceResponse(withJSONDictionary: historySinceResponseDictionary)
                    
                    var deletes = Set<String>()
                    var messageChanges = [MessageItem]()
                    
                    if let messages = historySinceResponse.getData()?.getMessages() {
                        for message in messages {
                            if message.isDeleted() {
                                if let id = message.getID() {
                                    deletes.insert(id)
                                }
                            } else {
                                messageChanges.append(message)
                            }
                        }
                    }
                    
                    try completion(self.historyMessageMapper.mapAll(messages: messageChanges), deletes, (historySinceResponse.getData()?.isHasMore() == true), (since == nil), historySinceResponse.getData()?.getRevision())
                }
            }
        }
    }
    
}

// MARK: -
final private class SessionParametersListenerImpl: SessionParametersListener {
    
    // MARL: - Constants
    private enum VisitorFieldsJSONField: String {
        case ID = "id"
    }
    
    // MARK: - Properties
    private let userDefaultsKey: String
    private var onVisitorIDChangeListener: (() -> ())?
    
    // MARK: - Initialization
    init(withUserDefaultsKey userDefaultsKey: String) {
        self.userDefaultsKey = userDefaultsKey
    }
    
    // MARK: - Methods
    // MARK: SessionParametersListener methods
    func onSessionParametersChanged(visitorFieldsJSONString: String,
                                    sessionID: String,
                                    authorizationData: AuthorizationData) {
        // FIXME: Refactor this hell of optionals.
        if var userDefaults = UserDefaults.standard.dictionary(forKey: userDefaultsKey) {
            if let previousVisitorFieldsJSONString = userDefaults[UserDefaultsMainPrefix.VISITOR.rawValue] as? String {
                if (onVisitorIDChangeListener != nil)
                    && (previousVisitorFieldsJSONString != visitorFieldsJSONString) {
                    if let previousVisitorFieldsJSONData = previousVisitorFieldsJSONString.data(using: .utf8),
                        let visitorFieldsJSONData = visitorFieldsJSONString.data(using: .utf8) {
                        if let previousVisitorFieldsDictionary = try? JSONSerialization.jsonObject(with: previousVisitorFieldsJSONData,
                                                                                                   options: []) as? [String : Any],
                            let visitorFieldsDictionary = try? JSONSerialization.jsonObject(with: visitorFieldsJSONData,
                                                                                            options: []) as? [String : Any] {
                            if let previousID = previousVisitorFieldsDictionary?[VisitorFieldsJSONField.ID.rawValue] as? String,
                                let id = visitorFieldsDictionary?[VisitorFieldsJSONField.ID.rawValue] as? String {
                                if previousID != id {
                                    onVisitorIDChangeListener!()
                                }
                            }
                        }
                    }
                }
            }
            
            userDefaults[UserDefaultsMainPrefix.VISITOR.rawValue] = visitorFieldsJSONString
            userDefaults[UserDefaultsMainPrefix.SESSION_ID.rawValue] = sessionID
            userDefaults[UserDefaultsMainPrefix.PAGE_ID.rawValue] = authorizationData.getPageID()
            userDefaults[UserDefaultsMainPrefix.AUTHORIZATION_TOKEN.rawValue] = authorizationData.getAuthorizationToken()
            UserDefaults.standard.set(userDefaults,
                                      forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.setValue([UserDefaultsMainPrefix.VISITOR.rawValue : visitorFieldsJSONString,
                                            UserDefaultsMainPrefix.SESSION_ID.rawValue : sessionID,
                                            UserDefaultsMainPrefix.PAGE_ID.rawValue : authorizationData.getPageID(),
                                            UserDefaultsMainPrefix.AUTHORIZATION_TOKEN.rawValue : authorizationData.getAuthorizationToken()],
                                           forKey: userDefaultsKey)
        }
    }
    
}

// MARK: -
final private class DestroyIfNotErrorListener: InternalErrorListener {
    
    // MARK: - Properties
    private let internalErrorListener: InternalErrorListener?
    private let sessionDestroyer: SessionDestroyer?
    
    // MARK: - Initialization
    init(sessionDestroyer: SessionDestroyer?,
         internalErrorListener: InternalErrorListener?) {
        self.sessionDestroyer = sessionDestroyer
        self.internalErrorListener = internalErrorListener
    }
    
    // MARK: - Methods
    // MARK: InternalErrorListener protocol methods
    func on(error: String?,
            urlString: String) {
        if (sessionDestroyer == nil)
            || (sessionDestroyer?.isDestroyed() == false) {
            if sessionDestroyer != nil {
                sessionDestroyer?.destroy()
            }
            
            if internalErrorListener != nil {
                internalErrorListener?.on(error: error,
                                          urlString: urlString)
            }
        }
    }
    
}

// MARK: -
final private class ErrorHandlerToInternalAdapter: InternalErrorListener {
    
    // MARK: - Parameters
    private let fatalErrorHandler: FatalErrorHandler?
    
    // MARK: - Initialization
    init(fatalErrorHandler: FatalErrorHandler?) {
        self.fatalErrorHandler = fatalErrorHandler
    }
    
    // MARK: - Methods
    
    // MARK: InternalErrorListener protocol methods
    func on(error: String?,
            urlString: String) {
        if fatalErrorHandler != nil {
            let webimError = WebimErrorImpl(errorType: (error != nil) ? toPublicErrorType(string: error!) : FatalErrorType.UNKNOWN,
                                            errorString: (error != nil) ? error! : "Unknown error from URL \(urlString)")
            
            fatalErrorHandler?.on(error: webimError)
        }
    }
    
    // MARK: Private methods
    private func toPublicErrorType(string: String) -> FatalErrorType {
        switch string {
        case WebimInternalError.ACCOUNT_BLOCKED.rawValue:
            return FatalErrorType.ACCOUNT_BLOCKED
        case WebimInternalError.VISITOR_BANNED.rawValue:
            return FatalErrorType.VISITOR_BANNED
        case WebimInternalError.WRONG_PROVIDED_VISITOR_HASH.rawValue:
            return FatalErrorType.WRONG_PROVIDED_VISITOR_HASH
        case WebimInternalError.PROVIDED_VISITOR_EXPIRED.rawValue:
            return FatalErrorType.PROVIDED_VISITOR_EXPIRED
        default:
            return FatalErrorType.UNKNOWN
        }
    }
    
}

// MARK: -
final private class HistoryMetaInformationStoragePreferences: HistoryMetaInformationStorage {
    
    // MARK: - Properties
    var userDefaultsKey: String
    
    // MARK: - Initialization
    init(withUserDefaultsKey key: String) {
        self.userDefaultsKey = key
    }
    
    // MARK: - Methods
    // MARK: HistoryMetaInformationStorage protocol methods
    
    func isHistoryEnded() -> Bool {
        if let historyEnded = UserDefaults.standard.dictionary(forKey: userDefaultsKey)?[UserDefaultsMainPrefix.HISTORY_ENDED.rawValue] as? Bool {
            return historyEnded
        }
        
        return false
    }
    
    func set(historyEnded: Bool) {
        if var userDefaults = UserDefaults.standard.dictionary(forKey: userDefaultsKey) {
            userDefaults[UserDefaultsMainPrefix.HISTORY_ENDED.rawValue] = historyEnded
            UserDefaults.standard.set(userDefaults,
                                      forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.setValue([UserDefaultsMainPrefix.HISTORY_ENDED.rawValue : historyEnded],
                                           forKey: userDefaultsKey)
        }
    }
    
    func getRevision() -> String? {
        return UserDefaults.standard.dictionary(forKey: userDefaultsKey)?[UserDefaultsMainPrefix.HISTORY_REVISION.rawValue] as? String
    }
    
    func set(revision: String?) {
        if var userDefaults = UserDefaults.standard.dictionary(forKey: userDefaultsKey) {
            userDefaults[UserDefaultsMainPrefix.HISTORY_REVISION.rawValue] = revision
            UserDefaults.standard.set(userDefaults,
                                      forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.setValue([UserDefaultsMainPrefix.HISTORY_REVISION.rawValue : revision],
                                           forKey: userDefaultsKey)
        }
    }
    
    func clear() {
        if var userDefaults = UserDefaults.standard.dictionary(forKey: userDefaultsKey) {
            userDefaults.removeValue(forKey: UserDefaultsMainPrefix.HISTORY_REVISION.rawValue)
            userDefaults.removeValue(forKey: UserDefaultsMainPrefix.HISTORY_ENDED.rawValue)
            UserDefaults.standard.setValue(userDefaults, forKey: userDefaultsKey)
        }
    }
    
}
