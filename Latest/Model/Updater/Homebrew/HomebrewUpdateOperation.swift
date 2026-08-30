//
//  HomebrewUpdateOperation.swift
//  Latest
//
//  Copyright © 2026 Max Langer. All rights reserved.
//

import Foundation

/// The operation upgrading apps installed as Homebrew casks.
///
/// Runs `brew upgrade --cask <token>` as the current user. Output is drained continuously to
/// feed the inactivity watchdog during long downloads and to surface brew's error output when
/// the upgrade fails.
final class HomebrewUpdateOperation: UpdateOperation, @unchecked Sendable {

	/// The maximum amount of process output retained for error reporting.
	private static let maximumBufferedOutputLength = 8192

	/// The length of the output tail attached to failure messages.
	private static let errorOutputTailLength = 500

	/// The token identifying the cask to be upgraded.
	private let caskToken: String

	/// The location of the brew executable, resolved at check time.
	private let brewURL: URL

	/// The running brew process. Guarded by `processLock`.
	private var process: Process?

	/// Protects `process` against the launch-vs-cancel race.
	private let processLock = NSLock()

	/// The tail of the combined standard output and error of the process. Guarded by `outputLock`.
	private var outputBuffer = Data()

	/// Protects `outputBuffer`.
	private let outputLock = NSLock()

	/// Initializes the operation for the given app, updating the cask with the given token.
	init(bundleIdentifier: String, appIdentifier: App.Bundle.Identifier, caskToken: String, brewURL: URL) {
		self.caskToken = caskToken
		self.brewURL = brewURL
		super.init(bundleIdentifier: bundleIdentifier, appIdentifier: appIdentifier)
	}


	// MARK: - Operation Overrides

	override func execute() {
		super.execute()

		// The brew location was resolved at check time; re-validate it before running.
		guard FileManager.default.isExecutableFile(atPath: self.brewURL.path) else {
			self.finish(with: LatestError.homebrewNotFound)
			return
		}

		// Brew upgrades are serialized by the update queue via operation dependencies
		// (Homebrew holds a global lock); once this runs, it owns brew. Run off the
		// queue's thread so the slot's thread is not blocked for the whole upgrade.
		DispatchQueue.global(qos: .utility).async {
			// The operation may have been cancelled or timed out in the meantime.
			guard !self.isCancelled, !self.isFinished else {
				self.finish()
				return
			}

			self.runBrew()
		}
	}

	override func cancel() {
		super.cancel()

		// Only terminate an already-launched process; the drain loop then finishes the
		// operation via processDidTerminate. Do NOT finish here when the process is nil: a
		// cancel racing runBrew could finish the operation while runBrew goes on to launch
		// brew, orphaning it. Pre-launch cancellation is handled by the async guard in
		// execute(); a cancel that lands after process.run() but before publication is caught
		// by the post-launch check in runBrew.
		let process = self.processLock.withCriticalScope { self.process }
		process?.terminate()
	}

	override func timeoutTeardown() {
		// Tear down the running process so brew does not continue installing after the
		// operation failed. Runs only when the timeout wins the finish claim.
		let process = self.processLock.withCriticalScope { self.process }
		process?.terminate()
		super.timeoutTeardown()
	}


	// MARK: - Running Brew

