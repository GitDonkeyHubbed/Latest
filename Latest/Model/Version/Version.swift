//
//  Version.swift
//  Latest
//
//  Created by Max Langer on 01.11.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import Foundation

/**
 A Version represents a single version of an app. It contains both the version number and the build number to uniquely
 identify an app (in theory).
 Comparisons of versions results in an actual comparison. I.E. 1.4.2 > 1.3.5
 Build numbers are compared instead when both sides carry usable ones, see `compare(_:_:)`.
 This class is very much work in progress and needs some deep thoughts on edge cases and a more clever implementation
 */
struct Version: Hashable, Comparable {

	/// The version number itself
	let versionNumber: String?

	/// The build number itself
	let buildNumber: String?

	/// Flag whether both version number and build number are unavailable
	var isEmpty: Bool {
		let versionNumberComponents = versionNumber?.components().compactMap({ $0.plainComponent }).joined()
		let buildNumberComponents = buildNumber?.components().compactMap({ $0.plainComponent }).joined()

		return (versionNumberComponents?.isEmpty ?? true && buildNumberComponents?.isEmpty ?? true)
	}

	// MARK: - Comparisons

	static func == (lhs: Version, rhs: Version) -> Bool {
		compare(lhs, rhs) == .equal
	}

	static func < (lhs: Version, rhs: Version) -> Bool {
		compare(lhs, rhs) == .older
	}

	static func > (lhs: Version, rhs: Version) -> Bool {
		compare(lhs, rhs) == .newer
	}

	// MARK: - Hashing

	func hash(into hasher: inout Hasher) {
		// Equal values must hash equally, but `==` means "same update precedence", not "same
		// strings": "1.2" equals "1.2.0", and two values can be equal through their build numbers
		// while their version numbers differ, or vice versa. Chained, these equalities link
		// practically every pair of versions — (1.0, 100) == (2.0, 100) == (2.0, nil) == (2.0, 200) —
		// so no hash finer than a constant one keeps equal values together. Nothing uses versions
		// as set elements or dictionary keys (App hashes its identifier only), so this costs nothing.
	}

	// MARK: - Private

	/// An enum describing the result of an comparison.
	private enum CheckingResult {
		case older, newer, equal, undefined
	}

	/// Performs the actual check. This version checker is adopted by the Sparkle Framework and slightly adapted.
	///
	/// Whether build or version numbers are compared is decided from both sides alike, so
	/// `compare(a, b)` is always the mirror image of `compare(b, a)`:
	/// - Build numbers are only used if both are present and both look like build numbers
	///   ("1234", "1.2.40", "3.0b2"; not commit hashes like "a1b2c3" or "4f3a2b"). Otherwise versions are compared.
	/// - If both builds differ from their own version numbers, builds are compared. This is what
	///   Sparkle itself does: it compares CFBundleVersion.
	/// - If neither does, each side only holds a single string, and version numbers are compared.
	/// - If exactly one build merely repeats its version number (a Sparkle feed without a short version
	///   string, or an app whose CFBundleVersion equals its short version), that single string may be
	///   either kind. It is compared with the other side's build, as Sparkle would, unless it is clearly shaped
	///   like that side's version instead: it has the version's number of components but not the build's.
	///   Think "2.1.5" against "2.1.4 (300)", or a cask "4.5.0,450" against an app's "4.5.0".
	private static func compare(_ lhs: Version, _ rhs: Version) -> CheckingResult {
		var v1: String?
		var v2: String?

		if comparesBuildNumbers(lhs, rhs) {
			v1 = lhs.buildNumber
			v2 = rhs.buildNumber
		} else {
			v1 = lhs.versionNumber
			v2 = rhs.versionNumber
		}

		// Semantic-versioning build metadata (a trailing "+…" suffix) carries no
		// precedence: "3.6.1000+next.05e2e51d52" is the same version as "3.6.1000".
		// Comparing it produces phantom updates for apps whose feeds annotate
		// versions with build hashes, so it is ignored on both sides.
		v1 = v1?.strippingBuildMetadata
		v2 = v2?.strippingBuildMetadata

		guard let c1 = v1?.components(), let c2 = v2?.components() else {
			// Two versions without any comparable content are equal to each other.
			return (v1 == nil && v2 == nil) ? .equal : .undefined
		}

		let count1 = c1.count
		let count2 = c2.count
		for i in 0..<min(count1, count2) {
			guard case .component(let component1) = c1[i], case .component(let component2) = c2[i] else { continue }

			if let result = compareAtoms(component1, component2) {
				return result
			}
		}

		// The versions are equal up to the point where they both still have parts
		// Lets check to see if one is larger than the other
		if count1 != count2 {
			let isLonger1 = count1 > count2
			let longerComponents = (isLonger1 ? c1 : c2)[(isLonger1 ? count2 : count1)...]
			guard case .component(let atoms) = longerComponents.first(where: { if case .component = $0 { true } else { false } }) else {
				return .equal // Think "1.2" vs "1.2."
			}

			if case .number(let number) = atoms.first {
				if number == 0 {
					return .equal // Think "1.2" vs "1.2.0"
				}

				return isLonger1 ? .newer : .older // Think "1.2" vs "1.2.2"
			}

			return isLonger1 ? .older : .newer // Think "1.2" vs "1.2A"
		}

		return .equal // Think "1.2" vs "1.2"
	}

