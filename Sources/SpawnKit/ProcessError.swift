//
//  File.swift
//  SpawnKit
//
//  Created by 이지안 on 5/4/25.
//

import Foundation

public enum ProcessError: Error, LocalizedError {
    case posixSpawnError(errno: Int32, context: String)
    case waitpidError(errno: Int32, context: String)
    case invalidExecutable(path: String)
    case executableNotFound(name: String, path: String?)
    case setupError(description: String)
    case pipeCreationFailed(errno: Int32)
    case fileActionError(errno: Int32, action: String)
    case attributeError(errno: Int32, action: String)
    case signalError(errno: Int32, signal: Int32)

    public var errorDescription: String? {
        switch self {
        case .posixSpawnError(let errno, let context):
            return "posix_spawn failed during \(context): \(ProcessError.errnoToString(errno)) (\(errno))"
        case .waitpidError(let errno, let context):
            return "waitpid failed during \(context): \(ProcessError.errnoToString(errno)) (\(errno))"
        case .invalidExecutable(let path):
            return "Invalid executable path provided: \(path)"
        case .executableNotFound(let name, let path):
            let pathInfo = path != nil ? " (Searched PATH: \(path!))" : ""
            return "Executable '\(name)' not found\(pathInfo)."
        case .setupError(let description):
            return "Process setup error: \(description)"
        case .pipeCreationFailed(let errno):
            return "Failed to create pipe: \(ProcessError.errnoToString(errno)) (\(errno))"
        case .fileActionError(let errno, let action):
            return "File action '\(action)' failed: \(ProcessError.errnoToString(errno)) (\(errno))"
        case .attributeError(let errno, let action):
            return "Attribute action '\(action)' failed: \(ProcessError.errnoToString(errno)) (\(errno))"
        case .signalError(let errno, let signal):
             return "Sending signal \(signal) failed: \(ProcessError.errnoToString(errno)) (\(errno))"
        }
    }

    private static func errnoToString(_ errno: Int32) -> String {
        if let cString = strerror(errno) {
            return String(cString: cString)
        } else {
            return "Unknown error"
        }
    }
}
