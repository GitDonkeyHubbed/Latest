//
//  Installer.swift
//  Installer
//
//  Created by Max Langer on 06.01.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//

import Foundation

/// Errors raised by the privileged helper when a request fails its server-side checks.
enum UpdateInstallerError: LocalizedError {
	case packageSignatureInvalid
	case invalidReceiptPath
	case packageStagingFailed

	var errorDescription: String? {
		switch self {
		case .packageSignatureInvalid:
			return "The update package is not signed by a certificate trusted by macOS and was rejected."
		case .invalidReceiptPath:
			return "The receipt destination is not a valid Mac App Store receipt path and was rejected."
		case .packageStagingFailed:
			return "The update package could not be staged in a protected location and was rejected."
		}
	}
}

/// The implementation of the install helper.
class UpdateInstaller: NSObject, UpdateInstallerProtocol {

	/// The install target is hard-coded server-side. App Store package updates must only ever
	/// be applied to the boot volume; there is no client-supplied target, so a compromised or
	/// spoofed client cannot redirect `installer` to another location.
	private static let installTarget = "/"

	func ping(reply: @escaping () -> Void) {
		reply()
	}

	func performInstallation(ofPackageFileHandle fileHandle: FileHandle, receiptData: Data, receiptURL: URL, reply: @escaping ((any Error)?) -> Void) {
		do {
			// Validate the receipt destination before doing anything as root (shape + prefix).
			let validatedReceiptURL = try Self.validatedReceiptURL(receiptURL)

			// C6: copy the package out of the caller-provided file descriptor into a root-owned,
			// non-user-writable staging directory. Reading the fd — not a re-openable path — and
			// then only ever touching the root-owned copy removes the swap window between the
			// signature check and the install: no non-root user can alter the staged file.
			let (stagingDirectory, packageURL) = try Self.stageRootOwnedPackage(from: fileHandle)
			defer { try? FileManager.default.removeItem(at: stagingDirectory) }
			let packagePath = packageURL.path(percentEncoded: false)

			// Verify the signature on the root-owned copy that no non-root user can alter.
			try verifyPackageSignature(atPath: packagePath)

			// Install from the verified, root-owned copy. Target is hard-coded server-side.
			let (success, output) = try performCommand("/usr/sbin/installer", arguments: ["-pkg", packagePath, "-target", Self.installTarget])
			guard success else {
				reply(NSError(domain: "LatestInstallerErrorDomain", code: 0, userInfo: [NSLocalizedDescriptionKey: output]))
				return
			}

			// C7: write the receipt without following a symlink at any path component, so a
			// symlinked ancestor cannot redirect this root write outside the app bundle.
			try Self.secureWriteReceipt(receiptData, to: validatedReceiptURL)
		} catch {
			reply(error)
			return
		}

		// Install successful
		reply(nil)
	}

	// MARK: - Server-side validation

	/// Verifies that the package at `path` carries a signature that validates against a
	/// certificate trusted by macOS. `pkgutil --check-signature` exits non-zero for unsigned
	/// or tampered packages. The path is passed as an argv element (no shell), so a crafted
	/// filename cannot inject arguments.
	private func verifyPackageSignature(atPath path: String) throws {
		let (signed, output) = try performCommand("/usr/sbin/pkgutil", arguments: ["--check-signature", path])
		guard signed, !output.localizedCaseInsensitiveContains("no signature") else {
			throw UpdateInstallerError.packageSignatureInvalid
		}
	}

	/// Validates that `receiptURL` is a legitimate Mac App Store receipt destination:
	/// an absolute path under `/Applications`, shaped as `.../Contents/_MASReceipt/receipt`,
	/// with no `..` traversal and no symlinked ancestor that redirects the resolved path out
	/// of `/Applications`. Returns the standardized URL to use for the write.
	private static func validatedReceiptURL(_ receiptURL: URL) throws -> URL {
		let standardized = receiptURL.standardizedFileURL
		let path = standardized.path(percentEncoded: false)

		guard path.hasPrefix("/"),
			  !standardized.pathComponents.contains(".."),
			  path.hasPrefix("/Applications/"),
			  path.hasSuffix("/Contents/_MASReceipt/receipt") else {
			throw UpdateInstallerError.invalidReceiptPath
		}

		// Reject symlink redirection of any existing ancestor: the resolved path must still
		// live under /Applications. The write itself is additionally hardened per-component
		// with O_NOFOLLOW in `secureWriteReceipt`.
		let resolved = standardized.resolvingSymlinksInPath().path(percentEncoded: false)
		guard resolved.hasPrefix("/Applications/") else {
			throw UpdateInstallerError.invalidReceiptPath
		}

		return standardized
	}

