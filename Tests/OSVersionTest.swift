//
//  VersionTest.swift
//  Latest Tests
//
//  Created by Max Langer on 14.11.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import XCTest
@testable import Latest

class OSVersionTest: XCTestCase {
	
	func testGenericOSVersion() throws {
		let version = try OperatingSystemVersion(string: "11.2.3")
		XCTAssertEqual(version.majorVersion, 11)
		XCTAssertEqual(version.minorVersion, 2)
		XCTAssertEqual(version.patchVersion, 3)
	}
	
	func testOnlyMajorOSVersion() throws {
		let version = try OperatingSystemVersion(string: "11.0")
		XCTAssertEqual(version.majorVersion, 11)
		XCTAssertEqual(version.minorVersion, 0)
		XCTAssertEqual(version.patchVersion, 0)
	}
	
	func testFourComponentOSVersion() throws {
		let version = try OperatingSystemVersion(string: "11.2.3.1")
		XCTAssertEqual(version.majorVersion, 11)
		XCTAssertEqual(version.minorVersion, 2)
		XCTAssertEqual(version.patchVersion, 3)
	}

	
	func testInvalidOSVersion() throws {
		XCTAssertThrowsError(try OperatingSystemVersion(string: ""))
		XCTAssertThrowsError(try OperatingSystemVersion(string: "Version"))
	}
	
	func testOperatingSystemVersionComparison() {
		let v14_8_1 = OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 1)
		let v14_8_2 = OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 2)
		let v15_0_0 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
		
		XCTAssertTrue(v14_8_1 < v14_8_2)
		XCTAssertTrue(v14_8_2 >= v14_8_1)
		XCTAssertTrue(v14_8_2 < v15_0_0)
		XCTAssertFalse(v15_0_0 < v14_8_2)
	}
	
	func testRequiresExternalUpdateWorkaround() {
		// macOS 13 (Ventura)
		XCTAssertFalse(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0)))
		
		// macOS 14 (Sonoma)
		XCTAssertFalse(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 1)))
		XCTAssertTrue(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 2)))
		XCTAssertTrue(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 14, minorVersion: 9, patchVersion: 0)))
		
		// macOS 15 (Sequoia)
		XCTAssertFalse(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 1)))
		XCTAssertTrue(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 2)))
		XCTAssertTrue(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 15, minorVersion: 8, patchVersion: 0)))
		
		// macOS 26+
		XCTAssertFalse(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
		XCTAssertTrue(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)))
		XCTAssertTrue(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)))
		XCTAssertTrue(AppStoreUpdateCheckerOperation.requiresExternalUpdateWorkaround(for: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)))
	}
	
}
