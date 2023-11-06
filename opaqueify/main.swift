//
//  main.swift
//  opaqueify
//
//  Created by John Holdsworth on 18/10/2023.
//  Copyright © 2023 John Holdsworth. All rights reserved.
//
//  Repo: https://github.com/johnno1962/opaqueify
//

import Foundation
import Fortify // Catch fatal errors and stack trace
#if SWIFT_PACKAGE
import Opaqueifier
#endif

let argv = CommandLine.arguments

guard argv.count > 1 else {
    print("Usage: \(argv[0]) <project> [/Apllications/Xcode15.app]")
    exit(EXIT_FAILURE)
}

do {
    try Fortify.protect {
        exit(Opaqueifier().main(projectPath: argv[1],
                                xcode15Path: argv.count > 2 ? argv[2] : nil,
                knownPotocols: [objcCocoaProtocols, objcUIKitProtocols]))
    }
} catch {
    if let info = (error as NSError)
        .userInfo[NSLocalizedDescriptionKey] {
        print(info)
    }
    print("""
        🔥 Oh noes, the script has crashed. Please file an issue at \
        https://github.com/johnno1962/opaqueify with this debug \
        information along with the URL of the repo if possible.
        """)
    exit(EXIT_FAILURE)
}
