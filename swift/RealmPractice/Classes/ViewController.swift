//
//  ViewController.swift
//  RealmPractice
//
//  Created by Paolo Manna on 21/01/2021.
//

import RealmSwift
import UIKit

// Constants
let partitionValue	= "<Partition Value>"
let appId			= "<Realm App ID>"
let realmFolder			= "mongodb-realm"
let username			= ""
let password			= ""
let userAPIKey			= ""
let customJWT			= ""
let asyncRealmNames		= "AsyncRealmNames"

let manualClientReset	= true	// This is the default, set to false to use .discardLocal

let appConfig		= AppConfiguration(baseURL: nil, transport: nil, localAppName: nil,
             		                   localAppVersion: nil, defaultRequestTimeoutMS: 15000)
let app				= App(id: appId, configuration: appConfig)
let documentsURL	= URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!)

class TestData: Object {
	@Persisted(primaryKey: true) var _id = ObjectId.generate()
	@Persisted var _partition: String = ""
	@Persisted var doubleValue: Double?
	@Persisted var longInt: Int?
	@Persisted var mediumInt: Int?
}

// NOTE: The class of the objects handled here is set at TestData, change it to the one in your app
let objectClass	= TestData.self

class ViewController: UIViewController {
	let dateFormatter	= ISO8601DateFormatter()
	let numFormatter	= NumberFormatter()
	var textView: UITextView!
	var addButton: UIButton!
	var realm: Realm?
	var objects: Results<TestData>!
	var notificationToken: NotificationToken?
	var progressToken: SyncSession.ProgressNotificationToken?
	var progressAmount = 0
	var loginInProgress = false

	func log(_ text: String) {
		textView.text += "[\(dateFormatter.string(from: Date()))] - \(text)\n"
	}
	
