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
/// the upgrade fails. Once brew was launched, the operation only finishes after brew exited — even
/// on cancellation or timeout — as the update queue starts the next brew upgrade right after.
/// The only exception is a brew that survives even SIGKILL, which must not block the queue forever.
final class HomebrewUpdateOperation: UpdateOperation, @unchecked Sendable {

	/// The maximum amount of process output retained for error reporting.
	private static let maximumBufferedOutputLength = 8192

	/// The length of the output tail attached to failure messages.
	private static let errorOutputTailLength = 500

	/// The token identifying the cask to be upgraded.
	private let caskToken: String

	/// The location of the brew executable, resolved at check time.
	private let brewURL: URL

	/// The time brew is given to exit after SIGTERM before it is killed.
	private let terminationGracePeriod: TimeInterval

	/// The running brew process. Guarded by `processLock`.
	private var process: Process?

	/// The process group led by brew, nil if brew does not lead its own group. Guarded by `processLock`.
	private var processGroup: pid_t?

	/// Whether the watchdog timed out the operation. Guarded by `processLock`.
	private var timedOut = false

	/// Whether brew was asked to terminate. Guarded by `processLock`.
	private var terminationRequested = false

	/// Whether brew exited, was reaped and, if terminated, its remaining group was killed. Its PID,
	/// and with it its process group ID, may then be reused by an unrelated process, so no more
	/// signals may be sent. Guarded by `processLock`.
	private var processExited = false

	/// Serializes the launch of brew with cancellation and timeout.
	private let processLock = NSLock()

	/// The tail of the combined standard output and error of the process. Guarded by `outputLock`.
	private var outputBuffer = Data()

	/// Protects `outputBuffer`.
	private let outputLock = NSLock()

	/// Initializes the operation for the given app, updating the cask with the given token.
	init(bundleIdentifier: String, appIdentifier: App.Bundle.Identifier, caskToken: String, brewURL: URL, terminationGracePeriod: TimeInterval = 15) {
		self.caskToken = caskToken
		self.brewURL = brewURL
		self.terminationGracePeriod = terminationGracePeriod
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
		// execute() and by the launch check in runBrew, which runs under the same lock.
		self.terminateBrew()
	}

