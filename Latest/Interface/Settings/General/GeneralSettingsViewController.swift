//
//  GeneralSettingsViewController.swift
//  Latest
//
//  Created by Max Langer on 27.12.24.
//  Copyright © 2024 Max Langer. All rights reserved.
//

import AppKit

/// Controller for settings of the General tab.
class GeneralSettingsViewController: SettingsTabItemViewController {
	override func viewDidLoad() {
		super.viewDidLoad()
		updateInstallHelperBannerVisibility()
	}
	
	// MARK: - Check Includes
	
	/// Whether apps with limited support should be included in the app list.
	@objc var includeAppsWithLimitedSupport: Bool {
		get {
			AppListSettings.shared.includeAppsWithLimitedSupport
		}
		set {
			AppListSettings.shared.includeAppsWithLimitedSupport = newValue
		}
	}
	
	/// Whether apps with no support should be included in the app list.
	@objc var includeUnsupportedApps: Bool {
		get {
			AppListSettings.shared.includeUnsupportedApps
		}
		set {
			AppListSettings.shared.includeUnsupportedApps = newValue
		}
	}
	
	
	// MARK: - Install Helper
	
	@IBOutlet weak var installHelperOptInView: NSView!

	private func updateInstallHelperBannerVisibility() {
		do {
			try InstallHelper.verifyAvailability()
			installHelperOptInView.isHidden = true
		} catch {
			installHelperOptInView.isHidden = false
		}
	}
	
	@IBAction func registerInstallHelper(_ sender: Any) {
		AppStoreUpdateSettings.alwaysPerformManualUpdates.active = false
		try? InstallHelper.installHelper()
		
		updateInstallHelperBannerVisibility()
	}

}