	override func viewDidLoad() {
		super.viewDidLoad()
		
		// Do any additional setup after loading the view.
		dateFormatter.formatOptions	= [.withFullDate, .withFullTime]
		dateFormatter.timeZone		= TimeZone(secondsFromGMT: 0)
		
		numFormatter.numberStyle	= .decimal

		view.backgroundColor	= .systemBackground
		
		var textFrame			= view.bounds
		
		textFrame.origin.y		+= 20.0
		textFrame.size.height	-= 60.0

		textView					= UITextView(frame: textFrame)
		textView.autoresizingMask	= [.flexibleWidth, .flexibleHeight]
		textView.font				= UIFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
		
		view.addSubview(textView)
		
		let buttonFrame			= CGRect(x: textFrame.origin.x, y: textFrame.origin.y + textFrame.height,
		               			         width: textFrame.width, height: 40.0)
		
		addButton				= UIButton(frame: buttonFrame)
		
		addButton.autoresizingMask	= [.flexibleWidth, .flexibleTopMargin]
		addButton.setTitle("Add Items", for: .normal)
		addButton.setTitleColor(.blue, for: .normal)
		addButton.addTarget(self, action: #selector(insertUpdateTestData), for: .touchUpInside)
		
		view.addSubview(addButton)

		log("Application started")
		
		// Set these and logLevel to .trace to identify issues in the Sync process
//		Logger.analyseTrace		= true
//		Logger.callback			= log(_:)

		app.syncManager.logLevel	= .detail
		app.syncManager.logger		= { level, message in
			Logger.log(level: level.rawValue, message: message)
		}

		if let user = app.currentUser {
			log("Skipped login, using \(user.id), syncing…")
			
			openRealm(for: user)
		} else {
			logInUser()
		}
	}
	
	// MARK: - Realm operations
	
	fileprivate func logInUser() {
		guard !loginInProgress else { return }
		
		let credentials: Credentials!
		
		loginInProgress = true
		
		if !username.isEmpty {
			credentials	= .emailPassword(email: username, password: password)
		} else if !userAPIKey.isEmpty {
			credentials	= .userAPIKey(userAPIKey)
		} else if !customJWT.isEmpty {
			credentials	= .jwt(token: customJWT)
		} else {
			credentials	= .anonymous
		}
		
		app.login(credentials: credentials) { [weak self] result in
			DispatchQueue.main.async {
				self?.loginInProgress = false
				
				switch result {
				case let .success(user):
					// This is the part that reads the objects via Sync
					self?.log("Logged in \(user.id), syncing…")
					
					self?.openRealm(for: user)
				case let .failure(error):
					self?.log("Login Error: \(error.localizedDescription)")
				}
			}
		}
	}
	
	fileprivate func logOutUser() {
		app.currentUser?.logOut { error in
			DispatchQueue.main.async { [weak self] in
				if error != nil {
					self?.log("Logout Error: \(error!.localizedDescription)")
				} else {
					self?.log("Logged out")
				}
			}
		}
	}
	
	fileprivate func realmBackup(from backupPath: String, to realmFileURL: URL) {
		let backupURL	= realmFileURL.deletingPathExtension().appendingPathExtension("~realm")
		let fm			= FileManager.default
		
		do {
			// Delete file if present
			if fm.fileExists(atPath: backupURL.path) {
				try fm.removeItem(at: backupURL)
			}
			
			// Make a copy of the current realm
			try fm.moveItem(atPath: backupPath, toPath: backupURL.path)
			
			log("Realm backup successful")
		} catch {
			log("Realm backup failed: \(error.localizedDescription)")
		}
	}
	
	fileprivate func realmRestore() {
		guard let realm = realm, let realmFileURL = realm.configuration.fileURL else {
			log("No realm to restore")
			return
		}

		let backupURL	= realmFileURL.deletingPathExtension().appendingPathExtension("~realm")
		let fm			= FileManager.default

		guard fm.fileExists(atPath: backupURL.path) else {
			log("No backup found at \(backupURL.lastPathComponent) to apply")
			return
		}
		
		let config = Realm.Configuration(fileURL: backupURL,
		                                 readOnly: true)
		
		guard let backupRealm = try? Realm(configuration: config) else {
			// Failed, clean backup file
			log("Error applying restore")
			try? fm.removeItem(at: backupURL)
			return
		}
		
		// This part needs to be tailored for the specific realm we're restoring
		// In a nutshell, we need to read all collections that may have been modified by the user
		// and report all changes back to the fresh realm
		let oldObjects	= backupRealm.objects(objectClass)
		
		do {
			try realm.write {
				// Reads all objects, and applies changes
				for anObject in oldObjects {
					realm.create(objectClass, value: anObject, update: .modified)
				}
			}
			
			log("Restore successfully applied")
			try fm.removeItem(at: backupURL)
		} catch {
			log("Restore failed: \(error.localizedDescription)")
		}
	}
	
	func realmExists(for user: User) -> Bool {
		guard let realmFileURL	= user.configuration(partitionValue: partitionValue).fileURL else { return false }
		
		let realmFilePath	= realmFileURL.path
		let ud				= UserDefaults.standard
		
		// If there's a file, check if it's been ever opened successfully
		if FileManager.default.fileExists(atPath: realmFilePath) {
			if let asyncOpenRealms = ud.dictionary(forKey: asyncRealmNames) {
				return asyncOpenRealms[realmFilePath] != nil
			}
		} else if var asyncOpenRealms = ud.dictionary(forKey: asyncRealmNames) {
			// If there's no file, we certainly need to open async, but also delete a possible old reference
			asyncOpenRealms.removeValue(forKey: realmFileURL.path)
			ud.setValue(asyncOpenRealms, forKey: asyncRealmNames)
		}
		return false
	}
	
	// This is used only for sync opening: for async, we attach to the AsyncOpenTask instead
	func realmSetupProgress(for session: SyncSession?) {
		guard let session = session else {
			log("Invalid session for progress notification")
			
			return
		}
		
		progressAmount	= 0
		progressToken	= session.addProgressNotification(for: .download,
		             	                                  mode: .reportIndefinitely) { [weak self] progress in
			if progress.isTransferComplete {
				self?.progressToken?.invalidate()
				self?.progressToken		= nil
				self?.progressAmount	= 0
				
				DispatchQueue.main.async { [weak self] in
					self?.log("Transfer finished")
				}
			} else {
				DispatchQueue.main.async { [weak self] in
					// This can be called multiple times for the same progress, so skip duplicates
					guard let self = self, progress.transferredBytes > self.progressAmount else { return }
					
					let transferredStr		= self.numFormatter.string(from: NSNumber(value: progress.transferredBytes))
					let transferrableStr	= self.numFormatter.string(from: NSNumber(value: progress.transferrableBytes))
					
					self.progressAmount		= progress.transferredBytes
					self.log("Transferred \(transferredStr ?? "??") of \(transferrableStr ?? "??")…")
				}
			}
		}
	}
	
	// These callbacks do nothing here, but can be used to react to a Client Reset when in .discardLocal mode
	func beforeClientReset(_ before: Realm) {
		DispatchQueue.main.async { [weak self] in
			self?.log("Before a Client Reset for \(before.configuration.fileURL!))")
		}
	}
	
	func afterClientReset(_ before: Realm, _ after: Realm) {
		DispatchQueue.main.async { [weak self] in
			self?.log("After a Client Reset for \(before.configuration.fileURL!)) => \(after.configuration.fileURL!))")
		}
	}

	// General error handler: this will handle manual client reset,
	// but is also needed if breaking changes are applied, as .discardLocal won't be enough
	func realmSetupErrorHandler() {
		// Don't re-do it
		guard app.syncManager.errorHandler == nil else { return }
		
		app.syncManager.errorHandler	= { [weak self] error, session in
			guard let self = self, let user = session?.parentUser() else { return }

			let syncError	= error as! SyncError
			var fileURL: URL?
			
			// Extract failing partition from the session, detect which fileURL we're going to backup
			if let partition = session?.configuration()?.partitionValue as? String {
				fileURL	= user.configuration(partitionValue: partition).fileURL
			}
			
			switch syncError.code {
			case .clientResetError:
				if let realmConfigURL = fileURL, let (path, clientResetToken) = syncError.clientResetInfo() {
					self.log("The database is out of sync, resetting client…")
					
					if var asyncOpenRealms	= UserDefaults.standard.dictionary(forKey: asyncRealmNames) {
						asyncOpenRealms.removeValue(forKey: realmConfigURL.path)
						UserDefaults.standard.setValue(asyncOpenRealms, forKey: asyncRealmNames)
					}
					
					self.realmCleanup()
					
					// This clears the old realm files and makes a backup in `recovered-realms`
					SyncSession.immediatelyHandleError(clientResetToken, syncManager: app.syncManager)
					
					// Copy from the auto-generated backup to a known location
					self.realmBackup(from: path, to: realmConfigURL)
					
					// At this point, realm is gone, so user can be advised to quit and re-enter app (or at least logout)
					// Here we just retry to open the same realm again: YMMV
					DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
						self?.log("Trying to re-open realm…")
						self?.openRealm(for: user)
					}
				}
			case .clientUserError, .underlyingAuthError:
				self.log("Authentication Error: \(syncError.localizedDescription)")
				DispatchQueue.main.async { [weak self] in
					// Cleanup and force a new full login
					self?.realmCleanup()
					if app.currentUser != nil {
						self?.log("Logging out…")
						self?.logOutUser()
					} else {
						self?.log("Trying to login again…")
						self?.logInUser()
					}
				}
			default:
				print("SyncManager Error: ", error.localizedDescription)
			}
		}
	}
	
