//
//  VersionTest.swift
//  Latest Tests
//
//  Created by Max Langer on 14.11.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import XCTest
@testable import Latest

class VersionTest: XCTestCase {

    func testInitialization() {
        // Simple test
		var version = Version(versionNumber: "2.1.5", buildNumber: "215")

        XCTAssertEqual(version.versionNumber, "2.1.5")
        XCTAssertEqual(version.buildNumber, "215")

        // Nil test
		version = Version(versionNumber: nil, buildNumber: nil)
        XCTAssertNil(version.versionNumber)
        XCTAssertNil(version.buildNumber)
    }

	func testEmptyVersion() {
		XCTAssertTrue(Version(versionNumber: nil, buildNumber: nil).isEmpty)
		XCTAssertTrue(Version(versionNumber: nil, buildNumber: "").isEmpty)
		XCTAssertTrue(Version(versionNumber: "", buildNumber: "").isEmpty)
		XCTAssertTrue(Version(versionNumber: nil, buildNumber: ".").isEmpty)
		XCTAssertTrue(Version(versionNumber: "\n", buildNumber: nil).isEmpty)

		XCTAssertFalse(Version(versionNumber: "1", buildNumber: nil).isEmpty)
		XCTAssertFalse(Version(versionNumber: nil, buildNumber: "1").isEmpty)
		XCTAssertFalse(Version(versionNumber: "1.2", buildNumber: "123").isEmpty)
	}

    // MARK: - Right Comparison

    func testRightComparison() {
        // If bundle is available, check for the bundle

        // Should check the bundle version
		var v1 = Version(versionNumber: "2.1.5", buildNumber: "312")
		var v2 = Version(versionNumber: "2.1.6d12", buildNumber: "215")
        self.newer(v1, v2)

        // Should check the version
		v1 = Version(versionNumber: "2.1.5", buildNumber: nil)
		v2 = Version(versionNumber: "2.2.6", buildNumber: "216")
        self.older(v1, v2)

        // Should check the version
		v1 = Version(versionNumber: "2.1.5", buildNumber: "215")
		v2 = Version(versionNumber: "2.2.6", buildNumber: nil)
        self.older(v1, v2)

        // Should check the version
		v1 = Version(versionNumber: "2.1.5", buildNumber: nil)
		v2 = Version(versionNumber: "2.2.6", buildNumber: nil)
        self.older(v1, v2)
    }

    // MARK: - Bundle Checking

    func testOlderBundle() {
		var v1 = Version(versionNumber: "2.1.5", buildNumber: "215")
		var v2 = Version(versionNumber: "2.1.6", buildNumber: "216")
        self.older(v1, v2)

		v1 = Version(versionNumber: "2.1.5", buildNumber: "215a")
		v2 = Version(versionNumber: "2.2.6", buildNumber: "216b")
        self.older(v1, v2)
    }

    func testEqualBundle() {
		let v1 = Version(versionNumber: "2.1.5", buildNumber: "215")
		let v2 = Version(versionNumber: "2.1.5", buildNumber: "215")
        self.equal(v1, v2)
    }

    func testNewerBundle() {
		var v1 = Version(versionNumber: "2.0.6", buildNumber: "217")
		var v2 = Version(versionNumber: "2.1.5", buildNumber: "216")
        self.newer(v1, v2)

		v1 = Version(versionNumber: "2.1.6", buildNumber: "217a")
		v2 = Version(versionNumber: "2.2.4", buildNumber: "216b")
        self.newer(v1, v2)
    }

    // MARK: - Version Checking

    func testOlderVersionSimple() {
		var v1 = Version(versionNumber: "2.1.5", buildNumber: nil)
		var v2 = Version(versionNumber: "2.1.6", buildNumber: "216")
        self.older(v1, v2)

		v1 = Version(versionNumber: "2.1.5", buildNumber: "215")
		v2 = Version(versionNumber: "2.2.6", buildNumber: nil)
        self.older(v1, v2)

		v1 = Version(versionNumber: "2.1.5", buildNumber: nil)
		v2 = Version(versionNumber: "3.1.6", buildNumber: nil)
        self.older(v1, v2)
    }

    func testEqualVersionSimple() {
		var v1 = Version(versionNumber: "2.1.5", buildNumber: nil)
		var v2 = Version(versionNumber: "2.1.5", buildNumber: "215")
        self.equal(v1, v2)

		v1 = Version(versionNumber: "2.2.6", buildNumber: "215")
		v2 = Version(versionNumber: "2.2.6", buildNumber: nil)
        self.equal(v1, v2)

		v1 = Version(versionNumber: "3.1.6", buildNumber: nil)
		v2 = Version(versionNumber: "3.1.6", buildNumber: nil)
        self.equal(v1, v2)
    }

