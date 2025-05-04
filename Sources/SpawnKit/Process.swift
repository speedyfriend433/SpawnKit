//
//  Process.swift
//  SpawnKit
//
//  Created by 이지안 on 5/4/25.
//

import Foundation
import Darwin

/// Represents a running or terminated external process.
public class Process {

    /// The command or path that was executed.
    public let executablePath: String

    /// The arguments passed to the executable (including argv[0]).
    public let arguments: [String]

    /// The environment variables for the process. Nil means the parent environment was inherited.
    public let environment: [String: String]?

    /// The process identifier (PID) of the launched process. Valid only after `launch()` succeeds.
    public private(set) var processIdentifier: pid_t = 0

    /// The termination status code of the process. Valid only after the process has terminated and been waited for.
    public private(set) var terminationStatus: Int32 = -1

    /// Indicates if the process is still running. This is a snapshot in time.
    public var isRunning: Bool {
        guard processIdentifier > 0 else { return false }
        guard terminationStatus == -1 else { return false }

        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)

        if result == 0 {
            return true
        } else if result == processIdentifier {
            return false
        } else {
            if errno != ECHILD {
                 print("Warning: waitpid WNOHANG check failed for PID \(processIdentifier): \(strerror(errno) ?? "Unknown error") (\(errno))")
            }
            return false
        }
    }

    public private(set) var standardInput: FileHandle?
    public private(set) var standardOutput: FileHandle?
    public private(set) var standardError: FileHandle?

    private let stdinConfig: StandardStream
    private let stdoutConfig: StandardStream
    private let stderrConfig: StandardStream

    private var hasLaunched: Bool = false
    private var hasWaited: Bool = false
    private let processQueue = DispatchQueue(label: "com.appname.SpawnKit.process.wait_queue")

    /// Initializes a new Process instance configured to launch an executable.
    ///
    /// - Parameters:
    ///   - executableURL: URL pointing to the executable file.
    ///   - arguments: Command-line arguments. The executable name itself should typically be the first argument.
    ///   - environment: Environment variables. `nil` inherits parent environment, empty dictionary provides an empty environment.
    ///   - standardInput: Configuration for the process's standard input.
    ///   - standardOutput: Configuration for the process's standard output.
    ///   - standardError: Configuration for the process's standard error.
    public convenience init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        standardInput: StandardStream = .inherit,
        standardOutput: StandardStream = .inherit,
        standardError: StandardStream = .inherit
    ) throws {
        guard executableURL.isFileURL else {
            throw ProcessError.invalidExecutable(path: executableURL.absoluteString)
        }
        let path = executableURL.path
        let accessResult = path.withCString { cPath -> Int32 in
            return access(cPath, X_OK)
        }

        guard accessResult == 0 else {
            let errorNumber = errno
            if errorNumber == ENOENT {
                throw ProcessError.executableNotFound(name: path, path: nil)
            }
            throw ProcessError.posixSpawnError(errno: errorNumber, context: "Checking executable access for \(path)")
        }

        try self.init(
            command: path,
            arguments: arguments,
            environment: environment,
            searchPath: false,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }


    /// Initializes a new Process instance configured to launch a command.
    ///
    /// - Parameters:
    ///   - command: The name or path of the command to execute.
    ///   - arguments: Command-line arguments. If arguments is empty, `command` itself will be used as argv[0]. If not empty, the first element of `arguments` should typically be the command name.
    ///   - environment: Environment variables. `nil` inherits parent environment, empty dictionary provides an empty environment.
    ///   - searchPath: If `true`, searches the `PATH` environment variable to find the command if `command` doesn't contain a slash. If `false`, `command` must be a valid path.
    ///   - standardInput: Configuration for the process's standard input.
    ///   - standardOutput: Configuration for the process's standard output.
    ///   - standardError: Configuration for the process's standard error.
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        searchPath: Bool = true,
        standardInput: StandardStream = .inherit,
        standardOutput: StandardStream = .inherit,
        standardError: StandardStream = .inherit
    ) throws {

        let resolvedPath: String
        var actualSearchPath: String? = nil

        if searchPath && !command.contains("/") {
             if let pathEnv = getenv("PATH") {
                 actualSearchPath = String(cString: pathEnv)
             }
            guard let foundPath = try CInterop.findExecutable(named: command) else {
                throw ProcessError.executableNotFound(name: command, path: actualSearchPath)
            }
            resolvedPath = foundPath
        } else {
             guard access(command, X_OK) == 0 else {
                 if errno == ENOENT { throw ProcessError.executableNotFound(name: command, path: nil) }
                 throw ProcessError.posixSpawnError(errno: errno, context: "Checking executable access for \(command)")
            }
            resolvedPath = command
        }

        self.executablePath = resolvedPath

        if arguments.isEmpty {
            self.arguments = [resolvedPath]
        } else {
             self.arguments = arguments
             // if !arguments.isEmpty && (arguments[0] != command && arguments[0] != resolvedPath) { print warning? }
        }

        self.environment = environment
        self.stdinConfig = standardInput
        self.stdoutConfig = standardOutput
        self.stderrConfig = standardError
    }

    /// Launches the process asynchronously.
    ///
    /// - Throws: `ProcessError` if launching fails.
    public func launch() throws {
        guard !hasLaunched else {
            throw ProcessError.setupError(description: "Process has already been launched.")
        }

        let cArgv = CInterop.createCArray(from: self.arguments)
        defer { CInterop.freeCArray(cArgv) }

        let cEnvp = CInterop.createCEnvironment(from: self.environment)
        defer { CInterop.freeCArray(cEnvp!) }

        let fileActions = try FileActions()
        self.standardInput = try fileActions.setupRedirect(for: stdinConfig, targetFd: STDIN_FILENO)
        self.standardOutput = try fileActions.setupRedirect(for: stdoutConfig, targetFd: STDOUT_FILENO)
        self.standardError = try fileActions.setupRedirect(for: stderrConfig, targetFd: STDERR_FILENO)

        let attributes = try SpawnAttributes()
        // try attributes.setFlags(POSIX_SPAWN_...)

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid,
                                      executablePath,
                                      &fileActions.actions,
                                      &attributes.attributes,
                                      cArgv,
                                      cEnvp ?? environ
        )

        guard spawnResult == 0 else {
             throw ProcessError.posixSpawnError(errno: spawnResult, context: "calling posix_spawn for \(executablePath)")
        }
        self.processIdentifier = pid
        self.hasLaunched = true
    }

    /// Waits synchronously until the process terminates.
    /// Call this only after `launch()` has succeeded.
    ///
    /// - Throws: `ProcessError.waitpidError` if waiting fails, `ProcessError.setupError` if not launched.
    public func waitUntilExit() throws {
        guard hasLaunched else {
            throw ProcessError.setupError(description: "Process has not been launched.")
        }
        guard !hasWaited else {
            return
        }

        var status: Int32 = 0
        let waitResult = processQueue.sync {
             while true {
                 let result = waitpid(self.processIdentifier, &status, 0) // 0 flags = wait blocking
                 if result != -1 {
                     return result
                 }
                 if errno == EINTR {
                     print("SpawnKit: waitpid interrupted by signal (EINTR), retrying...")
                     continue
                 } else {
                     return result // Return -1 = error
                 }
             }
        }


        guard waitResult == self.processIdentifier else {
            // waitpid failed (returned -1 or unexpected pid like 0?)
            let errorNumber = errno
            hasWaited = true
            terminationStatus = -1
            if errorNumber == ECHILD {
                 print("SpawnKit Warning: waitpid failed with ECHILD for PID \(self.processIdentifier). Process already reaped?")
                 return
            }
            throw ProcessError.waitpidError(errno: errorNumber, context: "waiting for PID \(self.processIdentifier)")
        }

        self.terminationStatus = status
        hasWaited = true
    }


    // MARK: - Process Control (Signals) - Requires PID > 0

    /// Sends a signal to the process.
    /// - Parameter signal: The signal number (e.g., SIGTERM, SIGKILL, SIGINT).
    /// - Throws: `ProcessError` if sending the signal fails or process not launched.
    private func sendSignal(_ signal: Int32) throws {
         guard hasLaunched else { throw ProcessError.setupError(description: "Process not launched.") }

         if Darwin.kill(processIdentifier, signal) == -1 {
             let errorNumber = errno
             if errorNumber != ESRCH {
                 throw ProcessError.signalError(errno: errorNumber, signal: signal)
             } else {
                 print("SpawnKit: Signal \(signal) sent to PID \(processIdentifier), but process did not exist (ESRCH). Assumed already terminated.")
             }
         }
    }

    /// Sends the interrupt signal (SIGINT) to the process. (Like Ctrl+C)
    public func interrupt() throws {
        try sendSignal(SIGINT)
    }

    /// Sends the termination signal (SIGTERM) to the process, requesting graceful shutdown.
    public func terminate() throws {
        try sendSignal(SIGTERM)
    }

    /// Sends the kill signal (SIGKILL) to the process, forcing termination immediately.
    public func kill() throws {
        try sendSignal(SIGKILL)
    }

    /// Sends the suspend signal (SIGTSTP) to the process. (Like Ctrl+Z)
    public func suspend() throws {
        try sendSignal(SIGTSTP)
    }

     /// Sends the continue signal (SIGCONT) to the process.
    public func resume() throws {
        try sendSignal(SIGCONT)
    }

    // MARK: - Termination Status Helpers (after waitUntilExit)

    /// The exit code of the process if it terminated normally. Nil otherwise.
    public var normalExitCode: Int32? {
        guard hasWaited && WIFEXITED(terminationStatus) else { return nil }
        return WEXITSTATUS(terminationStatus)
    }

    /// The signal number that caused the process to terminate. Nil otherwise.
    public var terminationSignal: Int32? {
        guard hasWaited && WIFSIGNALED(terminationStatus) else { return nil }
        return WTERMSIG(terminationStatus)
    }

    /// True if the process terminated normally with an exit code.
    public var didExitNormally: Bool {
        return hasWaited && WIFEXITED(terminationStatus)
    }

    /// True if the process was terminated by a signal.
    public var wasTerminatedBySignal: Bool {
        return hasWaited && WIFSIGNALED(terminationStatus)
    }
}

