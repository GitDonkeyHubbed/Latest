//
//  HomebrewCheckerOperation.swift
//  Latest
//
//  Created by Max Langer on 12.03.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Cocoa

/// The operation for checking for updates via Homebrew.
class HomebrewCheckerOperation: StatefulOperation, UpdateCheckerOperation, @unchecked Sendable {
	
	static var sourceType: App.Source {
		return .none
	}
	
	/// The bundle to be checked for updates.
	private let bundle: App.Bundle
	
	/// The update fetched during the checking operation.
	fileprivate var update: App.Update?
	
	private let repository: UpdateRepository?
	
	static func canPerformUpdateCheck(forAppAt url: URL) -> Bool {
		return true
	}
		
	required init(with bundle: App.Bundle, repository: UpdateRepository?, completionBlock: @escaping UpdateCheckerCompletionBlock) {
		self.bundle =  bundle
		self.repository = repository
		
		super.init()
		
		self.completionBlock = {
			if let update = self.update {
				completionBlock(.success(update))
			} else {
				completionBlock(.failure(self.error ?? LatestError.updateInfoUnavailable))
			}
		}
	}
	
	
	// MARK: - Operation

	override func execute() {
		guard let repository else {
			self.finish()
			return
		}
		
		repository.updateInfo(for: bundle) { bundle, version, minimumOSVersion, caskToken in
			defer { self.finish() }
			guard let version else { return }

			// Perform the upgrade directly when Homebrew is installed and the app was actually
			// installed through it. Otherwise, fall back to opening the app so its own update
			// mechanism can take over. The scanned copy must live in /Applications — brew's
			// default appdir — since a Caskroom entry says nothing about copies elsewhere
			// (e.g. an app reinstalled manually after the cask install). Compare canonical paths
			// (resolve symlinks + standardize) so a bundle reached through a symlinked or
			// non-canonical /Applications path is still recognized and the operation stays
			// constructible (C3).
			let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL
			let updateAction: App.Update.Action
			if let caskToken, let brewURL = HomebrewInstallation.brewURL, HomebrewInstallation.isCaskInstalled(caskToken, brewURL: brewURL),
			   bundle.fileURL.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == applicationsURL {
				updateAction = .builtIn(block: { app in
					UpdateQueue.shared.addOperation(HomebrewUpdateOperation(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier, caskToken: caskToken, brewURL: brewURL))
				})
			} else {
				updateAction = .external(label: bundle.name, block: { app in
					app.open()
				})
			}

			self.update = App.Update(app: bundle, remoteVersion: version, minimumOSVersion: minimumOSVersion, source: .homebrew, date: nil, releaseNotes: nil, updateAction: updateAction)
		}
	}
	
}
