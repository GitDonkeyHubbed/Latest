//
//  BundleCollector.swift
//  Latest
//
//  Created by Max Langer on 07.03.24.
//  Copyright © 2024 Max Langer. All rights reserved.
//

import Foundation
import UniformTypeIdentifiers

/// Gathers apps at a given URL.
enum BundleCollector {
	
	/// Excluded subfolders that won't be checked.
	private static let excludedSubfolders = Set(["Setapp"])
	
	/// Set of bundles that should not be included in Latest.
	private static let excludedBundleIdentifiers = Set([
		// Safari Web Apps
		"com.apple.Safari.WebApp",
		"com.max-langer.Latest"
	])
	
	private static let appExtension = UTType.applicationBundle.preferredFilenameExtension
	
	/// Returns a list of application bundles at the given URL.
	static func collectBundles(at url: URL) -> [App.Bundle] {
		let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
		
		var bundles = [App.Bundle]()
		while let bundleURL = enumerator?.nextObject() as? URL {
			guard !excludedSubfolders.contains(where: { bundleURL.pathComponents.contains($0) }) else {
				enumerator?.skipDescendants()
				continue
			}
			
			if bundleURL.pathExtension == appExtension, let bundle = bundle(forAppAt: bundleURL) {
				bundles.append(bundle)
			}
		}

		return bundles
	}
	
	
	// MARK: - Utilities
		
	/// Returns a bundle representation for the app at the given url, without Spotlight Metadata.
	static private func bundle(forAppAt url: URL) -> App.Bundle? {
		guard let appBundle = Bundle(url: url),
			  let info = appBundle.uncachedInfoDictionary,
			  let buildNumber = info["CFBundleVersion"] as? String,
			  let identifier = (info["CFBundleIdentifier"] as? String) ?? appBundle.bundleIdentifier,
			  let versionNumber = info["CFBundleShortVersionString"] as? String,
			  let appName = (info["CFBundleName"] as? String) ?? (info["CFBundleDisplayName"] as? String) else {
			return nil
		}
		
		// Find update source
		guard let source = UpdateCheckCoordinator.source(forAppAt: url) else {
			return nil
		}
		
		// Skip bundles which are explicitly excluded
		guard !excludedBundleIdentifiers.contains(where: { identifier.contains($0) }) else {
			return nil
		}
		
		// Build version. Skip bundle if no version is provided.
		let version = Version(versionNumber: VersionParser.parse(versionNumber: versionNumber), buildNumber: VersionParser.parse(buildNumber: buildNumber))
		guard !version.isEmpty else {
			return nil
		}
		
		// Create bundle
		return App.Bundle(version: version, name: appName, bundleIdentifier: identifier, fileURL: url, source: source)
	}

}

fileprivate extension Bundle {
	
	/// The bundle's Info.plist contents, bypassing `Bundle.infoDictionary` caching.
	///
	/// `NSBundle` and `CFBundle` both cache Info.plist keys. After Sparkle,
	/// Homebrew, or App Store installs that cache still returned the pre-update
	/// short-version string, so the app stayed in Available Updates. Prefer the
	/// plist file on disk; only then fall back to a flushed CFBundle.
	var uncachedInfoDictionary: [String: Any]? {
		let candidates = [
			bundleURL.appendingPathComponent("Contents/Info.plist"),
			bundleURL.appendingPathComponent("Wrapper/Info.plist"),
			bundleURL.appendingPathComponent("Info.plist")
		]
		for plistURL in candidates {
			if let info = NSDictionary(contentsOf: plistURL) as? [String: Any],
			   info["CFBundleIdentifier"] != nil || info["CFBundleShortVersionString"] != nil {
				return info
			}
		}
		
		let bundleRef = CFBundleCreate(.none, self.bundleURL as CFURL)
		if let bundleRef {
			_CFBundleFlushBundleCaches(bundleRef)
			if let info = CFBundleGetInfoDictionary(bundleRef) as? [String: Any] {
				return info
			}
		}
		
		return infoDictionary
	}
}
