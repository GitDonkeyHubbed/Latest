//
//  Installer.swift
//  Installer
//
//  Created by Max Langer on 06.01.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//

import Foundation

/// The implementation of the install helper.
class UpdateInstaller: NSObject, UpdateInstallerProtocol {
	func performInstallation(ofPackageAt url: URL, targetURL: String, receiptData: Data, receiptURL: URL, reply: @escaping ((any Error)?) -> Void) {
		do {
			// Install app
			let path = url.path(percentEncoded: false)
			let (success, output) = try performCommand("/usr/sbin/installer", arguments: ["-pkg", path, "-target", targetURL])
			guard success else {
				reply(NSError(domain: "LatestInstallerErrorDomain", code: 0, userInfo: [NSLocalizedDescriptionKey: output]))
				return
			}
			
			// Insert receipt
			let fileManager = FileManager.default
			let attributes: [FileAttributeKey: Any] = [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755]
			
			if fileManager.fileExists(atPath: receiptURL.path(percentEncoded: false)) {
				try fileManager.removeItem(at: receiptURL)
			} else {
				try fileManager.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: attributes)
			}
			
			try receiptData.write(to: receiptURL, options: .atomic)
			try fileManager.setAttributes(attributes, ofItemAtPath: receiptURL.path(percentEncoded: false))
		} catch {
			reply(error)
			return
		}
		
		// Cleanup
		let directory = url.deletingLastPathComponent()
		try? FileManager.default.removeItem(at: directory)
		
		// Install successful
		reply(nil)
	}
	
	private func performCommand(_ executablePath: String, arguments: [String]) throws -> (success: Bool, output: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executablePath)
		process.arguments = arguments
		
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		
		try process.run()
		
		// Drain the pipe before waiting, otherwise the child deadlocks against
		// a full pipe buffer once its output exceeds the buffer's capacity.
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let success = (process.terminationStatus == 0)
		
		return (success, output)
	}
}
