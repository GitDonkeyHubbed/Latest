//
//  HomebrewInstallation.swift
//  Latest
//
//  Copyright © 2026 Max Langer. All rights reserved.
//

import Foundation

/// Locates the local Homebrew installation.
///
/// Latest only performs cask upgrades directly when Homebrew is actually installed and the
/// matched cask is present in the local Caskroom. Both checks are cheap file system probes;
/// no processes are spawned.
enum HomebrewInstallation {

	/// The URL of the `brew` executable, or `nil` if Homebrew is not installed.
	static var brewURL: URL? {
		var candidates = [String]()

		// Respect custom installation locations first.
		if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
			candidates.append((prefix as NSString).appendingPathComponent("bin/brew"))
		}

		candidates.append(contentsOf: [
			// Apple Silicon
			"/opt/homebrew/bin/brew",
			// Intel
			"/usr/local/bin/brew"
		])

		for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
			return URL(fileURLWithPath: path)
		}

		return nil
	}

	/// Whether the cask with the given token was installed through the Homebrew installation at the given location.
	///
	/// Checks for the cask's directory in the Caskroom; matching an app to a cask by name alone
	/// does not mean the app was actually installed through Homebrew.
	static func isCaskInstalled(_ token: String, brewURL: URL) -> Bool {
		// <prefix>/bin/brew -> <prefix>/Caskroom/<token>
		let caskURL = brewURL
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Caskroom")
			.appendingPathComponent(token)

		var isDirectory: ObjCBool = false
		return FileManager.default.fileExists(atPath: caskURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
	}

}
