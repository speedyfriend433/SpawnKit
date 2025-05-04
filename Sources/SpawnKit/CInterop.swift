//
//  File.swift
//  SpawnKit
//
//  Created by 이지안 on 5/4/25.
//

import Foundation
import Darwin

internal enum CInterop {

    /// Creates a null-terminated C array of C strings from a Swift String array.
    /// Caller is responsible for freeing the memory using `freeCArray`.
    static func createCArray(from swiftArray: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let count = swiftArray.count
        let cArray = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)

        for (index, element) in swiftArray.enumerated() {
            guard let cString = strdup(element) else {
                // Uh memory allocation failed. Clean up what we've done so far lol.
                print("Error: strdup failed for element '\(element)'. Cleaning up.")
                for i in 0..<index {
                    free(cArray[i])
                }
                cArray.deallocate()
                 fatalError("strdup failed during C array creation")
                // for i in 0..<index { free(cArray[i]) }
                // cArray.deallocate()
                // return nil
            }
            cArray[index] = cString
        }
        cArray[count] = nil
        return cArray
    }

    /// Creates a null-terminated C array for environment variables (`KEY=VALUE`).
    /// Caller is responsible for freeing the memory using `freeCArray`.
    static func createCEnvironment(from environment: [String: String]?) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
        guard let env = environment else {
            return nil
        }

        let count = env.count
        let cArray = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
        var index = 0
        for (key, value) in env {
            let entry = "\(key)=\(value)"
            guard let cString = strdup(entry) else {
                print("Error: strdup failed for environment entry '\(entry)'. Cleaning up.")
                for i in 0..<index {
                    free(cArray[i])
                }
                cArray.deallocate()
                fatalError("strdup failed during C environment creation")
            }
            cArray[index] = cString
            index += 1
        }
        cArray[count] = nil
        return cArray
    }

    /// Frees the memory allocated by `createCArray` or `createCEnvironment`.
    static func freeCArray(_ cArray: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var index = 0
        while let pointer = cArray[index] {
            free(pointer)
            index += 1
        }
        cArray.deallocate()
    }

    /// Searches the PATH environment variable for an executable.
    /// Returns the full path if found and executable, otherwise nil.
    static func findExecutable(named name: String) throws -> String? {
        if name.contains("/") {
            guard access(name, X_OK) == 0 else {
                if errno == ENOENT { return nil }
                throw ProcessError.posixSpawnError(errno: errno, context: "Checking direct executable path '\(name)' access")
            }
             return name
        }

        guard let pathEnv = getenv("PATH") else {
            return nil
        }
        let searchPaths = String(cString: pathEnv).split(separator: ":").map(String.init)

        for dir in searchPaths {
             guard !dir.isEmpty else { continue }
            let fullPath = (dir as NSString).appendingPathComponent(name)
            if access(fullPath, X_OK) == 0 {
                return fullPath
            } else {
                 if errno != ENOENT {
                     print("Warning: access check failed for \(fullPath) with errno \(errno): \(String(cString: strerror(errno)))")
                 }
            }
        }
        return nil
    }
}