	override func deferTimeoutFinish() -> Bool {
		// Recorded under the launch lock, so runBrew either sees it and never launches brew,
		// or has already published the process.
		let isLaunched = self.processLock.withCriticalScope { () -> Bool in
			self.timedOut = true
			return self.process != nil
		}

		// Before launch there is nothing to wait for; the base class finishes right away.
		guard isLaunched else { return false }

		// Finishing now would let the update queue start the next brew upgrade while this one
		// still holds Homebrew's lock, failing it as "already locked". Terminate brew instead;
		// the drain loop finishes with the timeout error once brew exited and was reaped.
		self.terminateBrew()
		return true
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

		guard self.launch(process) else { return }

		// Defensive post-launch check: terminate brew should the operation have been cancelled,
		// timed out or finished regardless, and suppress the .installing progress for it.
		// processDidTerminate remains the sole post-launch finish site (barring the last-resort
		// backstop in terminateBrew) — we only terminate here; the drain loop reaps and finishes.
		let timedOut = self.processLock.withCriticalScope { self.timedOut }
		if self.isCancelled || self.isFinished || timedOut {
			self.terminateBrew()
		} else {
			self.progressState = .installing
		}

		// Drain the combined output before waiting on the process — waiting first could
		// deadlock once the pipe buffer fills up. Each chunk feeds the watchdog so long
		// downloads are not mistaken for a stall. Each wait is bounded with poll(2), in short
		// slices so a termination requested meanwhile is noticed promptly: brew's children
		// (e.g. curl) inherit the pipe's write end and can keep it open after brew itself
		// was terminated, so waiting for EOF alone could hang forever.
		let handle = pipe.fileHandleForReading
		while true {
			// Once brew was told to stop, its output no longer matters. Stop draining as soon as
			// brew is gone (a surviving helper may keep writing to the pipe indefinitely), or once
			// the operation was given up on because brew could not be killed.
			let isTerminating = self.processLock.withCriticalScope { self.terminationRequested }
			if isTerminating && (!process.isRunning || self.isFinished) { break }

			var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
			let result = poll(&descriptor, 1, 1_000)

			guard result > 0 else {
				// Timeout or signal: keep draining while brew itself is alive. Once it is
				// gone and its output was read, silent stragglers holding the pipe are not
				// worth waiting for.
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

		// brew could not be killed and the operation was finished regardless; don't block on it.
		if self.isFinished && process.isRunning { return }

		// Reap the process exactly once, then finish.
		process.waitUntilExit()
		self.processLock.withCriticalScope {
			// A terminated brew's helpers may outlive it, still holding Homebrew's lock (and the
			// pipe). Kill them before the queue moves on. The group ID cannot be reused while any
			// of them exists, and this runs right after brew was reaped.
			if self.terminationRequested, let group = self.processGroup {
				killpg(group, SIGKILL)
			}
			self.processExited = true
		}
		self.processDidTerminate(process)
	}

	/// Launches and publishes the process, or finishes the operation and returns false if it
	/// was not launched.
	///
	/// Runs under the lock cancel() and the timeout take: they either see the published process
	/// and terminate it, or are seen here and brew is never launched. The lock is held only for
	/// the spawn itself, never while brew runs.
	private func launch(_ process: Process) -> Bool {
		self.processLock.lock()
		guard !self.isCancelled, !self.timedOut else {
			self.processLock.unlock()
			self.finish()
			return false
		}
		do {
			try process.run()
		} catch {
			self.processLock.unlock()
			self.finish(with: error)
			return false
		}
		self.process = process
		// Foundation launches the child as the leader of a new process group.
		let pid = process.processIdentifier
		self.processGroup = getpgid(pid) == pid ? pid : nil
		self.processLock.unlock()
		return true
	}

	/// Finishes the operation according to the termination state of the given process.
	private func processDidTerminate(_ process: Process) {
		guard !self.finishIfInterrupted() else { return }

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

	/// Finishes a timed-out or cancelled operation. Returns false if it was neither.
	private func finishIfInterrupted() -> Bool {
		// The watchdog deferred its finish to here (see deferTimeoutFinish), so the queue only
		// moves on once brew is gone. Report the same error as an immediate timeout would.
		let timedOut = self.processLock.withCriticalScope { self.timedOut }
		if timedOut {
			self.finish(with: LatestError.updateTimedOut)
			return true
		}

		// A cancelled operation finishes without error, mirroring the other update operations.
		if self.isCancelled {
			self.finish()
			return true
		}

		return false
	}

	// MARK: - Terminating Brew

	/// Asks brew to exit, killing it should it still run after the grace period.
	///
	/// A no-op before launch, after brew was reaped, and on repeated calls — a second SIGTERM
	/// could interrupt brew's cleanup, such as releasing its locks. Never waits for the process.
	private func terminateBrew() {
		let terminated = self.processLock.withCriticalScope { () -> Bool in
			guard !self.terminationRequested, let process = self.process, self.send(SIGTERM, to: process) else { return false }
			self.terminationRequested = true
			return true
		}
		guard terminated else { return }

		// Escalate so the operation, and with it the brew queue, is guaranteed to finish even if
		// brew ignores or hangs on SIGTERM. Helpers outliving brew are killed once it was reaped.
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.terminationGracePeriod) {
			let isKilled = self.processLock.withCriticalScope { () -> Bool in
				guard let process = self.process else { return false }
				return self.send(SIGKILL, to: process)
			}
			guard isKilled else { return }

			// Last resort: should brew survive even SIGKILL (stuck in an uninterruptible kernel
			// wait), stop blocking the brew queue and finish regardless.
			DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.terminationGracePeriod) {
				let isRunning = self.processLock.withCriticalScope { !self.processExited && self.process?.isRunning == true }
				if isRunning && !self.finishIfInterrupted() {
					self.finish()
				}
			}
		}
	}

	/// Sends the given signal to brew's process group. Returns false if brew already exited.
	///
	/// Must be called with `processLock` held, which keeps `processExited` stable.
	private func send(_ signal: Int32, to process: Process) -> Bool {
		// Once brew was reaped, the drain loop takes care of its remaining group.
		guard !self.processExited, process.isRunning else { return false }

		// Signal the whole group, not just brew: Homebrew's locks are flock(2) locks owned by the
		// open file, which brew's forked helpers (cask installs via Utils.safe_fork, the auto-update
		// shell and its git/curl children) share. A helper outliving a killed brew would keep the
		// lock held. Tools brew execs into groups of their own don't inherit the locks
		// (close-on-exec). Fall back to brew alone should it ever not lead its own group.
		if let group = self.processGroup {
			killpg(group, signal)
		} else {
			kill(process.processIdentifier, signal)
		}
		return true
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
