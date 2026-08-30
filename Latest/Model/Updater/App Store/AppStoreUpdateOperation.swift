//
//  AppStoreUpdateOperation.swift
//  Latest
//
//  Created by Max Langer on 01.07.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import CommerceKit
import StoreFoundation

/// The operation updating Mac App Store apps.
class AppStoreUpdateOperation: UpdateOperation, @unchecked Sendable {

	/// The purchase associated with the to be updated app.
	private var purchase: SSPurchase!

	/// The observer that observes the Mac App Store updater. Guarded by `observerLock`:
	/// it is written on CommerceKit's callback thread and read on whichever thread finishes.
	private var observerIdentifier: CKDownloadQueueObserver?

	/// Protects `observerIdentifier` against the registration-vs-finish race.
	private let observerLock = NSLock()

	/// The app-store identifier for the related app.
	private let itemIdentifier: UInt64

	private let installURL: URL

	private var installerPackageURL: URL?

	init(bundleIdentifier: String, installURL: URL, appIdentifier: App.Bundle.Identifier, appStoreIdentifier: UInt64) {
		self.installURL = installURL
		self.itemIdentifier = appStoreIdentifier
		super.init(bundleIdentifier: bundleIdentifier, appIdentifier: appIdentifier)
	}
	
	static func prepareForUpdates() throws(InstallHelperError) {
		// Framework can download and install apps automatically
		if requiresManualInstallation {
			try InstallHelper.verifyAvailability()
		}
	}
	
	fileprivate static let requiresManualInstallation: Bool = {
		let version = ProcessInfo.processInfo.operatingSystemVersion
		
		return switch version.majorVersion {
		case 14:
			ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 14, minorVersion: 8, patchVersion: 2))
		case 15:
			ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 7, patchVersion: 2))
		default:
			ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 26, minorVersion: 1, patchVersion: 0))
		}
	}()
	
	
	// MARK: - Operation Overrides

	override func execute() {
		super.execute()
		
		// Construct purchase to receive update
		let purchase = SSPurchase(itemIdentifier: self.itemIdentifier, account: nil)
		CKPurchaseController.shared().perform(purchase, withOptions: 0) { [weak self] purchase, _, error, response in
			guard let self = self else { return }

			if let error = error {
				self.finish(with: error)
				return
			}

			if let downloads = response?.downloads, downloads.count > 0, let purchase = purchase {
				guard !self.isCancelled, !self.isFinished else {
					// The operation was cancelled or timed out while the purchase was
					// in flight; cancel the downloads delivered with the response
					// directly (the shared queue's mirror may not contain them yet).
					downloads.forEach { $0.cancel(withStoreClient: ISStoreClient(storeClientType: 0)) }
					self.cancelQueuedDownloads()
					return
				}

				self.purchase = purchase

				let identifier = CKDownloadQueue.shared().add(self)
				self.observerLock.withCriticalScope { self.observerIdentifier = identifier }

				// Re-check after publishing: a concurrent cancel or timeout may have
				// finished the operation between the guard above and the registration,
				// in which case willFinish already ran and read a nil observer.
				// Clean up here so no zombie observer outlives the operation.
				if self.isCancelled || self.isFinished {
					CKDownloadQueue.shared().remove(identifier)
					self.observerLock.withCriticalScope { self.observerIdentifier = nil }
					downloads.forEach { $0.cancel(withStoreClient: ISStoreClient(storeClientType: 0)) }
					self.cancelQueuedDownloads()
				}
			} else {
				self.finish(with: LatestError.updateInfoUnavailable)
			}
		}
	}
	
	override func cancel() {
		super.cancel()

		// Finishing removes the download queue observer, after which the isCancelled
		// branch in the status callback can no longer run. Cancel the in-flight
		// download explicitly before tearing down.
		self.cancelQueuedDownloads()

		self.finish()
	}

	override func willFinish() {
		let observerIdentifier = self.observerLock.withCriticalScope { () -> CKDownloadQueueObserver? in
			let identifier = self.observerIdentifier
			self.observerIdentifier = nil
			return identifier
		}
		if let observerIdentifier {
			CKDownloadQueue.shared().remove(observerIdentifier)
		}

		super.willFinish()
	}

	override func timeoutTeardown() {
		// Tear down the in-flight download so CommerceKit does not keep
		// downloading (and possibly installing) after the operation failed.
		// Queried fresh from the shared queue; caching the download reference
		// here would race CommerceKit's callback thread.
		self.cancelQueuedDownloads()
		super.timeoutTeardown()
	}

	/// Cancels any in-flight App Store download for this operation's item.
	private func cancelQueuedDownloads() {
		for case let download as SSDownload in CKDownloadQueue.shared().downloads where download.metadata.itemIdentifier == self.itemIdentifier {
			download.cancel(withStoreClient: ISStoreClient(storeClientType: 0))
		}
	}

	
	// MARK: - Manual Installation
	
	/// Adds a link to the downloaded app store package to retrieve it at a later time.
	fileprivate static func snapshotAppStorePackage(at path: String) -> URL? {
		do {
			let packageURL = URL(fileURLWithPath: path)
			let fileManager = FileManager.default
			
			let hardLinkURL = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: packageURL, create: true).appending(path: packageURL.lastPathComponent, directoryHint: .notDirectory)
			try fileManager.linkItem(at: packageURL, to: hardLinkURL)
			
			return hardLinkURL
		} catch {
			return nil
		}
	}
}


// MARK: - Download Observer

extension AppStoreUpdateOperation: CKDownloadQueueObserver {

