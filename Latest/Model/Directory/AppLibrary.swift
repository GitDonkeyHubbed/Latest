//
//  AppLibrary.swift
//  Latest
//
//  Created by Max Langer on 08.01.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Foundation

/// Observes the local collection of apps and notifies its owner of changes.
class AppLibrary {
	
	/// The handler to be called when apps change locally.
	typealias UpdateHandler = ([App.Bundle]) -> Void
	let updateHandler: UpdateHandler
	
	/// A list of all application bundles that are available locally.
	var bundles: [App.Bundle] {
		directoriesLock.withCriticalScope { directories }.flatMap { $0.value.bundles }
	}
		
	/// The observed directories. Guarded by `directoriesLock`, as it is read from several queues.
	private var directories = [URL: AppDirectory]()
	
	/// Protects `directories`.
	private let directoriesLock = NSLock()
	
	/// Serializes directory setup, so concurrent rescans cannot interleave.
	private let setupQueue = DispatchQueue(label: "AppLibrarySetupQueue")
	
	/// Initializes the library with the given handler for updates.
	init(handler: @escaping UpdateHandler) {
		self.updateHandler = handler
	}
	
	private let schedulerQueue = DispatchQueue(label: "AppLibrarySchedulerQueue")
	private var updateWorkItem: DispatchWorkItem?

	private func scheduleUpdate() {
		schedulerQueue.async { [self] in
			self.updateWorkItem?.cancel()
			let workItem = DispatchWorkItem { [weak self] in
				self?.performUpdate()
			}
			self.updateWorkItem = workItem
			self.schedulerQueue.asyncAfter(deadline: .now() + 10, execute: workItem)
		}
	}

	
	// MARK: - Actions
	
	/// Starts the update checking process
	func startQuery() {
		setupQueue.async {
			self.setupDirectoryObservers()
		}
	}
		
	private func setupDirectoryObservers() {
		// Use a dispatch group for the initial setup to get contents for all directories before gathering apps
		let existingDirectories = directoriesLock.withCriticalScope { self.directories }
		let dispatchGroup: DispatchGroup? = existingDirectories.isEmpty ? DispatchGroup() : nil

		// Setup directories
		let directories = Dictionary(uniqueKeysWithValues: directoryStore.URLs.compactMap { url -> (URL, AppDirectory)? in
			// Skip unreachable directories
			guard directoryStore.isReachable(url) else { return nil }

			dispatchGroup?.enter()

			// The callback fires again for every later content change, but the
			// group must be left exactly once per directory — a directory that
			// changes again while another one is still listing its initial
			// contents would otherwise unbalance the group and crash.
			let initialContentsLock = NSLock()
			var initialContentsListed = false

			// Reuse existing directory observations if possible
			return (url, existingDirectories[url] ?? AppDirectory(url: url) {
				let isInitialContents = initialContentsLock.withCriticalScope { () -> Bool in
					guard !initialContentsListed else { return false }
					initialContentsListed = true
					return true
				}

				if isInitialContents, let dispatchGroup {
					// Initial mode, notify dispatch group
					dispatchGroup.leave()
				} else {
					// Schedule update
					self.scheduleUpdate()
				}
			})
		})
		directoriesLock.withCriticalScope { self.directories = directories }

		if let dispatchGroup {
			dispatchGroup.notify(queue: .global()) {
				// Call update immediately. Using the scheduler delays the update.
				self.performUpdate()
			}
		} else {
			// A rescan (e.g. locations changed in settings). Removed directories trigger no
			// callback of their own, so publish the new set of bundles right away.
			self.performUpdate()
		}
	}
	
	private func performUpdate() {
		updateHandler(bundles)
	}

	
	
	// MARK: - Directory Handling
	
	/// The store handling application directories.
	private lazy var directoryStore = {
		AppDirectoryStore(updateHandler: self.startQuery)
	}()
	
}
