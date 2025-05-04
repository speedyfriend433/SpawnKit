//
//  File.swift
//  SpawnKit
//
//  Created by 이지안 on 5/4/25.
//

import Foundation
import Darwin

/// Manages `posix_spawn_file_actions_t` for redirecting file descriptors.
internal class FileActions {
    internal var actions: posix_spawn_file_actions_t?
    private var pipesToCloseInParent: [Int32] = []

    init() throws {
        var act: posix_spawn_file_actions_t? = nil
        let result = posix_spawn_file_actions_init(&act)
        guard result == 0 else {
            throw ProcessError.fileActionError(errno: result, action: "init")
        }
        self.actions = act
    }

    deinit {
        if actions != nil {
            posix_spawn_file_actions_destroy(&actions)
        }
        // Ensure parent closes its ends of any created pipes
        for fd in pipesToCloseInParent {
            close(fd)
        }
    }

    /// Adds an action to open a file and assign it to a specific file descriptor in the child.
    func addOpen(fd: Int32, path: String, flags: Int32, mode: mode_t) throws {
        guard actions != nil else { throw ProcessError.setupError(description: "File actions not initialized") }
        let result = path.withCString { cPath in
            posix_spawn_file_actions_addopen(&actions, fd, cPath, flags, mode)
        }
        guard result == 0 else {
            throw ProcessError.fileActionError(errno: result, action: "addopen \(path) -> fd \(fd)")
        }
    }

    /// Adds an action to duplicate a file descriptor.
    func addDup2(sourceFd: Int32, targetFd: Int32) throws {
        guard actions != nil else { throw ProcessError.setupError(description: "File actions not initialized") }
        let result = posix_spawn_file_actions_adddup2(&actions, sourceFd, targetFd)
        guard result == 0 else {
            throw ProcessError.fileActionError(errno: result, action: "adddup2 \(sourceFd) -> \(targetFd)")
        }
    }

    /// Adds an action to close a file descriptor.
    func addClose(fd: Int32) throws {
        guard actions != nil else { throw ProcessError.setupError(description: "File actions not initialized") }
        let result = posix_spawn_file_actions_addclose(&actions, fd)
        guard result == 0 else {
            throw ProcessError.fileActionError(errno: result, action: "addclose \(fd)")
        }
    }

    /// Sets up redirection based on the `StandardStream` configuration.
    /// Manages pipe creation and tracks FDs to close in the parent.
    /// Returns the `FileHandle` for the parent's end of the pipe if `.pipe` was used.
    func setupRedirect(for stream: StandardStream, targetFd: Int32) throws -> FileHandle? {
        let representation = try resolveStreamRepresentation(stream: stream, targetFd: targetFd)
        var parentFileHandle: FileHandle? = nil

        switch representation {
        case .inherit:
             // Do nothing, child inherits parent's fd
             break
        case .fd(let sourceFd):
            // User provided a FileHandle (represented by its fd)
            if sourceFd != targetFd {
                try addDup2(sourceFd: sourceFd, targetFd: targetFd)
                // Important: We don't close the original sourceFd here, as the user might still need it.
                // Ownership remains with the caller.
            }
        case .path(let path, let flags):
            // Open the file path and assign it to targetFd
            // Mode 0644: rw-r--r--
            let mode: mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
            try addOpen(fd: targetFd, path: path, flags: flags, mode: mode)

        case .pipe(let readEnd, let writeEnd):
            // Determine which end the child needs and which the parent needs
            if targetFd == STDIN_FILENO { // Child reads from stdin
                try addDup2(sourceFd: readEnd, targetFd: STDIN_FILENO)
                try addClose(fd: writeEnd) // Child doesn't need the write end
                pipesToCloseInParent.append(readEnd) // Parent closes read end
                parentFileHandle = FileHandle(fileDescriptor: writeEnd, closeOnDealloc: true)
            } else { // Child writes to stdout/stderr (targetFd 1 or 2)
                try addDup2(sourceFd: writeEnd, targetFd: targetFd)
                try addClose(fd: readEnd) // Child doesn't need the read end
                pipesToCloseInParent.append(writeEnd) // Parent closes write end
                parentFileHandle = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
            }
        }
        return parentFileHandle
    }

    /// Converts `StandardStream` enum into an internal representation, creating pipes if necessary.
    private func resolveStreamRepresentation(stream: StandardStream, targetFd: Int32) throws -> StandardStream.Representation {
        switch stream {
        case .inherit:
            return .inherit
        case .nullDevice:
             // Open /dev/null for reading (if stdin) or writing (if stdout/stderr)
             let flags = (targetFd == STDIN_FILENO) ? O_RDONLY : O_WRONLY
             return .path("/dev/null", flags)
        case .pipe:
            var pipefd: [Int32] = [0, 0]
            let result = Darwin.pipe(&pipefd)
            guard result == 0 else {
                throw ProcessError.pipeCreationFailed(errno: errno)
            }
            // pipefd[0] is read end, pipefd[1] is write end
            return .pipe(readEnd: pipefd[0], writeEnd: pipefd[1])
        case .useHandle(let fh):
            // Use the file descriptor from the provided handle
             return .fd(fh.fileDescriptor)
        case .file(let path):
            // Open file for reading (stdin) or writing/creating/truncating (stdout/stderr)
            let flags = (targetFd == STDIN_FILENO) ? O_RDONLY : (O_WRONLY | O_CREAT | O_TRUNC)
            return .path(path, flags)
        }
    }
}