    func testNewerVersionSimple() {
		var v1 = Version(versionNumber: "2.1.6", buildNumber: nil)
		var v2 = Version(versionNumber: "2.1.5", buildNumber: "216")
        self.newer(v1, v2)

		v1 = Version(versionNumber: "2.3.6", buildNumber: "215")
		v2 = Version(versionNumber: "2.2.4", buildNumber: nil)
        self.newer(v1, v2)

		v1 = Version(versionNumber: "4.1.5", buildNumber: nil)
		v2 = Version(versionNumber: "3.1.6", buildNumber: nil)
        self.newer(v1, v2)
    }

    func testOlderVersion() {
		let v1 = Version(versionNumber: "2.1.5", buildNumber: nil)
		let v2 = Version(versionNumber: "2.1.6", buildNumber: "216")
        self.older(v1, v2)
    }

    func testEqualVersion() {
		var v1 = Version(versionNumber: "2.1.5", buildNumber: nil)
		var v2 = Version(versionNumber: "2.1.5.0", buildNumber: "215")
        self.equal(v1, v2)

		v1 = Version(versionNumber: "2.2.6.0", buildNumber: "215")
		v2 = Version(versionNumber: "2.2.6", buildNumber: nil)
        self.equal(v1, v2)

		v1 = Version(versionNumber: "2.2.6", buildNumber: nil)
		v2 = Version(versionNumber: "2.2.6", buildNumber: nil)
        self.equal(v1, v2)
    }

    func testNewerVersion() {
		var v1 = Version(versionNumber: "3.1.5", buildNumber: nil)
		var v2 = Version(versionNumber: "2.1.6", buildNumber: "216")
        self.newer(v1, v2)

		v1 = Version(versionNumber: "3.1.5", buildNumber: "215")
		v2 = Version(versionNumber: "2.2.6", buildNumber: nil)
        self.newer(v1, v2)
    }

	func testBuildMetadataIgnored() {
		// Semver build metadata ("+…") does not affect precedence. An installed
		// "3.6.1000" is the same version as a feed's "3.6.1000+next.05e2e51d52".
		var v1 = Version(versionNumber: "3.6.1000", buildNumber: nil)
		var v2 = Version(versionNumber: "3.6.1000+next.05e2e51d52", buildNumber: nil)
		self.equal(v1, v2)

		v1 = Version(versionNumber: "0.4.20+1", buildNumber: nil)
		v2 = Version(versionNumber: "0.4.20", buildNumber: "1")
		self.equal(v1, v2)

		// A real version bump still wins over any metadata.
		v1 = Version(versionNumber: "0.4.19+2", buildNumber: nil)
		v2 = Version(versionNumber: "0.4.20", buildNumber: nil)
		self.older(v1, v2)

		// Metadata on build numbers is ignored as well.
		v1 = Version(versionNumber: "2.1.5", buildNumber: "215+abc")
		v2 = Version(versionNumber: "2.1.5", buildNumber: "215")
		self.equal(v1, v2)

		// The Hashable contract: values comparing equal because metadata is
		// ignored must also hash equally.
		v1 = Version(versionNumber: "3.6.1000", buildNumber: nil)
		v2 = Version(versionNumber: "3.6.1000+next.05e2e51d52", buildNumber: nil)
		XCTAssertEqual(v1.hashValue, v2.hashValue)
		XCTAssertEqual(Set([v1, v2]).count, 1)
	}

	func testDashIsASeparator() {
		// A dash separates components; it must not be read as a minus sign.
		self.older(Version(versionNumber: "2.4.1-1", buildNumber: nil),
				   Version(versionNumber: "2.4.1-2", buildNumber: nil))
		self.newer(Version(versionNumber: "1.2-10", buildNumber: nil),
				   Version(versionNumber: "1.2-9", buildNumber: nil))
	}

	func testPreReleaseSuffix() {
		// A trailing text suffix marks a pre-release of the plain version.
		self.older(Version(versionNumber: "1.0b3", buildNumber: nil),
				   Version(versionNumber: "1.0", buildNumber: nil))
		self.newer(Version(versionNumber: "2.1", buildNumber: nil),
				   Version(versionNumber: "2.1rc1", buildNumber: nil))
		self.older(Version(versionNumber: "1.0b", buildNumber: nil),
				   Version(versionNumber: "1.0b3", buildNumber: nil))
		self.older(Version(versionNumber: "1.0b3", buildNumber: nil),
				   Version(versionNumber: "1.0b4", buildNumber: nil))
	}

