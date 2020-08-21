//
//  UserSessionService.swift
//  MobileMessaging
//
//  Created by Andrey Kadochnikov on 17.01.2020.
//

import Foundation
import CoreData

class UserSessionService : MobileMessagingService {

	var currentSessionId: String? {
		if let pushRegId = mmContext.currentInstallation().pushRegistrationId, let currentSessionStartDate = fetchCurrentSessionStartDate() {
			return "\(pushRegId)_\(Int64(floor(currentSessionStartDate.timeIntervalSince1970 * 1000)))"
		} else {
			return nil
		}
	}

	private enum State {
		case suspended
		case resumed
	}
	private var state: State = .suspended
	private let serviceQueue = MMQueue.Serial.New.UserSessionQueue.queue.queue
	private let userSessionPersistingQueue = MMOperationQueue.newSerialQueue
	private let userSessionReportingQueue = MMOperationQueue.newSerialQueue
	private var isReportingNeeded = true
	private var timer: RepeatingTimer?
	private let context: NSManagedObjectContext

	init(mmContext: MobileMessaging) {
		self.context = mmContext.internalStorage.newPrivateContext()
		super.init(mmContext: mmContext, uniqueIdentifier: "UserSessionService")
	}

	//MARK: -

	override func stop(_ completion: @escaping (Bool) -> Void) {
		serviceQueue.async {
			self.logDebug("stops")
			self.timer = nil
			self.cancelOperations()
			super.stop(completion)
		}
	}

	override func start(_ completion: @escaping (Bool) -> Void) {
		serviceQueue.async {
			self.logDebug("starts")
			self.setupTimer()
			super.start(completion)
		}
	}

	override func mobileMessagingWillStart(_ mmContext: MobileMessaging) {
		start({_ in })
	}

	override func mobileMessagingWillStop(_ mmContext: MobileMessaging) {
		stop({_ in})
	}

	override func appWillEnterForeground(_ notification: Notification) {
		serviceQueue.async {
			self.isReportingNeeded = true
		}
	}

	override func appDidBecomeActive(_ notification: Notification) {
		serviceQueue.async {
			self.logDebug("timer resumes: app did become active state")
			self.timer?.resume()
		}
	}

	override func appWillResignActive(_ notification: Notification) {
		serviceQueue.async {
			self.logDebug("timer suspends: app will resign active state")
			self.timer?.suspend()
		}
	}

	override func appWillTerminate(_ n: Notification) {
		serviceQueue.async {
			self.logDebug("timer cancels: app will terminate")
			self.stop({ _ in })
		}
	}

	//MARK: -

	func fetchCurrentSessionStartDate() -> Date? {
		var result: Date? = nil
		context.performAndWait {
			result = fetchCurrentSession()?.startDate
		}
		return result
	}

	func fetchCurrentSession() -> UserSessionReportObject? {
		var result: UserSessionReportObject? = nil
		context.performAndWait {
			result = UserSessionReportObject.MM_find(
				withPredicate: NSPredicate(format: "endDate > %@", MobileMessaging.date.now.addingTimeInterval(-Consts.UserSessions.sessionTimeoutSec) as NSDate),
				fetchLimit: 1,
				sortedBy: "startDate",
				ascending: true,
				inContext: context)?.first
		}
		return result
	}

	func performSessionTracking(doReporting: Bool, completion: @escaping () -> Void) {
		guard MobileMessaging.application.applicationState == .active else {
			logDebug("app is not in active state, skipping session tracking.")
			completion()
			return
		}
		guard let pushRegId = mmContext.currentInstallation().pushRegistrationId else {
			logDebug("no push registration id. Aborting...")
			completion()
			return
		}
		let now = MobileMessaging.date.now

		userSessionPersistingQueue.addOperation(UserSessionPersistingOperation(mmContext: mmContext, pushRegId: pushRegId, sessionTimestamp: now, context: context, finishBlock: { _ in

			if doReporting {
				self.isReportingNeeded = false
				if !self.userSessionReportingQueue.addOperationExclusively(UserSessionsReportingOperation(mmContext: self.mmContext, context: self.context, finishBlock: {_ in
					completion()
				})) {
					completion()
				}
			} else {
				completion()
			}
		}))
	}

	private func cancelOperations() {
		userSessionPersistingQueue.cancelAllOperations()
		userSessionReportingQueue.cancelAllOperations()
	}

	private func setupTimer() {
		guard !isTestingProcessRunning else {
			return
		}
		timer = RepeatingTimer(timeInterval: Consts.UserSessions.sessionSaveInterval, queue: serviceQueue)
		timer?.eventHandler = handleTimerEvent
		timer?.resume()
	}

	private func handleTimerEvent() { // performs in timerQueue
		assert(!Thread.isMainThread)
		performSessionTracking(doReporting: isReportingNeeded, completion: {  })
	}

	private func setupObservers() {
		guard !isTestingProcessRunning else {
			return
		}
	}
}
