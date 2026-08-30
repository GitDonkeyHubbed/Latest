//
//  InstallerProtocol.swift
//  Installer
//
//  Created by Max Langer on 06.01.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol UpdateInstallerProtocol {
	/// Installs the Mac App Store package referenced by the given open file handle.
	///
	/// A file handle is passed instead of a path so the privileged helper reads the exact
	/// bytes the caller opened, immune to a path swap between check and use (C6). The helper
	/// copies those bytes into a root-owned directory, verifies the package signature there,
	/// installs it, and writes the receipt without following symlinks (C7). The install target
	/// is fixed to the boot volume server-side; there is no client-supplied target.
	func performInstallation(ofPackageFileHandle fileHandle: FileHandle, receiptData: Data, receiptURL: URL, reply: @escaping (Error?) -> Void)

	/// Lightweight liveness check so the app can confirm the daemon is responsive before
	/// resorting to a disruptive unregister/register cycle (Q5).
	func ping(reply: @escaping () -> Void)
}