	/// Whether `compare(_:_:)` should compare the build numbers of the given versions. Symmetric in its arguments.
	private static func comparesBuildNumbers(_ lhs: Version, _ rhs: Version) -> Bool {
		guard let lhsBuild = lhs.buildNumber, let rhsBuild = rhs.buildNumber,
			  lhsBuild.looksLikeBuildNumber, rhsBuild.looksLikeBuildNumber else {
			return false
		}

		switch (lhsBuild != lhs.versionNumber, rhsBuild != rhs.versionNumber) {
		case (true, true):
			return true
		case (false, false):
			return false
		case (false, true):
			return !reads(lhsBuild, asVersionOf: rhs)
		case (true, false):
			return !reads(rhsBuild, asVersionOf: lhs)
		}
	}

	/// Whether the given single string is better read as the version's version number than as its build number:
	/// it has as many components as the version number, but not as many as the build. Ambiguous shapes ("1234"
	/// against "5 (1230)", "3.0" against "3.0 (3.0b2)") count as builds, as Sparkle compares CFBundleVersion.
	private static func reads(_ string: String, asVersionOf version: Version) -> Bool {
		let count = string.componentCount
		return count == version.versionNumber?.componentCount && count != version.buildNumber?.componentCount
	}

	/// Compares the atoms of two version components, returning the comparison
	/// result of the first pair of atoms that differ, or nil if they are equal
	/// (or one side runs out of atoms before a difference is found).
	private static func compareAtoms(_ atoms1: [Segment.Atom], _ atoms2: [Segment.Atom]) -> CheckingResult? {
		let atomsCount1 = atoms1.count
		let atomsCount2 = atoms2.count
		for i in 0..<min(atomsCount1, atomsCount2) {
			let component1 = atoms1[i]
			let component2 = atoms2[i]

			if let result = compareAtom(component1, component2) {
				return result
			}
		}

		// The atoms are equal as far as both go. Mirror the component-level rule for any
		// extra atoms: a trailing text suffix marks a pre-release, a trailing number a later build.
		if atomsCount1 != atomsCount2 {
			let isLonger1 = atomsCount1 > atomsCount2
			switch (isLonger1 ? atoms1 : atoms2)[min(atomsCount1, atomsCount2)] {
			case .string:
				return isLonger1 ? .older : .newer // Think "1.0b3" vs "1.0"
			case .number(let value) where value != 0:
				return isLonger1 ? .newer : .older // Think "1.0b3" vs "1.0b"
			case .number:
				break
			}
		}

		return nil
	}

	/// Compares a single pair of atoms, returning nil if they are equal.
	private static func compareAtom(_ component1: Segment.Atom, _ component2: Segment.Atom) -> CheckingResult? {
		// Compare numbers
		if case .number(let value1) = component1, case .number(let value2) = component2 {
			if value1 > value2 {
				return .newer // Think "1.3" vs "1.2"
			} else if value2 > value1 {
				return .older // Think "1.2" vs "1.3"
			}
		}

		// Compare letters
		else if case .string(let value1) = component1, case .string(let value2) = component2 {
			switch value1.compare(value2) {
			case .orderedAscending:
				return .older // Think "1.2A" vs "1.2B"
			case .orderedDescending:
				return .newer // Think "1.2B" vs "1.2A"
			default: ()
			}
		}

		// Not the same type? Now we have to do some validity checking
		else {
			return compareMismatchedAtoms(component1, component2)
		}

		return nil
	}

