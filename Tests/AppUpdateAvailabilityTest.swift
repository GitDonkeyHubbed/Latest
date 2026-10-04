//
//  AppUpdateAvailabilityTest.swift
//  Latest Tests
//
//  Copyright © 2026 Max Langer. All rights reserved.
//

import XCTest
@testable import Latest

/// Regression tests for apps that stayed in Available Updates after an install.
class AppUpdateAvailabilityTest: XCTestCase {

	func testReplacedBundleClearsUpdateAvailable() {
		let url = URL(fileURLWithPath: "/Applications/Linger.app")
		let oldBundle = Self.bundle(version: "1.0.0", build: "1", url: url)
		let update = Self.update(for: oldBundle, remoteVersion: "2.0.0", remoteBuild: "2")
		let app = App(bundle: oldBundle, update: .success(update), isIgnored: false)

		XCTAssertTrue(app.updateAvailable)

		let installed = app.with(bundle: Self.bundle(version: "2.0.0", build: "2", url: url))
		XCTAssertFalse(installed.updateAvailable, "A successful install must drop the app from Available Updates even before a new remote check.")
	}

	func testStoreDropsUpdatableAppAfterBundleReplacement() {
		let store = AppDataStore()
		let url = URL(fileURLWithPath: "/Applications/Linger.app")
		let oldBundle = Self.bundle(version: "1.0.0", build: "1", url: url)

		_ = store.set(appBundles: [oldBundle])
		_ = store.set(.success(Self.update(for: oldBundle, remoteVersion: "2.0.0", remoteBuild: "2")), for: oldBundle)
		XCTAssertEqual(store.updatableApps.count, 1)

		let newBundle = Self.bundle(version: "2.0.0", build: "2", url: url)
		_ = store.set(appBundles: [newBundle])
		XCTAssertEqual(store.updatableApps.count, 0, "Replacing the on-disk bundle with the advertised version must clear the update list.")
	}

	func testCollectBundlesSeesUpdatedInfoPlist() throws {
		let fileManager = FileManager.default
		let root = fileManager.temporaryDirectory.appendingPathComponent("LatestBundleCollector-\(UUID().uuidString)", isDirectory: true)
		let appURL = root.appendingPathComponent("Linger.app")
		let contentsURL = appURL.appendingPathComponent("Contents")
		let macosURL = contentsURL.appendingPathComponent("MacOS")
		try fileManager.createDirectory(at: macosURL, withIntermediateDirectories: true)
		fileManager.createFile(atPath: macosURL.appendingPathComponent("Linger").path, contents: Data())
		defer { try? fileManager.removeItem(at: root) }

		try Self.writeInfoPlist(at: contentsURL, version: "1.0.0", build: "1")
		let first = BundleCollector.collectBundles(at: root)
		XCTAssertEqual(first.count, 1)
		XCTAssertEqual(first.first?.version.versionNumber, "1.0.0")

		try Self.writeInfoPlist(at: contentsURL, version: "2.0.0", build: "2")
		let second = BundleCollector.collectBundles(at: root)
		XCTAssertEqual(second.count, 1)
		XCTAssertEqual(second.first?.version.versionNumber, "2.0.0", "A second scan must not keep the cached pre-update version.")
		XCTAssertEqual(second.first?.version.buildNumber, "2")
	}

	// MARK: - Helpers

	private static func bundle(version: String, build: String, url: URL) -> App.Bundle {
		App.Bundle(version: Version(versionNumber: version, buildNumber: build), name: "Linger",
				   bundleIdentifier: "com.test.linger", fileURL: url, source: .sparkle)
	}

	private static func update(for bundle: App.Bundle, remoteVersion: String, remoteBuild: String) -> App.Update {
		App.Update(app: bundle, remoteVersion: Version(versionNumber: remoteVersion, buildNumber: remoteBuild), minimumOSVersion: nil,
				   source: .sparkle, date: nil, releaseNotes: nil, updateAction: .builtIn(block: { _ in }))
	}

	private static func writeInfoPlist(at contentsURL: URL, version: String, build: String) throws {
		let info: [String: Any] = [
			"CFBundleIdentifier": "com.test.linger",
			"CFBundleName": "Linger",
			"CFBundleDisplayName": "Linger",
			"CFBundleShortVersionString": version,
			"CFBundleVersion": build,
			"CFBundleExecutable": "Linger",
			"CFBundlePackageType": "APPL"
		]
		let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
		try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
	}

}