	func testNumeralSystems() {
		// Western arabic numerals
		var v1 = Version(versionNumber: "3.1.5", buildNumber: nil)
		var v2 = Version(versionNumber: "2.1.6", buildNumber: "216")
		self.newer(v1, v2)

		// Eastern arabic numerals
		v1 = Version(versionNumber: "٣.١.٥", buildNumber: "٢١٥")
		v2 = Version(versionNumber: "٢.٢.٦", buildNumber: nil)
		self.newer(v1, v2)

		// Indian numerals
		v1 = Version(versionNumber: "३.१.५", buildNumber: "२१७")
		v2 = Version(versionNumber: "२.१.६", buildNumber: nil)
		self.newer(v1, v2)

		// Multi-digit numerals compare by value, not as text
		v1 = Version(versionNumber: "١٠.٠", buildNumber: nil)
		v2 = Version(versionNumber: "٩.٠", buildNumber: nil)
		self.newer(v1, v2)
	}

	func testHostileVersionStrings() {
		// Version strings with characters the scanner cannot classify must
		// never crash the comparison (the parser used to call fatalError).
		// Identical hostile strings compare equal…
		self.equal(Version(versionNumber: "1.2🚀", buildNumber: nil),
				   Version(versionNumber: "1.2🚀", buildNumber: nil))
		self.equal(Version(versionNumber: "１.２.３", buildNumber: nil),
				   Version(versionNumber: "１.２.３", buildNumber: nil))

		// …and comparisons around them stay sane where a numeric prefix exists.
		self.newer(Version(versionNumber: "3.0", buildNumber: nil),
				   Version(versionNumber: "2.0\u{01}beta", buildNumber: nil))
		self.older(Version(versionNumber: "1.9", buildNumber: nil),
				   Version(versionNumber: "2.0-🚀.5", buildNumber: nil))

		// Mixed scripts, control characters, and replacement characters parse
		// without trapping regardless of how the atoms are classified.
		_ = Version(versionNumber: "٣.١🚀.٥", buildNumber: "\u{FFFD}\u{0007}")
			== Version(versionNumber: "2.2.6", buildNumber: "٢١٧")
	}

	// MARK: - Consistency

	func testBuildNumberDecisionIsSymmetric() {
		// Only the left side used to decide whether builds are compared, so swapping the operands
		// compared different strings: versions one way ("2.1.5" > "2.1.4"), builds the other ("300" > "2.1.5").
		let v1 = Version(versionNumber: "2.1.5", buildNumber: "2.1.5")
		let v2 = Version(versionNumber: "2.1.4", buildNumber: "300")
		self.newer(v1, v2)
		self.older(v2, v1)
	}

	func testHomebrewBuildIsNotRankedAgainstNumber() {
		// Casks like "4.5.0,a1b2c3" carry a download token as build. It says nothing about precedence
		// compared to a numeric CFBundleVersion, so the version numbers decide.
		let installed = Version(versionNumber: "4.5.0", buildNumber: "450")
		self.equal(installed, VersionParser.parse(combinedVersionNumber: "4.5.0,a1b2c3"))
		self.older(installed, VersionParser.parse(combinedVersionNumber: "4.5.1,a1b2c3"))
		self.older(installed, VersionParser.parse(combinedVersionNumber: "4.5.1,4f3a2b"))
		self.newer(installed, VersionParser.parse(combinedVersionNumber: "4.4.9,9e8d7c"))

		// An app without a distinct build number is not compared against the cask's build either.
		self.equal(Version(versionNumber: "1.2.3", buildNumber: "1.2.3"), VersionParser.parse(combinedVersionNumber: "1.2.3,456"))
	}

	func testPreReleaseBuildsAreCompared() {
		// Only hash-like builds are excluded. Pre-release and Apple-style builds rank as Sparkle ranks them.
		self.older(Version(versionNumber: "3.0", buildNumber: "3.0b1"), Version(versionNumber: "3.0", buildNumber: "3.0b2"))
		self.older(Version(versionNumber: "3.0", buildNumber: "3.0b2"), Version(versionNumber: "3.0", buildNumber: "3.0"))
		self.older(Version(versionNumber: "1.0", buildNumber: "1.0rc1"), Version(versionNumber: "1.0", buildNumber: "1.0rc2"))
		self.older(Version(versionNumber: "1.0", buildNumber: "21A5248p"), Version(versionNumber: "1.0", buildNumber: "21A5300"))
	}

