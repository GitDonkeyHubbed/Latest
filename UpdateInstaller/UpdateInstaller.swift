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
			return "The update package is not signed by Apple's Mac App Store package signing identity and was rejected."
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
			// A Swift `LocalizedError` bridges to an NSError whose description is provided lazily
			// in-process only; it is lost when the error is encoded over XPC. Send the message
			// eagerly so the app can show why the request was rejected.
			reply(NSError(domain: "LatestInstallerErrorDomain", code: 0, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]))
			return
		}

		// Install successful
		reply(nil)
	}

	// MARK: - Server-side validation

	/// Verifies that the package at `path` is signed by Apple itself, as App Store downloads are.
	/// `pkgutil --check-signature` exits non-zero for unsigned or tampered packages, but it exits
	/// zero for any Developer ID–signed package too, so the reported chain must additionally be
	/// Apple's own. The path is passed as an argv element (no shell), so a crafted filename cannot
	/// inject arguments, and it is our fixed staging name, so it cannot inject chain-like output.
	private func verifyPackageSignature(atPath path: String) throws {
		// Unlocalized labels: the parser below matches pkgutil's English output.
		let (signed, output) = try performCommand("/usr/sbin/pkgutil", arguments: ["--check-signature", path], environment: ["LANG": "C", "LC_ALL": "C"])
		guard signed, !output.localizedCaseInsensitiveContains("no signature"), Self.isAppleOwnedSignature(pkgutilOutput: output) else {
			throw UpdateInstallerError.packageSignatureInvalid
		}
	}

	// MARK: - Apple package signature pinning

	/// SHA-256 of "Apple Root CA", as listed by
	/// `security find-certificate -c "Apple Root CA" -Z /System/Library/Keychains/SystemRootCertificates.keychain`.
	private static let appleRootCAFingerprint = "B0B1730ECBC7FF4505142C49F1295E6EDA6BCAED7E2C68C5BE91B5A11001F024"

	/// Leaf identities Apple signs App Store content with. Apple's CAs issue every third-party
	/// certificate with a typed, team-suffixed name ("Developer ID Installer: Name (TEAMID)",
	/// "3rd Party Mac Developer Installer: …"), so no one but Apple can hold a leaf with one of
	/// these exact names under Apple Root CA.
	/// - "Apple Mac OS Installer Package Signing" signs the packages appstoreagent downloads
	///   (pkgutil status "signed by Apple for the App Store").
	/// - "Apple Mac OS Application Signing" is the identity Apple re-signs App Store app bundles
	///   with; accepted in case a package is signed by it as well.
	private static let appleSigningIdentities: Set<String> = [
		"Apple Mac OS Installer Package Signing",
		"Apple Mac OS Application Signing"
	]

	/// A certificate as listed in the "Certificate Chain:" section of `pkgutil --check-signature`.
	private struct ListedCertificate {
		let name: String
		let sha256Fingerprint: String
	}

	/// Whether `pkgutil --check-signature` output (run with `LANG=C`) reports a chain whose leaf is
	/// one of Apple's own signing identities and whose anchor is Apple Root CA. Fails closed:
	/// anything missing, malformed or out of order is rejected.
	static func isAppleOwnedSignature(pkgutilOutput output: String) -> Bool {
		guard let chain = certificateChain(fromPkgutilOutput: output), chain.count >= 2,
			  let leaf = chain.first, let anchor = chain.last else {
			return false
		}
		return appleSigningIdentities.contains(leaf.name) && anchor.sha256Fingerprint == appleRootCAFingerprint
	}

	/// Parses the numbered entries following "Certificate Chain:". Every entry must be numbered
	/// in sequence from 1 and carry a complete SHA-256 fingerprint; otherwise returns `nil`.
	private static func certificateChain(fromPkgutilOutput output: String) -> [ListedCertificate]? {
		let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
		guard let header = lines.firstIndex(where: { $0.caseInsensitiveCompare("Certificate Chain:") == .orderedSame }) else {
			return nil
		}

		var entries: [(name: String, lines: [String])] = []
		for line in lines[(header + 1)...] {
			if let entry = numberedEntry(line) {
				guard entry.position == entries.count + 1 else { return nil }
				entries.append((entry.name, []))
			} else if !entries.isEmpty {
				entries[entries.count - 1].lines.append(line)
			} else if !line.isEmpty {
				return nil
			}
		}

		let chain = entries.compactMap { entry in
			sha256Fingerprint(in: entry.lines).map { ListedCertificate(name: entry.name, sha256Fingerprint: $0) }
		}
		guard !chain.isEmpty, chain.count == entries.count else { return nil }
		return chain
	}

	/// Splits an entry header such as "1. Apple Root CA" into its position and certificate name.
	private static func numberedEntry(_ line: String) -> (position: Int, name: String)? {
		guard let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy({ $0.isASCII && $0.isNumber }),
			  let position = Int(line[..<dot]), position > 0 else {
			return nil
		}
		let name = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
		return name.isEmpty ? nil : (position, name)
	}

	/// Reads the hex bytes after "SHA256 Fingerprint:", which pkgutil wraps across lines, and
	/// returns them as 64 uppercase hex digits without separators.
	private static func sha256Fingerprint(in lines: [String]) -> String? {
		let label = "sha256 fingerprint:"
		guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(label) }) else { return nil }

		let isHexDigit: (Character) -> Bool = { $0.isASCII && $0.isHexDigit }
		var digits = String(lines[start].dropFirst(label.count))
		for line in lines[(start + 1)...] {
			guard !line.isEmpty, line.allSatisfy({ isHexDigit($0) || $0 == " " }) else { break }
			digits += line
		}

		let fingerprint = digits.filter { !$0.isWhitespace }.uppercased()
		guard fingerprint.count == 64, fingerprint.allSatisfy(isHexDigit) else { return nil }
		return fingerprint
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
			try fileManager.createDirectory(
				at: directory,
				withIntermediateDirectories: false,
				attributes: [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o700]
			)
		} catch {
			throw UpdateInstallerError.packageStagingFailed
		}

		let packageURL = directory.appendingPathComponent("update.pkg", isDirectory: false)
		guard fileManager.createFile(
			atPath: packageURL.path(percentEncoded: false),
			contents: nil,
			attributes: [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o600]
		) else {
			try? fileManager.removeItem(at: directory)
			throw UpdateInstallerError.packageStagingFailed
		}

		do {
			let output = try FileHandle(forWritingTo: packageURL)
			defer { try? output.close() }
			try? fileHandle.seek(toOffset: 0)
			// `read(upToCount:)` throws on I/O errors; the legacy `readData(ofLength:)` raises an
			// Objective-C exception instead, which would abort the daemon.
			while let chunk = try fileHandle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
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
	/// the write is rejected rather than redirected. The receipt is replaced atomically, so a
	/// failed write leaves any existing receipt in place.
	private static func secureWriteReceipt(_ data: Data, to receiptURL: URL) throws {
		let components = receiptURL.pathComponents
		guard components.first == "/", components.count >= 3 else {
			throw UpdateInstallerError.invalidReceiptPath
		}

		let directoryComponents = Array(components.dropFirst().dropLast())
		let fileName = components[components.count - 1]

		let parentFD = try openReceiptDirectory(directoryComponents)
		defer { close(parentFD) }

		// `parentFD` is now the real `_MASReceipt` directory with no symlinked ancestor.
		// O_NOFOLLOW does not stop hard links: writing to an existing entry in place could overwrite
		// (and later re-own and chmod) any root file it is linked to. Write an exclusively created
		// temporary file instead and rename it over the receipt, which replaces the directory entry
		// itself and keeps the old receipt intact until its replacement is complete.
		let temporaryName = ".\(fileName).\(UUID().uuidString)"
		let fileFD = temporaryName.withCString { openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o755) }
		guard fileFD >= 0 else { throw UpdateInstallerError.invalidReceiptPath }

		do {
			defer { close(fileFD) }
			try writeAll(data, to: fileFD)
			_ = fchown(fileFD, 0, 0)
			_ = fchmod(fileFD, 0o755)
			guard fsync(fileFD) == 0 else { throw UpdateInstallerError.invalidReceiptPath }
		} catch {
			_ = temporaryName.withCString { unlinkat(parentFD, $0, 0) }
			throw error
		}

		let renamed = temporaryName.withCString { temporary in
			fileName.withCString { renameat(parentFD, temporary, parentFD, $0) }
		}
		guard renamed == 0 else {
			_ = temporaryName.withCString { unlinkat(parentFD, $0, 0) }
			throw UpdateInstallerError.invalidReceiptPath
		}
	}

	/// Writes all of `data` to `fileDescriptor`, retrying interrupted and partial writes.
	private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
		try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			guard let base = raw.baseAddress else { return }
			var offset = 0
			while offset < raw.count {
				let written = write(fileDescriptor, base.advanced(by: offset), raw.count - offset)
				if written < 0 {
					if errno == EINTR { continue }
					throw UpdateInstallerError.invalidReceiptPath
				}
				offset += written
			}
		}
	}

	/// Descends from `/` through `directoryComponents` one component at a time with
	/// `O_NOFOLLOW` per level, creating only the trailing bundle directories if missing.
	/// Returns an open descriptor for the final directory; the caller owns and must close it.
	/// Every intermediate descriptor is closed on all paths, including when this throws.
	private static func openReceiptDirectory(_ directoryComponents: [String]) throws -> Int32 {
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

		return parentFD
	}

	private func performCommand(_ executablePath: String, arguments: [String], environment: [String: String] = [:]) throws -> (success: Bool, output: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executablePath)
		process.arguments = arguments
		if !environment.isEmpty {
			process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
		}

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