	/// Compares two atoms of different types.
	private static func compareMismatchedAtoms(_ component1: Segment.Atom, _ component2: Segment.Atom) -> CheckingResult? {
		if case .string = component1 {
			return .older // Think "1.2A" vs "1.2.2"
		} else if case .string = component2 {
			return .newer // Think "1.2.3" vs "1.2A"
		}

		// One is a number and the other is a period. The period is invalid
		else if case .number = component1 {
			return .older // Think "1.2.." vs "1.2.0"
		} else if case .number = component2 {
			return .newer // Think "1.2.3" vs "1.2.."
		}

		return nil
	}
}

extension Version: CustomDebugStringConvertible {
	var debugDescription: String {
		return "Version: \(versionNumber ?? "None"), Build: \(buildNumber ?? "None")"
	}
}

/// An extension helping the version checking
fileprivate extension String {

	/**
	 Returns the components of an version number.
	 Components are grouped by Character type, so "12.3" returns [("12", .number), (".", .separator), ("3", .number)]
	 */
	func components() -> [Version.Segment] {
		let scanner = Scanner(string: self)

		var components = [Version.Segment]()
		var currentAtoms = [Version.Segment.Atom]()

		while !scanner.isAtEnd {
			// Try to scan number. Only plain digit runs count: `scanInt` would also consume a
			// leading sign, reading the separator in "1.2-5" as the negative number -5.
			if let digits = scanner.scanCharacters(from: .decimalDigits) {
				// Map every numeral system ("٣", "३", "１") to ASCII before converting.
				let asciiDigits = digits.compactMap { $0.wholeNumberValue.map(String.init) }.joined()
				if asciiDigits.count == digits.count, let number = Int(asciiDigits) {
					currentAtoms.append(.number(value: number))
				} else {
					// Values exceeding Int: keep them as plain text.
					currentAtoms.append(.string(value: digits))
				}
			}

			// Try to scan separator
			else if let string = scanner.scanCharacters(from: .separators) {
				components.append(.component(atoms: currentAtoms))
				components.append(.separator(character: string as String))

				currentAtoms.removeAll()
			}

			// Try to scan anything else
			else if let string = scanner.scanCharacters(from: .letters) {
				currentAtoms.append(.string(value: string as String))
			} else {
				// Characters that fit no category (e.g. digit-class characters
				// the scanner cannot consume as a number) must not crash the
				// app over one odd version string. Consume a single character
				// as plain text so scanning always advances. Indices must come
				// from scanner.string — string indices are not portable between
				// String instances.
				let string = scanner.string
				let index = scanner.currentIndex
				guard index < string.endIndex else { break }

				currentAtoms.append(.string(value: String(string[index])))
				scanner.currentIndex = string.index(after: index)
			}
		}

		if !currentAtoms.isEmpty {
			components.append(.component(atoms: currentAtoms))
		}

		return components
	}

	/// The number of non-empty components, ignoring build metadata. 3 for "1.2.3", 1 for "1234".
	var componentCount: Int {
		strippingBuildMetadata.components().filter { segment in
			if case .component(let atoms) = segment { !atoms.isEmpty } else { false }
		}.count
	}

	/// Whether the string reads as a build number: it starts with a digit and is no commit hash or digest
	/// ("1234", "1.2.40", "3.0b2", "21A5300"; not "a1b2c3" or "4f3a2b"). Homebrew casks carry such tokens as
	/// build, and ranking them against a plain number is meaningless.
	var looksLikeBuildNumber: Bool {
		let string = strippingBuildMetadata
		guard case .component(let atoms) = string.components().first, case .number = atoms.first else {
			return false
		}

		// Six or more lowercase hex digits including a letter: typical for a hash, unlikely for a build.
		// Apple-style builds ("21A5300") use uppercase letters.
		let isHash = string.count >= 6
			&& string.allSatisfy { $0.isHexDigit && !$0.isUppercase }
			&& string.contains(where: \.isLetter)
		return !isHash
	}
}

fileprivate extension CharacterSet {

	/// Contains all delimiters used by a version string
	static let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

	/// Contains any characters but separators and digits
	static let letters = CharacterSet.separators.union(.decimalDigits).inverted

}