	func downloadQueue(_ downloadQueue: CKDownloadQueue!, statusChangedFor download: SSDownload!) {
		guard download.metadata.itemIdentifier == itemIdentifier, let status = download.status else {
			return
		}

		// Cancel download if the operation has been cancelled
		if self.isCancelled {
			download.cancel(withStoreClient: ISStoreClient(storeClientType: 0))
			self.finish()
			return
		}

		self.noteActivity()

		// Nothing left to do besides forwarding progress; we wait for the install failure.
		// Keep assigning progressState so the inactivity watchdog (reset in its didSet)
		// is fed while the download finishes and the OS runs its automatic install attempt.
		if self.installerPackageURL != nil {
			self.progressState = .extracting(progress: min(0.7 + 0.3 * Double(status.percentComplete), 0.99))
			return
		}

		if Self.requiresManualInstallation && status.percentComplete >= 0.8 {
			// Keep the installer alive by linking to it. Manual installation will follow once the automatic one failed.
			self.progressState = .extracting(progress: 0.2)
			self.installerPackageURL = Self.snapshotAppStorePackage(at: download.primaryAsset.downloadPath)
			self.progressState = .extracting(progress: 0.7)
		} else {
			switch status.activePhase.phaseType {
			case 0:
				self.progressState = .downloading(loadedSize: Int64(status.activePhase.progressValue), totalSize: Int64(status.activePhase.totalProgressValue))
			case 1:
				self.progressState = .extracting(progress: Double(status.activePhase.progressValue) / Double(status.activePhase.totalProgressValue))
			default:
				self.progressState = .initializing
			}
		}
	}

	func downloadQueue(_ downloadQueue: CKDownloadQueue!, changedWithRemoval download: SSDownload!) {
		guard download.metadata.itemIdentifier == self.purchase.itemIdentifier, let status = download.status else {
			return
		}

		// Installed successfully
		guard status.isFailed else {
			self.finish()
			return
		}
		
		// No manual installation possible, abort with error
		guard let installerPackageURL, let receiptData = download.metadata.receiptData else {
			self.finish(with: status.error)
			return
		}

		// `installer -target /` places the package at its predefined location inside
		// /Applications. An app living elsewhere would be duplicated rather than
		// updated, so fall back to the plain error for those. Compare canonical paths
		// (resolve symlinks + standardize) so a bundle reached through a symlinked or
		// non-canonical /Applications path is still recognized (C2). The install target
		// stays hard-coded to `/` server-side (C1/C6): the refuted crosscheck suggestion to
		// target the resolved bundle path is intentionally not applied — MAS packages carry
		// absolute paths and the helper no longer accepts a client-supplied target.
		let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL
		guard self.installURL.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == applicationsURL else {
			self.finish(with: status.error)
			return
		}

		// The location appStoreReceiptURL resolves to for an app bundle. Resolve symlinks in the
		// bundle path first (C7): the receipt destination handed to the root helper must be a
		// real path, not one whose ancestor is a symlink that could redirect the privileged
		// write. The helper independently refuses to traverse symlinks per component.
		let receiptURL = self.installURL.resolvingSymlinksInPath().appending(path: "Contents/_MASReceipt/receipt")

		Task { [weak self] in
			guard let self, !self.isCancelled else {
				self?.finish()
				return
			}
			
			self.progressState = .installing
			
			// C6: open a file handle on the snapshot and hand that to the helper instead of a
			// path. The helper reads the exact bytes we opened here into a root-owned copy and
			// verifies the signature there, so the staged file cannot be swapped between the
			// helper's check and use. The snapshot lives in a user-writable replacement
			// directory, so this app — not the helper — owns cleaning it up afterwards.
			let snapshotDirectory = installerPackageURL.deletingLastPathComponent()
			defer { try? FileManager.default.removeItem(at: snapshotDirectory) }

			do {
				let fileHandle = try FileHandle(forReadingFrom: installerPackageURL)
				defer { try? fileHandle.close() }

				// The privileged helper reports no progress; extend the watchdog so a
				// long-running install is not mistaken for a stall.
				self.extendWatchdog(by: 30 * 60)
				try await InstallHelper.shared.installPackage(fileHandle: fileHandle, receiptData: receiptData, receiptURL: receiptURL)
				self.finish()
			} catch {
				self.finish(with: error)
			}
		}
	}

	func downloadQueue(_ downloadQueue: CKDownloadQueue!, changedWithAddition download: SSDownload!) {}

}

private extension SSPurchase {
	convenience init(itemIdentifier: UInt64, account: ISStoreAccount?) {
		self.init()

		let parameters: [String: Any] = [
			"productType": "C",
			"price": 0,
			"salableAdamId": itemIdentifier,
			"pg": "default",
			"appExtVrsId": 0,

			// is redownload, use existing functionality
			"pricingParameters": "STDRDL"
		]

		buyParameters =
			parameters.map { key, value in
				"\(key)=\(value)"
			}
			.joined(separator: "&")

		if let account = account {
			accountIdentifier = account.dsID
			appleID = account.identifier
		}

		let downloadMetadata = SSDownloadMetadata()
		downloadMetadata.kind = "software"
		downloadMetadata.itemIdentifier = itemIdentifier

		self.downloadMetadata = downloadMetadata
		self.itemIdentifier = itemIdentifier
	}
}

extension SSDownloadMetadata {
	/// Returns the app store receipt from the metadata.
	var receiptData: Data? {
		dictionary?["app-receipt"] as? Data
	}
}