	fileprivate func realmSyncOpen(with user: User) {
		// The simplest Client Reset handling is just to use .discardLocal(), but won't handle breaking changes
		let clientResetMode: ClientResetMode	= manualClientReset ? .manual() : .discardUnsyncedChanges(beforeReset: { [weak self] before in self?.beforeClientReset(before) },
		                                    	                                                          afterReset: { [weak self] before, after in self?.afterClientReset(before, after) })
		let config	= user.configuration(partitionValue: partitionValue, clientResetMode: clientResetMode)
		
		realmSetupErrorHandler()
		
		do {
			realm = try Realm(configuration: config)
			
			log("Opened \(partitionValue) Realm (sync)")
			
			realmSetupProgress(for: realm?.syncSession)
			
			realmRestore()
			realmSetup()
		} catch {
			log("Sync Open Error: \(error.localizedDescription)")
			realmCleanup(delete: true)
		}
	}
	
	fileprivate func realmAsyncOpen(with user: User) {
		let clientResetMode: ClientResetMode	= manualClientReset ? .manual() : .discardUnsyncedChanges(beforeReset: { [weak self] before in self?.beforeClientReset(before) },
		                                    	                                                          afterReset: { [weak self] before, after in self?.afterClientReset(before, after) })
		let config	= user.configuration(partitionValue: partitionValue, clientResetMode: clientResetMode)
		
		
		realmSetupErrorHandler()

		let task	= Realm.asyncOpen(configuration: config,
		        	                  callbackQueue: DispatchQueue.main) { [weak self] result in
			switch result {
			case let .success(openRealm):
				self?.realm = openRealm
				
				// Async open completed successfully, store it in the prefs
				if let realmFileURL = config.fileURL {
					var asyncOpenRealms = UserDefaults.standard.dictionary(forKey: asyncRealmNames) ?? [String: Any]()
					
					asyncOpenRealms[realmFileURL.path]	= true
					UserDefaults.standard.setValue(asyncOpenRealms, forKey: asyncRealmNames)
				}
				
				self?.log("Opened \(partitionValue) Realm (async)")
				
				self?.realmRestore()
				self?.realmSetup()
				
			case let .failure(error):
				self?.log("Async Open Error: \(error.localizedDescription)")
				self?.realmCleanup(delete: false)
			}
		}
		
		progressAmount	= 0
		task.addProgressNotification(queue: .main) { [weak self] progress in
			if progress.isTransferComplete {
				self?.progressAmount	= 0
				self?.log("Transfer finished")
			} else {
				guard let self = self, progress.transferredBytes > self.progressAmount else { return }

				let transferredStr		= self.numFormatter.string(from: NSNumber(value: progress.transferredBytes))
				let transferrableStr	= self.numFormatter.string(from: NSNumber(value: progress.transferrableBytes))
				
				self.progressAmount		= progress.transferredBytes
				self.log("Transferred \(transferredStr ?? "??") of \(transferrableStr ?? "??")…")
			}
		}
	}
	