// Defining the type of a character
fileprivate extension Version {
	enum Segment: Equatable {

		enum Atom: Equatable {
			case number(value: Int) // 0..9
			case string(value: String) // Everything else

			func isSameType(_ other: Atom) -> Bool {
				switch (self, other) {
				case (.number(_), .number(_)),
					(.string(_), .string(_)):
					return true
				default:
					return false
				}
			}
		}

		case separator(character: String) // Newlines, punctuation..
		case component(atoms: [Atom]) // [123, A]

		var plainComponent: String? {
			guard case .component(let atoms) = self else {
				return nil
			}

			return atoms.map { atom in
				switch atom {
				case .number(let value):
					return "\(value)"
				case .string(let value):
					return value
				}
			}.joined()
		}

		func isSameType(_ other: Segment) -> Bool {
			switch (self, other) {
			case (.separator, .separator),
				(.component(_), .component(_)):
				return true
			default:
				return false
			}
		}

	}

}

extension Array where Element == Version.Segment {
	func joined() -> String? {
		let string = self.map { segment in
			switch segment {
			case .separator(let character):
				character
			case .component:
				segment.plainComponent!
			}
		}.joined()

		return string.isEmpty ? nil : string
	}
}

// MARK: - Version Sanitization

extension Version {

	func sanitize(with appVersion: Version) -> Version {
		// The last component of the version number is actually the build number. (Can only be detected for equal build numbers. Avoids false positives)
		// App: 1.2 (40)
		// Remote: 1.2.40
		if buildNumber == nil, var components = versionNumber?.components(),
		   let lastRemoteComponent = components.last?.plainComponent, lastRemoteComponent == appVersion.buildNumber {
			// Remove build number segment from version number and store it separately.
			let buildNumber = components.removeLast()

			// Remove separator as well.
			if !components.isEmpty {
				components.removeLast()
			}

			return Version(versionNumber: components.joined(), buildNumber: buildNumber.plainComponent)
		}

		// The entire version number equals the app versions build number. We assume version number by default, but that may not be the case.
		if let versionNumber, versionNumber == appVersion.buildNumber {
			// Switch to build number.
			return Version(versionNumber: nil, buildNumber: versionNumber)
		}

		//
		if appVersion.buildNumber == appVersion.versionNumber, var components = versionNumber?.components(),
		   components.last?.plainComponent != nil, components.count == 7 {
			components.removeLast()
			components.removeLast()

			if components.joined() == appVersion.buildNumber {
				return Version(versionNumber: components.joined(), buildNumber: buildNumber)
			}
		}

		// Nothing changed
		return self
	}

}

// MARK: -

extension OperatingSystemVersion: @retroactive Comparable, @retroactive Equatable {

	public static func == (lhs: OperatingSystemVersion, rhs: OperatingSystemVersion) -> Bool {
		lhs.majorVersion == rhs.majorVersion &&
		lhs.minorVersion == rhs.minorVersion &&
		lhs.patchVersion == rhs.patchVersion
	}

	public static func < (lhs: OperatingSystemVersion, rhs: OperatingSystemVersion) -> Bool {
		if lhs.majorVersion != rhs.majorVersion {
			return lhs.majorVersion < rhs.majorVersion
		}
		if lhs.minorVersion != rhs.minorVersion {
			return lhs.minorVersion < rhs.minorVersion
		}
		return lhs.patchVersion < rhs.patchVersion
	}

	init(string: String) throws {
		let components = string.components().flatMap({ component in
			switch component {
			case .component(let atoms):
				return atoms.compactMap { atom in
					switch atom {
					case .number(let value):
						return value
					default:
						return nil
					}
				}
			default:
				return []
			}
		})
		guard !components.isEmpty else { throw OperatingSystemVersionError.parsingError(version: string) }

		let major = components[0]
		let minor = components.count > 1 ? components[1] : 0
		let patch = components.count > 2 ? components[2] : 0
		self.init(majorVersion: major, minorVersion: minor, patchVersion: patch)
	}

	enum OperatingSystemVersionError: Error {
		case parsingError(version: String)
	}

}

// MARK: - Semantic Versioning

private extension String {

	/// The version string with any semantic-versioning build metadata removed.
	///
	/// Build metadata is the part after a "+" ("3.6.1000+next.05e2e51d52"). Per
	/// the semantic-versioning specification it must be ignored when determining
	/// version precedence.
	var strippingBuildMetadata: String {
		guard let index = self.firstIndex(of: "+") else { return self }
		return String(self[..<index])
	}

}
