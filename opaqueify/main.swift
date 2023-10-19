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

let start = Date.timeIntervalSinceReferenceDate
let argv = CommandLine.arguments

guard argv.count > 1 else {
    print("Usage: \(argv[0]) <project>")
    exit(1)
}

let project = URL(fileURLWithPath: argv[1])

// First build the package so we can determine
// the Swift compiler arguments for SourceKit.
let commands = build(project: project)

// Use a combination of the syntax map and
// Cursor-info requests to determine the
// set of identifiers that are protocols.
let (protocolMap, files) = extractProtocols(from: project, commands: commands)

var edits = 0
for (file, syntax) in files {
    // re-use the syntax map to find the patches to any/some
    let patches = process(syntax: syntax, for: file, protocols: protocolMap)
    if patches.count != 0, // apply any patches and save
        let patched = apply(patches: patches, to: file) {
        try? patched.write(toFile: file,
                           atomically: true, encoding: .utf8)
        edits += patches.count
    }
}

print(edits, "edits in",
      Date.timeIntervalSinceReferenceDate-start, "seconds")