// MARK: - Darwin Wait Status Macro Wrappers -

private func WIFEXITED(_ status: Int32) -> Bool {
    // From sys/wait.h: #define _WSTATUS(x) (_W_INT(x) & 0177) -> low 7 bits
    // #define WIFEXITED(x) (_WSTATUS(x) == 0)
    return (status & 0x7f) == 0
}

private func WEXITSTATUS(_ status: Int32) -> Int32 {
    // From sys/wait.h: #define WEXITSTATUS(x) (_W_INT(x) >> 8)
    return (status >> 8) & 0xff
}

private func WIFSIGNALED(_ status: Int32) -> Bool {
    // From sys/wait.h: #define WIFSIGNALED(x) (_WSTATUS(x) != _WSTOPPED && _WSTATUS(x) != 0)
    let wstatus = status & 0x7f
    return wstatus != 0 && wstatus != 0x7f // 0x7f (0177) is _WSTOPPED
}


private func WTERMSIG(_ status: Int32) -> Int32 {
    // From sys/wait.h: #define WTERMSIG(x) (_WSTATUS(x))
    return status & 0x7f
}

private func WIFSTOPPED(_ status: Int32) -> Bool {
    // From sys/wait.h: #define WIFSTOPPED(x) (_WSTATUS(x) == _WSTOPPED)
    return (status & 0x7f) == 0x7f // 0x7f (0177) is _WSTOPPED
}

private func WSTOPSIG(_ status: Int32) -> Int32 {
    // From sys/wait.h: #define WSTOPSIG(x) (_W_INT(x) >> 8)
    return (status >> 8) & 0xff
}

// _WSTOPPED constant based on sys/wait.h
// #define _WSTOPPED       0177 /* _WSTATUS if process is stopped */
// private let _WSTOPPED: Int32 = 0x7f // Hex for 0177 octal
