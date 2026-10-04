//
//  AppListSettings.swift
//  Latest
//
//  Created by Max Langer on 09.01.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

private let sortOptionsKey = "SortOptionsKey"
private let showInstalledUpdatesKey = "ShowInstalledUpdatesKey"
private let showIgnoredUpdatesKey = "ShowIgnoredUpdatesKey"

private let includeUnsupportedAppsKey = "ShowUnsupportedUpdatesKey"
private let includeAppsWithLimitedSupportKey = "IncludeAppsWithLimitedSupportKey"

/// Observable front end to app list preferences.
struct AppListSettings: Observable {

	/// Sorting options available to the app list.
	enum SortOptions: Int, CaseIterable {
		/// Sort based on the date of the the last update, similar to what the App Store does.
		case updateDate = 0

		/// Sort alphabetically by app name.
		case name = 1

		/// A user-displayable text of the given sort option.
		var displayName: String {
			switch self {
			case .updateDate:
				return NSLocalizedString("DateSortOption", comment: "Update date sorting option. Displayed in menu with title: 'Sort By' -> 'Date'")
			case .name:
				return NSLocalizedString("NameSortOption", comment: "Sorting option to list by app names alphabetically. Displayed in menu with title: 'Sort By' -> 'Name'")
			}
		}
	}

	var observers = [UUID: ObservationHandler]()

	private init() {
		// Show installed updates by default
		UserDefaults.standard.register(defaults: [showInstalledUpdatesKey: true])
	}

	static var shared: AppListSettings = {
		return AppListSettings()
	}()

	/// The order the app list should be shown in.
	var sortOrder: SortOptions {
		get {
			SortOptions(rawValue: UserDefaults.standard.integer(forKey: sortOptionsKey)) ?? .updateDate
		}

		set {
			set(newValue.rawValue, forKey: sortOptionsKey)
		}
	}

	/// Whether installed apps should be visible
	var showInstalledUpdates: Bool {
		get {
			UserDefaults.standard.bool(forKey: showInstalledUpdatesKey)
		}

		set {
			set(newValue, forKey: showInstalledUpdatesKey)
		}
	}

	/// Whether ignored apps should be visible
	var showIgnoredUpdates: Bool {
		get {
			UserDefaults.standard.bool(forKey: showIgnoredUpdatesKey)
		}

		set {
			set(newValue, forKey: showIgnoredUpdatesKey)
		}
	}

	/// Whether unsupported apps should be visible
	var includeUnsupportedApps: Bool {
		get {
			UserDefaults.standard.bool(forKey: includeUnsupportedAppsKey)
		}

		set {
			set(newValue, forKey: includeUnsupportedAppsKey)
		}
	}

	/// Whether apps only partially supported by Latest should be included.
	var includeAppsWithLimitedSupport: Bool {
		get {
			UserDefaults.standard.bool(forKey: includeAppsWithLimitedSupportKey)
		}

		set {
			set(newValue, forKey: includeAppsWithLimitedSupportKey)
		}
	}

	// MARK: - Utilities

	private func set(_ value: Any, forKey key: String) {
		UserDefaults.standard.set(value, forKey: key)

		DispatchQueue.main.async {
			self.notify()
		}
	}

}
