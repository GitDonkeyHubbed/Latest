//
//  UpdateInstallHelper.swift
//  Latest
//
//  Created by Max Langer on 11.01.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//

import AppKit
import os
import ServiceManagement

/// Manages the privileged helper daemon used to install App Store updates via XPC.
actor InstallHelper {
	
	/// The shared instance used for installing packages.
	static let shared = InstallHelper()
	
	private static let installHelperName = "com.max-langer.latest.UpdateInstaller"
	
	private init() {}
	
	// MARK: - Helper Registration
	
	/// Verifies that the install helper is registered and approved.
	static func verifyAvailability() throws(InstallHelperError) {
		switch helperService.status {
		case .notFound, .notRegistered:
			throw InstallHelperError.installHelperNotRegistered
		case .requiresApproval:
			throw InstallHelperError.installHelperRequiresApproval
		case .enabled:
			return
		@unknown default:
			fatalError("Unhandled SMAppService.Status case")
		}
	}
	
	/// Registers the helper or opens System Settings if approval is required.
	static func installHelper() throws {
		let service = helperService
		switch service.status {
		case .notFound, .notRegistered:
			try service.register()
		case .requiresApproval:
			SMAppService.openSystemSettingsLoginItems()
		case .enabled:
			break
		@unknown default:
			break
		}
	}
	
	private static var helperService: SMAppService {
		SMAppService.daemon(plistName: installHelperName + ".plist")
	}
	
	/// Re-registers the helper to ensure it is available for use.
	private func ensureAvailability() async throws {
		try Self.verifyAvailability()

		// Q5: The unregister → sleep → register cycle tears down a working daemon and adds
		// latency to every install. It only exists because a helper reported `.enabled` can
		// still be unresponsive. So probe first: if the daemon answers a lightweight liveness
		// check, it is genuinely working and we skip the disruptive re-registration entirely.
		// Only when the probe fails do we fall back to the full recycle.
		if await isHelperResponsive() {
			return
		}

		let service = Self.helperService
		try await service.unregister()
		try await Task.sleep(for: .seconds(0.5))
		try service.register()
	}

	/// Sends a bounded liveness probe to the daemon. Returns `true` only if the daemon replies
	/// before the timeout; any error, missing proxy, or timeout returns `false` so the caller
	/// falls back to re-registration.
	private func isHelperResponsive() async -> Bool {
		let connection = NSXPCConnection(machServiceName: Self.installHelperName)
		connection.remoteObjectInterface = NSXPCInterface(with: UpdateInstallerProtocol.self)
		connection.activate()
		defer { connection.invalidate() }

		return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
			// Once-guard: exactly one resume across the reply, the error handler, and the timeout.
			let resumed = OSAllocatedUnfairLock(initialState: false)
			func resumeOnce(with value: Bool) {
				let shouldResume = resumed.withLock { flag -> Bool in
					guard !flag else { return false }
					flag = true
					return true
				}
				if shouldResume { continuation.resume(returning: value) }
			}

			guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
				resumeOnce(with: false)
			}) as? UpdateInstallerProtocol else {
				resumeOnce(with: false)
				return
			}

			proxy.ping {
				resumeOnce(with: true)
			}

			// Bound the wait: an unresponsive-but-registered daemon must not hang the probe.
			Task {
				try? await Task.sleep(for: .seconds(2))
				resumeOnce(with: false)
			}
		}
	}
	
	// MARK: - Package Installation
	
	/// Installs an App Store update package via the privileged helper.
	///
	/// The package is passed as an open file handle rather than a path (C6): the helper reads
	/// the exact bytes the caller opened, copies them into a root-owned location, and verifies
	/// the signature there, so the file cannot be swapped between check and use. The install
	/// target is fixed to the boot volume server-side.
	func installPackage(fileHandle: FileHandle, receiptData: Data, receiptURL: URL) async throws {
		try await ensureAvailability()
		
		let connection = NSXPCConnection(machServiceName: Self.installHelperName)
		connection.remoteObjectInterface = NSXPCInterface(with: UpdateInstallerProtocol.self)
		
		connection.activate()
		defer { connection.invalidate() }
		
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			// Once-guard: exactly one resume no matter which callback fires first,
			// and a no-op for any later interruption/invalidation callbacks.
			let resumed = OSAllocatedUnfairLock(initialState: false)
			func resumeOnce(with result: Result<Void, Error>) {
				let shouldResume = resumed.withLock { flag -> Bool in
					guard !flag else { return false }
					flag = true
					return true
				}
				if shouldResume { continuation.resume(with: result) }
			}
			
			// The error-handler proxy is invoked for both interruption and invalidation,
			// including invalidation that occurred before this message was sent, with the
			// guarantee that exactly one of {reply block, error handler} runs per message.
			guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
				resumeOnce(with: .failure(LatestError.installHelperCommunicationFailed))
			}) as? UpdateInstallerProtocol else {
				resumeOnce(with: .failure(LatestError.installHelperCommunicationFailed))
				return
			}
			
			proxy.performInstallation(ofPackageFileHandle: fileHandle, receiptData: receiptData, receiptURL: receiptURL) { error in
				if let error {
					resumeOnce(with: .failure(error))
				} else {
					resumeOnce(with: .success(()))
				}
			}
		}
	}
}

// MARK: - InstallHelperError

/// Errors related to install helper availability.
enum InstallHelperError: LocalizedError {
	case installHelperNotRegistered
	case installHelperRequiresApproval
	
	var errorDescription: String? {
		switch self {
		case .installHelperNotRegistered:
			return NSLocalizedString("InstallHelperNotFoundErrorDescription",
									 comment: "Shown when the update helper is not installed.")
		case .installHelperRequiresApproval:
			return NSLocalizedString("InstallHelperRequiresApprovalErrorDescription",
									 comment: "Shown when the update helper is installed but disabled, requiring approval.")
		}
	}
}