	func testSparkleFeedWithoutShortVersion() {
		// A Sparkle feed without a short version string repeats its build as display version. Like Sparkle,
		// compare it against the installed build, not the installed version.
		let installed = Version(versionNumber: "2.1", buildNumber: "1234")
		self.older(installed, Version(versionNumber: "1240", buildNumber: "1240"))
		self.newer(installed, Version(versionNumber: "1230", buildNumber: "1230"))
		self.older(Version(versionNumber: "2024.1", buildNumber: "500"), Version(versionNumber: "510", buildNumber: "510"))
		self.older(Version(versionNumber: "1.2.3", buildNumber: "1.2.3.4500"), Version(versionNumber: "1.2.3.4567", buildNumber: "1.2.3.4567"))

		// The feed's build may have as many components as the installed short version. Such shapes are ambiguous,
		// and builds are compared, as Sparkle does.
		self.equal(Version(versionNumber: "5", buildNumber: "523"), Version(versionNumber: "523", buildNumber: "523"))
		self.newer(Version(versionNumber: "5", buildNumber: "530"), Version(versionNumber: "523", buildNumber: "523"))
		self.newer(Version(versionNumber: "5", buildNumber: "1234"), Version(versionNumber: "1230", buildNumber: "1230"))
		self.older(Version(versionNumber: "2024", buildNumber: "500"), Version(versionNumber: "510", buildNumber: "510"))
		self.equal(Version(versionNumber: "3.1.2", buildNumber: "2023.10.05"), Version(versionNumber: "2023.10.05", buildNumber: "2023.10.05"))
		self.equal(Version(versionNumber: "1.2", buildNumber: "1.240"), Version(versionNumber: "1.240", buildNumber: "1.240"))
	}

	func testUpdateDetectionForSparkleFeedWithoutShortVersion() {
		// Sparkle hands over the latest item even if the app is up to date, so these must not show phantom updates.
		XCTAssertFalse(self.updateAvailable(installed: Version(versionNumber: "5", buildNumber: "1234"),
											remote: Version(versionNumber: "1234", buildNumber: "1234")))
		XCTAssertFalse(self.updateAvailable(installed: Version(versionNumber: "5", buildNumber: "1234"),
											remote: Version(versionNumber: "1230", buildNumber: "1230")))
		XCTAssertFalse(self.updateAvailable(installed: Version(versionNumber: "3.1.2", buildNumber: "2023.10.05"),
											remote: Version(versionNumber: "2023.10.05", buildNumber: "2023.10.05")))
		XCTAssertFalse(self.updateAvailable(installed: Version(versionNumber: "1.2", buildNumber: "1.240"),
											remote: Version(versionNumber: "1.240", buildNumber: "1.240")))

		// Real updates are found.
		XCTAssertTrue(self.updateAvailable(installed: Version(versionNumber: "2024", buildNumber: "500"),
										   remote: Version(versionNumber: "510", buildNumber: "510")))
		XCTAssertTrue(self.updateAvailable(installed: Version(versionNumber: "2.1", buildNumber: "1234"),
										   remote: Version(versionNumber: "1240", buildNumber: "1240")))

		// Sanitization moves a feed version equal to the installed build to the build number, and keeps that change.
		let bundle = self.bundle(with: Version(versionNumber: "5", buildNumber: "1234"))
		let update = self.update(for: bundle, remote: Version(versionNumber: "1234", buildNumber: "1234")).sanitized(for: bundle)
		XCTAssertNil(update.remoteVersion.versionNumber)
		XCTAssertEqual(update.remoteVersion.buildNumber, "1234")
	}

	func testComparisonIsConsistent() {
		for v1 in Self.corpus {
			XCTAssertTrue(v1 == v1, "\(v1)")

			for v2 in Self.corpus {
				let description = "\(v1) vs. \(v2)"
				XCTAssertEqual(v1 < v2, v2 > v1, description)
				XCTAssertEqual(v1 > v2, v2 < v1, description)
				XCTAssertEqual(v1 == v2, v2 == v1, description)

				// At most one relation holds. None only if the versions cannot be compared, in either direction.
				let relations = [v1 < v2, v1 == v2, v1 > v2].filter { $0 }.count
				XCTAssertLessThanOrEqual(relations, 1, description)
				if relations == 0 {
					XCTAssertFalse(v2 < v1 || v2 == v1 || v2 > v1, description)
				}
			}
		}
	}

