//
//  UpdateQueue.swift
//  Latest
//
//  Created by Max Langer on 01.07.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import Foundation

/// The queue where update operations are scheduled on.
class UpdateQueue: OperationQueue, @unchecked Sendable {

	// MARK: - Initialization
	private override init() {
		super.init()

		self.maxConcurrentOperationCount = 3
	}

	/// The shared instance of the queue.
	static let shared = UpdateQueue()

	/// Invoked after an update operation installed its update successfully.
	var onOperationFinished: ((App.Bundle.Identifier) -> Void)?

	/// Whether the given finished operation installed its update, so the installed apps should be rescanned.
	///
	/// Failed and cancelled operations leave the app as it was. Rescanning after them would rebuild the
	/// app's row, whose update button then re-reads the (now `.none`) queue state and hides the error.
	static func didInstallUpdate(_ operation: UpdateOperation) -> Bool {
		return !operation.isCancelled && operation.error == nil
	}

	// MARK: - Public Methods

	/// The handler forwarding the current progress state.
	typealias ProgressHandler = (_: App.Bundle.Identifier) -> Void

	/// Cancels the update operation for the given app.
	func cancelUpdate(for identifier: App.Bundle.Identifier) {
		guard let operation = self.operation(for: identifier) else { return }
		operation.cancel()
	}

	/// Whether the queue contains an update operation for the given app.
	func contains(_ identifier: App.Bundle.Identifier) -> Bool {
		return self.operation(for: identifier) != nil
	}

	/// Returns the state for a given app.
	func state(for identifier: App.Bundle.Identifier) -> UpdateOperation.ProgressState {
		return self.operation(for: identifier)?.progressState ?? .none
	}

	override func addOperation(_ op: Operation) {
		// Abort if the operation is of an unknown type
		guard let operation = op as? UpdateOperation else {
			assertionFailure("Added unknown operation \(op.self) to update queue.")
			return
		}

		// Abort if the app is already in the queue
		if !self.contains(operation.appIdentifier) {
			// Homebrew holds a global lock, so brew upgrades run one at a time. Chain
			// them via dependencies: a waiting operation stays unstarted, occupies no
			// concurrency slot, and arms no watchdog until it is its turn.
			if let brewOperation = operation as? HomebrewUpdateOperation,
			   let previousBrewOperation = self.operations.compactMap({ $0 as? HomebrewUpdateOperation }).last {
				brewOperation.addDependency(previousBrewOperation)
			}

			let existingCompletion = operation.completionBlock
			operation.completionBlock = { [weak self] in
				existingCompletion?()
				guard Self.didInstallUpdate(operation) else { return }
				self?.onOperationFinished?(operation.appIdentifier)
			}

			// Install the handler before enqueueing: the queue may start the operation (which
			// reports progress right away) on another thread as soon as it is added.
			operation.progressHandler = { identifier in
				self.notifyObservers(for: identifier)
			}

			super.addOperation(op)

			// Installing the handler already notified observers, but before the operation was
			// enqueued, so they saw no state. Report `.pending` now; an operation waiting for a
			// slot or a previous brew upgrade reports nothing else until it starts.
			self.notifyObservers(for: operation.appIdentifier)
		}
	}

	// MARK: - Observer Handling

	/// The handler for notifying observers about changes to the update state.
	typealias ObserverHandler = (_: UpdateOperation.ProgressState) -> Void

	/// A mapping of observers associated with apps.
	private var observers = [App.Bundle.Identifier: [NSObject: ObserverHandler]]()

	/// Adds the observer if it is not already registered.
	func addObserver(_ observer: NSObject, to identifier: App.Bundle.Identifier, handler: @escaping ObserverHandler) {
		var observers = self.observers[identifier] ?? [:]

		// Only add the observer, if it is not already installed.
		guard observers[observer] == nil else {
			return
		}

		observers[observer] = handler

		// Call handler immediately to propagate initial state
		handler(self.state(for: identifier))

		// Update observers
		self.observers[identifier] = observers
	}

	/// Removes the observer.
	func removeObserver(_ observer: NSObject, for identifier: App.Bundle.Identifier) {
		self.observers[identifier]?.removeValue(forKey: observer)
	}

	/// Notifies observers about state changes.
	private func notifyObservers(for identifier: App.Bundle.Identifier) {
		let state = self.state(for: identifier)

		DispatchQueue.main.async {
			self.observers[identifier]?.forEach { (_: NSObject, handler: UpdateQueue.ObserverHandler) in
				handler(state)
			}
		}
	}

	// MARK: - Helper

	/// Returns the operation for the given app.
	private func operation(for identifier: App.Bundle.Identifier) -> UpdateOperation? {
		guard let updateOperations = self.operations as? [UpdateOperation] else {
			fatalError("Unknown operations in update queue")
		}

		return updateOperations.first(where: { $0.appIdentifier == identifier })
	}

}
