//
//  HomebrewUpdateOperationTest.swift
//  Latest Tests
//
//  Copyright © 2026 Max Langer. All rights reserved.
//

import XCTest
@testable import Latest

/// Exercises the termination state machine of `HomebrewUpdateOperation` with stub shell scripts
/// standing in for brew, so no real Homebrew is launched.
class HomebrewUpdateOperationTest: XCTestCase {

	private var directory: URL!

	override func setUpWithError() throws {
		self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomebrewUpdateOperationTest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: self.directory)
	}

	// MARK: - Tests

	func testTimeoutBeforeLaunchFinishesImmediately() {
		let operation = self.operation(script: "exit 0")

		operation.handleTimeout()

		XCTAssertTrue(operation.isFinished)
		XCTAssertTrue(Self.isTimeout(operation.error))
	}

	func testTimeoutAfterLaunchWaitsUntilBrewAndItsChildrenExited() throws {
		// brew takes a moment to wind down after SIGTERM, while its child dies right away.
		let operation = self.operation(script: """
		sleep 600 &
		echo $! > "\(self.directory.path)/child.pid"
		echo $$ > "\(self.directory.path)/brew.pid"
		trap 'sleep 1; exit 1' TERM
		wait
		""")
		try self.launch(operation)

		operation.handleTimeout()
		XCTAssertFalse(operation.isFinished, "The operation must not finish while brew is still running.")

		self.waitUntilFinished(operation, timeout: 10)
		XCTAssertTrue(Self.isTimeout(operation.error))
		XCTAssertFalse(self.isAlive(try self.pid(named: "brew.pid")))
		XCTAssertFalse(self.isAlive(try self.pid(named: "child.pid")), "brew's process group must be terminated as well.")
	}

	func testTimeoutKillsBrewIgnoringTermination() throws {
		// Ignored signals are inherited, so the whole process group ignores SIGTERM.
		let operation = self.operation(script: """
		trap '' TERM
		echo $$ > "\(self.directory.path)/brew.pid"
		while :; do sleep 1; done
		""", gracePeriod: 1)
		try self.launch(operation)

		let start = Date()
		operation.handleTimeout()

		self.waitUntilFinished(operation, timeout: 10)
		XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.9, "brew must be given the grace period to exit.")
		XCTAssertTrue(Self.isTimeout(operation.error))
		XCTAssertFalse(self.isAlive(try self.pid(named: "brew.pid")))
	}

	func testTimeoutKillsHelpersOutlivingBrew() throws {
		// brew exits on SIGTERM, leaving behind a helper that ignores it and keeps writing to the pipe.
		try self.assertTimeoutKillsHelperOutlivingBrew(helper: "while :; do echo tick; sleep 1; done")
	}

	func testTimeoutKillsSilentHelpersOutlivingBrew() throws {
		try self.assertTimeoutKillsHelperOutlivingBrew(helper: "while :; do sleep 1; done")
	}

	func testCancelAfterLaunchFinishesWithoutError() throws {
		let operation = self.operation(script: """
		echo $$ > "\(self.directory.path)/brew.pid"
		while :; do sleep 1; done
		""")
		try self.launch(operation)

		operation.cancel()

		self.waitUntilFinished(operation, timeout: 10)
		XCTAssertNil(operation.error)
		XCTAssertFalse(self.isAlive(try self.pid(named: "brew.pid")))
	}

	// MARK: - Helpers

	/// Times out a brew that exits on SIGTERM while the given helper ignores it, and asserts the
	/// operation finishes once brew is gone, well before the grace period, with the helper killed.
	private func assertTimeoutKillsHelperOutlivingBrew(helper: String, file: StaticString = #filePath, line: UInt = #line) throws {
		let operation = self.operation(script: """
		( trap '' TERM; \(helper) ) &
		echo $! > "\(self.directory.path)/child.pid"
		echo $$ > "\(self.directory.path)/brew.pid"
		while :; do sleep 1; done
		""", gracePeriod: 60)
		try self.launch(operation)
		let child = try self.pid(named: "child.pid")

		operation.handleTimeout()

		self.waitUntilFinished(operation, timeout: 10)
		XCTAssertTrue(Self.isTimeout(operation.error), file: file, line: line)
		XCTAssertFalse(self.isAlive(try self.pid(named: "brew.pid")), file: file, line: line)
		XCTAssertFalse(self.isAlive(child), "Helpers outliving brew must be killed before the operation finishes.", file: file, line: line)
	}

	/// Returns an operation running the given shell script in place of brew.
	private func operation(script: String, gracePeriod: TimeInterval = 15) -> HomebrewUpdateOperation {
		let url = self.directory.appendingPathComponent("brew-\(UUID().uuidString)")
		FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n\(script)\n".utf8), attributes: [.posixPermissions: 0o755])

		return HomebrewUpdateOperation(
			bundleIdentifier: "com.example.app",
			appIdentifier: URL(fileURLWithPath: "/Applications/Example.app"),
			caskToken: "example",
			brewURL: url,
			terminationGracePeriod: gracePeriod
		)
	}

	/// Starts the operation and waits until brew was launched and published, then until the
	/// script wrote its PID file.
	private func launch(_ operation: HomebrewUpdateOperation) throws {
		let launched = self.expectation(description: "brew launched")
		launched.assertForOverFulfill = false
		operation.progressHandler = { [unowned operation] _ in
			if case .installing = operation.progressState {
				launched.fulfill()
			}
		}

		operation.start()
		self.wait(for: [launched], timeout: 10)

		let pidFile = self.directory.appendingPathComponent("brew.pid").path
		self.wait(for: [self.expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: pidFile) }, evaluatedWith: nil)], timeout: 10)
		_ = try self.pid(named: "brew.pid")
	}

	private func waitUntilFinished(_ operation: HomebrewUpdateOperation, timeout: TimeInterval) {
		self.wait(for: [self.expectation(for: NSPredicate { _, _ in operation.isFinished }, evaluatedWith: nil)], timeout: timeout)
	}

	/// Reads the PID the script wrote into the given file.
	private func pid(named name: String) throws -> pid_t {
		let contents = try String(contentsOf: self.directory.appendingPathComponent(name), encoding: .utf8)
		return try XCTUnwrap(pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
	}

	/// Whether the process with the given PID still exists, allowing a moment for a killed
	/// orphan to be reaped by launchd.
	private func isAlive(_ pid: pid_t) -> Bool {
		for _ in 0..<50 {
			if kill(pid, 0) != 0 && errno == ESRCH {
				return false
			}
			usleep(100_000)
		}
		return true
	}

	private static func isTimeout(_ error: Error?) -> Bool {
		if case .updateTimedOut = error as? LatestError {
			return true
		}
		return false
	}

}