	func testEqualVersionsHashEqually() {
		for v1 in Self.corpus {
			for v2 in Self.corpus where v1 == v2 {
				XCTAssertEqual(v1.hashValue, v2.hashValue, "\(v1) vs. \(v2)")
			}
		}

		// Equal through build numbers alone, and through trailing zeros.
		XCTAssertEqual(Set([Version(versionNumber: "1.0", buildNumber: "100"), Version(versionNumber: "2.0", buildNumber: "100")]).count, 1)
		XCTAssertEqual(Set([Version(versionNumber: "1.2", buildNumber: nil), Version(versionNumber: "1.2.0", buildNumber: nil)]).count, 1)
	}

	/// Version pairs covering the comparison paths: missing values, builds equal to their versions, numeric and
	/// textual builds, pre-releases, build metadata, separators and other numeral systems.
	private static let corpus: [Version] = {
		let pairs: [(String?, String?)] = [
			(nil, nil), (nil, ""), ("", ""), ("\n", "."), (nil, "40"), (nil, "abc"), (nil, "1.2.40"),
			("1.2", nil), ("1.2.0", nil), ("1.2.", nil), ("1.2", "1.2"), ("1.2", "40"), ("1.2.40", nil), ("40", nil),
			("2.1.5", nil), ("2.1.5", "215"), ("2.1.5", "2.1.5"), ("2.1.4", "300"), ("2.1.5.0", "215"), ("2.1.5", "312"),
			("2.1.6d12", "215"), ("2.1.5", "215a"), ("2.2.6", "216b"), ("2.1.5", "215+abc"),
			("4.5.0", "450"), ("4.5.0", "a1b2c3"), ("4.5.1", "4f3a2b"), ("4.5.0", "4.5.0"), ("1.2.3", "456"),
			("2.1", "1234"), ("1240", "1240"), ("1230", "1230"), ("1234", "1234"), ("2024.1", "500"), ("510", "510"),
			("5", "1234"), ("5", "523"), ("523", "523"), ("2024", "500"), ("121", "121"), ("121", "45678"),
			("3.0", "3.0b1"), ("3.0", "3.0b2"), ("3.0", "3.0"), ("1.0", "21A5248p"), ("1.0", "21A5300"),
			("1.0b3", nil), ("1.0", nil), ("1.0b", nil), ("2.1rc1", "2.1rc1"), ("1.0", "1.0b4"),
			("3.6.1000+next.05e2e51d52", nil), ("3.6.1000", nil), ("0.4.20+1", nil), ("0.4.20", "1"),
			("2.4.1-1", nil), ("1.2-10", "1.2-10"), ("٣.١.٥", "٢١٥"), ("२.१.६", nil), ("1.2🚀", "\u{FFFD}")
		]
		return pairs.map { Version(versionNumber: $0, buildNumber: $1) }
	}()

    // MARK: - Helper Methods

	/// Whether an update to the remote version is offered for an app at the installed version, sanitized as the app does.
	private func updateAvailable(installed: Version, remote: Version) -> Bool {
		let bundle = self.bundle(with: installed)
		return self.update(for: bundle, remote: remote).sanitized(for: bundle).updateAvailable
	}

	private func bundle(with version: Version) -> App.Bundle {
		App.Bundle(version: version, name: "Test", bundleIdentifier: "com.example.test",
				   fileURL: URL(fileURLWithPath: "/Applications/Test.app"), source: .sparkle)
	}

	private func update(for bundle: App.Bundle, remote: Version) -> App.Update {
		App.Update(app: bundle, remoteVersion: remote, minimumOSVersion: nil, source: .sparkle, date: nil, releaseNotes: nil,
				   updateAction: .builtIn(block: { _ in }))
	}

    private func older(_ v1: Version, _ v2: Version) {
        XCTAssertTrue(v1 < v2)
        XCTAssertTrue(v1 <= v2)
        XCTAssertTrue(v1 != v2)
        XCTAssertFalse(v1 == v2)
        XCTAssertFalse(v1 >= v2)
        XCTAssertFalse(v1 > v2)
    }

    private func equal(_ v1: Version, _ v2: Version) {
        XCTAssertTrue(v1 >= v2)
        XCTAssertTrue(v1 <= v2)
        XCTAssertTrue(v1 == v2)
        XCTAssertFalse(v1 != v2)
        XCTAssertFalse(v1 < v2)
        XCTAssertFalse(v1 > v2)
    }

    private func newer(_ v1: Version, _ v2: Version) {
        XCTAssertTrue(v1 > v2)
        XCTAssertTrue(v1 >= v2)
        XCTAssertTrue(v1 != v2)
        XCTAssertFalse(v1 == v2)
        XCTAssertFalse(v1 <= v2)
        XCTAssertFalse(v1 < v2)
    }

}