	func openRealm(for user: User) {
		// It's suggested that async is used at first launch, sync after
		// This check is very simple: when opening multiple realms,
		// or recovering from a client reset, you may want to have a smarter one
		if realmExists(for: user) {
			realmSyncOpen(with: user)
		} else {
			realmAsyncOpen(with: user)
		}
	}
	
	func realmSetup() {
		guard let realm = realm else {
			log("No realm defined")
			
			return
		}
		
		// Access objects in the realm, sorted by _id so that the ordering is defined.
		objects = realm.objects(objectClass).sorted(byKeyPath: "_id")

		guard objects != nil else {
			log("Query Error: No objects found")
			
			return
		}
		
		// Observe the projects for changes.
		notificationToken = objects.observe { [weak self] changes in
			switch changes {
			case .initial:
				// Results are now populated and can be accessed without blocking the UI
				self?.log("Initial load change")
			case let .update(_, deletions, insertions, modifications):
				// Query results have changed, so apply them
				self?.log("Received \(deletions.count) deleted, \(insertions.count) inserted, \(modifications.count) updates")
			case let .error(error):
				// An error occurred while opening the Realm file on the background worker thread
				self?.log("Observe Error: \(error.localizedDescription)")
			}
		}
		
		log("Number of \(objectClass) objects obtained: \(objects.count)")
	}
	
	func realmCleanup(delete: Bool = false) {
		// Invalidate progress, if set
		progressToken?.invalidate()
		progressToken		= nil
		
		guard let realm = realm else { return }
		
		// Invalidate observer
		notificationToken?.invalidate()
		notificationToken	= nil
		
		// Clear results list
		objects	= nil
		
		// Invalidate and clear the realm itself
		realm.invalidate()
		self.realm	= nil
		
		log("Closed \(partitionValue) Realm")
		
		if delete {
			guard let config = app.currentUser?.configuration(partitionValue: partitionValue) else { return }
			
			// Deleting immediately doesn't work, introduce a small wait
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
				do {
					if let realmFileURL = config.fileURL,
					   var asyncOpenRealms	= UserDefaults.standard.dictionary(forKey: asyncRealmNames)
					{
						asyncOpenRealms.removeValue(forKey: realmFileURL.path)
						UserDefaults.standard.setValue(asyncOpenRealms, forKey: asyncRealmNames)
					}
					
					_	= try Realm.deleteFiles(for: config)
					
					self?.log("Deleted realm files")
				} catch {
					self?.log("Clear Realm Error: \(error.localizedDescription)")
				}
			}
		}
	}
	
	// MARK: - DB Fill in - just an example here
	
	fileprivate func createDocument() -> TestData {
		let document	= TestData()
		
		document._partition		= partitionValue
		document.doubleValue	= Double(arc4random_uniform(100000)) / 100.0
		document.longInt		= Int(arc4random_uniform(1000000))
		document.mediumInt		= Int(arc4random_uniform(1000))

		return document
	}
	
	fileprivate func createDocumentList() -> [TestData] {
		var docList	= [TestData]()
		
		for _ in 0 ..< 500 {
			let document	= createDocument()
			
			docList.append(document)
		}
		
		return docList
	}
	
	@IBAction func insertUpdateTestData() {
		do {
			if objects.isEmpty {
				let documentList	= createDocumentList()
				
				try realm?.write { [weak self] in
					self?.realm?.add(documentList, update: .modified)
				}
				log("Inserted: \(documentList.count) documents")
			} else {
				guard let localRealm = realm, let records = objects else { return }
				
				// Add new data to embedded array
				try localRealm.write {
					records.forEach {
						$0.longInt!		-= 1
						$0.mediumInt!	+= 1
						$0.doubleValue!	*= 1.1
					}
				}
				log("Updated: \(records.count) documents")
			}
		} catch {
			log("Error inserting/updating: \(error.localizedDescription)")
		}
	}
}