	// MARK: - Root-owned staging (C6)

	/// Copies the bytes behind `fileHandle` into a freshly created, root-owned staging
	/// directory (mode 0700, owner root:wheel) and returns both the directory (for cleanup)
	/// and the staged package URL. Because the source is an already-open descriptor rather
	/// than a path the caller can re-point, and the destination is unreadable and unwritable
	/// to every non-root user, the staged copy cannot be swapped after this returns.
	private static func stageRootOwnedPackage(from fileHandle: FileHandle) throws -> (directory: URL, package: URL) {
		let fileManager = FileManager.default

		// The root process's temporary directory is itself root-owned and mode 0700.
		let directory = fileManager.temporaryDirectory.appendingPathComponent("com.max-langer.latest.staging-" + UUID().uuidString, isDirectory: true)
		do {
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o700])
		} catch {
			throw UpdateInstallerError.packageStagingFailed
		}

		let packageURL = directory.appendingPathComponent("update.pkg", isDirectory: false)
		guard fileManager.createFile(atPath: packageURL.path(percentEncoded: false), contents: nil, attributes: [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o600]) else {
			try? fileManager.removeItem(at: directory)
			throw UpdateInstallerError.packageStagingFailed
		}

		do {
			let output = try FileHandle(forWritingTo: packageURL)
			defer { try? output.close() }
			try? fileHandle.seek(toOffset: 0)
			while true {
				let chunk = fileHandle.readData(ofLength: 4 * 1024 * 1024)
				if chunk.isEmpty { break }
				try output.write(contentsOf: chunk)
			}
		} catch {
			try? fileManager.removeItem(at: directory)
			throw UpdateInstallerError.packageStagingFailed
		}

		return (directory, packageURL)
	}

	// MARK: - Symlink-safe receipt write (C7)

	/// Writes `data` to the receipt path, descending from `/` one component at a time and
	/// refusing to traverse any symlink (`O_NOFOLLOW` per level). Only the trailing bundle
	/// directories (`Contents`, `_MASReceipt`) are created if missing, mirroring the previous
	/// intermediate-directory behavior. A symlink planted at any component fails the open and
	/// the write is rejected rather than redirected.
	private static func secureWriteReceipt(_ data: Data, to receiptURL: URL) throws {
		let components = receiptURL.pathComponents
		guard components.first == "/", components.count >= 3 else {
			throw UpdateInstallerError.invalidReceiptPath
		}

		let directoryComponents = Array(components.dropFirst().dropLast())
		let fileName = components[components.count - 1]

		// Number of trailing directory components allowed to be created if missing.
		let creatableSuffix = 2

		var parentFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		guard parentFD >= 0 else { throw UpdateInstallerError.invalidReceiptPath }

		for (index, component) in directoryComponents.enumerated() {
			var childFD = component.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
			if childFD < 0 && errno == ENOENT && index >= directoryComponents.count - creatableSuffix {
				let made = component.withCString { mkdirat(parentFD, $0, 0o755) }
				if made == 0 {
					childFD = component.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
					if childFD >= 0 {
						_ = fchown(childFD, 0, 0)
						_ = fchmod(childFD, 0o755)
					}
				}
			}
			guard childFD >= 0 else {
				close(parentFD)
				throw UpdateInstallerError.invalidReceiptPath
			}
			close(parentFD)
			parentFD = childFD
		}

		// `parentFD` is now the real `_MASReceipt` directory with no symlinked ancestor.
		let fileFD = fileName.withCString { openat(parentFD, $0, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o755) }
		close(parentFD)
		guard fileFD >= 0 else { throw UpdateInstallerError.invalidReceiptPath }
		defer { close(fileFD) }

		try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			guard let base = raw.baseAddress else { return }
			var offset = 0
			while offset < raw.count {
				let written = write(fileFD, base.advanced(by: offset), raw.count - offset)
				if written < 0 {
					if errno == EINTR { continue }
					throw UpdateInstallerError.invalidReceiptPath
				}
				offset += written
			}
		}

		_ = fchown(fileFD, 0, 0)
		_ = fchmod(fileFD, 0o755)
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
