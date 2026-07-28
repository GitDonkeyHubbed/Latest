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
		
		let service = Self.helperService
		
		// Services may be unreliable even though reported as enabled, so always re-register to ensure they are working
		try await service.unregister()
		try await Task.sleep(for: .seconds(0.5))
		
		try service.register()
	}
	
	// MARK: - Package Installation
	
	/// Installs an App Store update package at the given target URL via the privileged helper.
	func installPackage(at url: URL, targetURL: String, receiptData: Data, receiptURL: URL) async throws {
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
			
			proxy.performInstallation(ofPackageAt: url, targetURL: targetURL, receiptData: receiptData, receiptURL: receiptURL) { error in
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

