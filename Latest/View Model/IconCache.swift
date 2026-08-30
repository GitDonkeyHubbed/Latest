//
//  IconCache.swift
//  Latest
//
//  Created by Max Langer on 12.08.18.
//  Copyright © 2018 Max Langer. All rights reserved.
//

import AppKit

/// A cache for app icons.
class IconCache {
    
	/// The shared cache object.
    static var shared = IconCache()
    
	/// Initializes the cache.
    private init() {
        self.cache = NSCache()
    }

	/// The object storing app images.
	private var cache: NSCache<NSString, NSImage>
	
	/// Provides the icon for the given app through the given completion handler.
    func icon(for app: App, with completion: @escaping (NSImage) -> Void) {
        let key = app.identifier.absoluteString as NSString
        if let icon = self.cache.object(forKey: key) {
            completion(icon)
			return
        }
        
        DispatchQueue.main.async {
            let icon = NSWorkspace.shared.icon(forFile: app.fileURL.path)
            self.cache.setObject(icon, forKey: key)

            completion(icon)
        }
    }
    
}