	/// Launches brew and blocks the brew queue until the process exited and was reaped.
	private func runBrew() {
		let process = Process()
		process.executableURL = self.brewURL
		process.arguments = ["upgrade", "--cask", self.caskToken]

		// Inherit the user's environment; disabling auto-update avoids a multi-minute
		// `brew update` (git tap sync) before the upgrade even starts. But the checker
		// advertises versions from the live cask API (formulae.brew.sh/api/cask.json via
		// UpdateRepository), while a plain `brew upgrade --cask` reads brew's locally
		// cached API JSON — which NO_AUTO_UPDATE would otherwise leave stale past its TTL.
		// The stale cache makes brew report "already installed / not upgrading" for a
		// version the checker already showed as newer, surfacing as homebrewUpgradeNotPerformed
		// with the update stuck in the list forever (Q1). HOMEBREW_FORCE_API_AUTO_UPDATE
		// forces only the cheap API cask-data refresh even while NO_AUTO_UPDATE is set
		// (see `brew` manpage), so the installer resolves the same version the checker did
		// without paying for a full git `brew update`. The added refresh is a small JSON
		// fetch, well within the monotonic download watchdog grace.
		var environment = ProcessInfo.processInfo.environment
		environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
		environment["HOMEBREW_FORCE_API_AUTO_UPDATE"] = "1"
		environment["HOMEBREW_NO_ENV_HINTS"] = "1"
		environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
		// Homebrew's boolean variables are presence-based; NO_COLOR is the documented
		// way to keep ANSI escapes out of the piped output.
		environment["HOMEBREW_NO_COLOR"] = "1"
		process.environment = environment

		// A null stdin makes password prompts (e.g. sudo for pkg-based casks) fail
		// immediately instead of hanging until the watchdog aborts the operation.
		process.standardInput = FileHandle.nullDevice

		// Combine stdout and stderr into a single pipe for activity tracking and error reporting.
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe

		do {
			try process.run()
		} catch {
			self.finish(with: error)
			return
		}

		self.processLock.withCriticalScope { self.process = process }

		// A concurrent cancel or timeout may have won between process.run() and this
		// publication. Terminate the now-published process so cancellation/timeout during
		// process.run() cannot leave brew running, and suppress the .installing progress for an
		// operation that is already cancelled or finished. processDidTerminate remains the sole
		// post-launch finish site — we only terminate here; the drain loop reaps and finishes.
		if self.isCancelled || self.isFinished {
			process.terminate()
		} else {
			self.progressState = .installing
		}

		// Drain the combined output before waiting on the process — waiting first could
		// deadlock once the pipe buffer fills up. Each chunk feeds the watchdog so long
		// downloads are not mistaken for a stall. Each wait is bounded with poll(2):
		// brew's children (e.g. curl) inherit the pipe's write end and can keep it open
		// after brew itself was terminated, so waiting for EOF alone could hang forever.
		let handle = pipe.fileHandleForReading
		while true {
			var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
			let result = poll(&descriptor, 1, 30_000)

			guard result > 0 else {
				// Timeout or signal: keep draining while brew itself is alive. Once it
				// is gone, silent stragglers holding the pipe are not worth waiting for.
				if process.isRunning { continue }
				break
			}

			let data = handle.availableData
			// An empty read signals EOF: all writers closed the pipe.
			guard !data.isEmpty else { break }

			self.append(output: data)
			self.noteActivity()

			// Big downloads may produce no output at all when brew runs without a terminal.
			// Push the timeout out for that phase. The watchdog deadline is monotonic
			// (max of current and proposed), so this long grace window is not shortened by
			// the routine noteActivity() calls that follow on each later output chunk.
			if let chunk = String(data: data, encoding: .utf8), chunk.contains("==> Downloading") {
				self.extendWatchdog(by: 30 * 60)
			}
		}

		// Reap the process exactly once, then finish.
		process.waitUntilExit()
		self.processDidTerminate(process)
	}

	/// Finishes the operation according to the termination state of the given process.
	private func processDidTerminate(_ process: Process) {
		// A cancelled operation finishes without error, mirroring the other update operations.
		// If the watchdog timed out earlier, its finish already claimed; this becomes a no-op.
		guard !self.isCancelled else {
			self.finish()
			return
		}

		if process.terminationReason == .exit && process.terminationStatus == 0 {
			// brew exits 0 even when it performed no upgrade (e.g. its install receipt
			// already matches the feed while the app bundle on disk differs). Surface
			// that instead of finishing silently, which would leave the update listed
			// forever with no explanation.
			let output = self.bufferedOutput?.lowercased() ?? ""
			if output.contains("already installed") || output.contains("not upgrading") || output.contains("already up-to-date") {
				self.finish(with: LatestError.homebrewUpgradeNotPerformed)
			} else {
				self.finish()
			}
		} else {
			self.finish(with: LatestError.homebrewUpgradeFailed(output: self.outputTail))
		}
	}


	// MARK: - Output Handling

	/// Appends the given chunk to the retained output tail.
	private func append(output data: Data) {
		self.outputLock.withCriticalScope {
			self.outputBuffer.append(data)

			// Only the tail is ever reported; cap the buffer so endless output cannot grow it.
			if self.outputBuffer.count > Self.maximumBufferedOutputLength {
				self.outputBuffer.removeFirst(self.outputBuffer.count - Self.maximumBufferedOutputLength)
			}
		}
	}

	/// The retained process output as a string, if any.
	private var bufferedOutput: String? {
		let data = self.outputLock.withCriticalScope { self.outputBuffer }
		guard let output = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }

		let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	/// A trimmed tail of the process output, suitable as the failure reason of an error.
	private var outputTail: String? {
		guard let output = self.bufferedOutput else { return nil }
		return String(output.suffix(Self.errorOutputTailLength))
	}

}
