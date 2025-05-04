//
//  File.swift
//  SpawnKit
//
//  Created by 이지안 on 5/4/25.
//

import Foundation

public enum StandardStream {
    /// Inherit the corresponding stream from the parent process. (Default)
    case inherit

    /// Redirect the stream to /dev/null.
    case nullDevice

    /// Create a pipe for communication. The corresponding `FileHandle` will be available
    /// via `Process.standardInput`, `Process.standardOutput`, or `Process.standardError`.
    case pipe

    /// Use the provided `FileHandle` for the stream. The ownership and closing
    /// of this handle remain the responsibility of the caller *after* the process finishes.
    /// The handle *must* be valid when `launch()` is called.
    case useHandle(FileHandle)

    /// Redirect the stream to or from a file at the specified path.
    /// For `.standardInput`, the file will be opened for reading.
    /// For `.standardOutput` and `.standardError`, the file will be opened for writing,
    /// created if it doesn't exist, and truncated if it does.
    /// - Important: Ensure the app has the necessary sandbox permissions to access the path.
    case file(path: String)

    internal enum Representation {
        case inherit
        case fd(Int32)
        case path(String, Int32) // Path and open flags (e.g., O_RDONLY, O_WRONLY | O_CREAT | O_TRUNC)
        case pipe(readEnd: Int32, writeEnd: Int32) // read/write ends *of the pipe*
    }

    internal func createFileHandleIfNeeded() -> FileHandle? {
        switch self {
        case .pipe:
            return nil
        case .useHandle(let fh):
            return fh
        default:
            return nil
        }
    }
}
