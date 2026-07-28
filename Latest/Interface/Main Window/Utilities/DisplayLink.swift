//
//  DisplayLink.swift
//
//  Created by Max Langer on 23.05.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import AppKit
import QuartzCore

/// Forwards display-link ticks to the wrapper without retaining it, so a
/// discarded wrapper can deallocate and tear its link down in deinit even if
/// the owner never called `stop()`.
private final class DisplayLinkProxy: NSObject {
	weak var target: DisplayLink?

	@objc func displayTick() {
		self.target?.displayTick()
	}
}

/// Convenience wrapper for driving animations from a display link.
class DisplayLink: NSObject {

	/// The amount of time the display link should be running. If  set to `nil`, the display link runs indefinitely.
    private(set) var duration : Double?

	/// An optional completion handler called after the display link stopped animating.
    var completionHandler : (() -> ())?

	/// The current  animation progress. Only useful if a duration has been set.
	private(set) var progress : Double = 0

	/// The view driving the display link on macOS 14 and later. If no view is given, the main screen drives the link instead.
	private weak var view : NSView?

	/// Backing storage for the modern display link. Typed `Any` since `CADisplayLink` is unavailable on macOS 13.
	private var modernDisplayLink : Any?

	/// The display link driving the animation on macOS 14 and later.
	@available(macOS 14.0, *)
	private var caDisplayLink : CADisplayLink? {
		get { return self.modernDisplayLink as? CADisplayLink }
		set { self.modernDisplayLink = newValue }
	}

	/// The display link driving the animation on macOS 13.
	private var legacyDisplayLink : CVDisplayLink?

	/// Frames used to calculate the animation progress, normalized to a 60 FPS timescale.
    private var _currentFrame : Double = 0
    private var _frames : Double = 0

	/// The callback called for each animation step.
    private(set) var callback : ((_ progress: Double) -> Void)!


	// MARK: - Initialization

	/// Initializes the display link with the given duration and callback.
	///
	/// On macOS 14 and later, the given view drives the animation. Passing no view falls back to a display link driven by the main screen.
	init(view: NSView? = nil, duration: Double?, callback: @escaping ((_ progress: Double) -> Void)) {
        super.init()

		self.view = view
        self.duration = duration
        self.callback = callback

		if #available(macOS 14.0, *) {
			// The CADisplayLink is created lazily in start(), since it retains its target while scheduled.
		} else {
			func displayLinkOutputCallback(_ displayLink: CVDisplayLink, _ inNow: UnsafePointer<CVTimeStamp>, _ inOutputTime: UnsafePointer<CVTimeStamp>, _ flagsIn: CVOptionFlags, _ flagsOut: UnsafeMutablePointer<CVOptionFlags>, _ displayLinkContext: UnsafeMutableRawPointer?) -> CVReturn {
				guard let displayLinkContext else { return kCVReturnInvalidArgument }

				unsafeBitCast(displayLinkContext, to: DisplayLink.self).displayTick()
				return kCVReturnSuccess
			}

			CVDisplayLinkCreateWithActiveCGDisplays(&self.legacyDisplayLink)
			if let legacyDisplayLink = self.legacyDisplayLink {
				CVDisplayLinkSetOutputCallback(legacyDisplayLink, displayLinkOutputCallback, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
			}
		}
	}

	deinit {
		// Immediately remove callback to avoid access to the deallocated access to this object from the callback on a background thread
		if let legacyDisplayLink = self.legacyDisplayLink {
			CVDisplayLinkSetOutputCallback(legacyDisplayLink, nil, nil)
		}

		// The link only holds the proxy; invalidate it so it stops ticking and
		// leaves the run loop once the wrapper goes away.
		if #available(macOS 14.0, *) {
			self.caDisplayLink?.invalidate()
		}
	}


	// MARK: - Animation

    @objc fileprivate func displayTick() {
		// Determine the total number of frames, normalized to a 60 FPS timescale.
		if let duration = self.duration {
			self._frames = duration * 60
		}

		else {
			self._frames = 1
		}

		// Advance the current frame based on the actual refresh rate of the display, normalized to a 60 FPS timescale.
		if #available(macOS 14.0, *), let displayLink = self.caDisplayLink {
			self._currentFrame += (displayLink.targetTimestamp - displayLink.timestamp) * 60
		} else if let displayLink = self.legacyDisplayLink {
			self._currentFrame += CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink) * 60
		} else {
			return
		}

		// Forward progress to the observer
		DispatchQueue.main.async {
			self.progress = self._currentFrame / self._frames
			if self.duration != nil, self.progress >= 1 {
                self.completionHandler?()
				self.stop()
            }

			self.callback(self.progress)
        }
	}


	// MARK: - Actions

	/// Starts the display link.
    func start() {
        self._currentFrame = 0

		if #available(macOS 14.0, *) {
			// Recreate the link if necessary, as it is invalidated whenever the animation stops.
			// The link targets a weak proxy instead of self: a scheduled CADisplayLink
			// retains its target, and retaining self directly would keep a discarded
			// wrapper alive and ticking forever.
			if self.caDisplayLink == nil {
				let proxy = DisplayLinkProxy()
				proxy.target = self

				let displayLink = self.view?.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.displayTick)) ?? NSScreen.main?.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.displayTick))
				displayLink?.add(to: .main, forMode: .common)
				self.caDisplayLink = displayLink
			}

			self.caDisplayLink?.isPaused = false
		} else if let legacyDisplayLink = self.legacyDisplayLink {
			CVDisplayLinkStart(legacyDisplayLink)
		}
    }

	/// Stops the display link.
    func stop() {
		if #available(macOS 14.0, *) {
			// The link retains its target while scheduled. Invalidate it on the main thread so this object can be deallocated.
			let invalidate = {
				self.caDisplayLink?.invalidate()
				self.caDisplayLink = nil
			}

			if Thread.isMainThread {
				invalidate()
			} else {
				DispatchQueue.main.async(execute: invalidate)
			}
		} else {
			// Must not be called on sync Main Thread, as it causes a deadlock there.
			DispatchQueue.global().async { [weak self] in
				guard let self = self, let legacyDisplayLink = self.legacyDisplayLink else { return }
				CVDisplayLinkStop(legacyDisplayLink)
			}
		}
    }

}
