//
//  File.swift
//  SpawnKit
//
//  Created by 이지안 on 5/4/25.
//

import Foundation
import Darwin

/// Manages `posix_spawnattr_t` for setting process spawn attributes.
internal class SpawnAttributes {
    internal var attributes: posix_spawnattr_t?

    init() throws {
        var attr: posix_spawnattr_t? = nil
        let result = posix_spawnattr_init(&attr)
        guard result == 0 else {
            throw ProcessError.attributeError(errno: result, action: "init")
        }
        self.attributes = attr
    }

    deinit {
        if attributes != nil {
            posix_spawnattr_destroy(&attributes)
        }
    }

    /// Set flags for the spawn operation (e.g., POSIX_SPAWN_SETSIGMASK).
    func setFlags(_ flags: Int16) throws {
        guard attributes != nil else { throw ProcessError.setupError(description: "Attributes not initialized") }
        let result = posix_spawnattr_setflags(&attributes, flags)
        guard result == 0 else {
            throw ProcessError.attributeError(errno: result, action: "setflags")
        }
    }

    // Add other attribute setters as needed (e.g., setpgroup, setsigmask, setsigdefault)
    //
    // func setSignalMask(_ mask: sigset_t) throws {
    //     var currentMask = mask 
    //     let result = posix_spawnattr_setsigmask(&attributes, ¤tMask)
    //     guard result == 0 else { throw ProcessError.attributeError(errno: result, action: "setsigmask") }
    // }
}
