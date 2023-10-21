//
//  main.swift
//  opaqueify
//
//  Created by John Holdsworth on 18/10/2023.
//  Copyright © 2023 John Holdsworth. All rights reserved.
//
//  Repo: https://github.com/johnno1962/Refactorator
//

import Foundation
import Popen

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
let (protocols, files) = extractProtocols(from: project, commands: commands)
let protoRegexp =
    #"\b(\#(protocols.keys.joined(separator: "|")))\b"#

var edits = 0
for (file, syntax) in files {
    // re-use the syntax map to find the patches to any/some
    let patches = process(syntax: syntax, for: file, 
        protocols: protocols, protoRegexp: protoRegexp)
    if patches.count != 0, // apply any patches and save
        var patched = apply(patches: patches, to: file)?[
            // is/as seem to get missed by the syntax tree
            #"(\s+(?:is|as[?!]?)\s+)(\#(protoRegexp))"#, "$1any $2"] {
        for _ in 1...5 {
            // @objc or cases cannot have generic params
            // allow case .some though
            patched[#"(?:@objc|\bcase)\s+.*[^\.]\b(some)\b"#]
                = "any"
        }
        try? patched.write(toFile: file,
                           atomically: true, encoding: .utf8)
        edits += patches.count
    }
}

// Second pass, use compiler errors for further patching..
if argv.count > 2 {
    let xcode = argv[2]
    _ = pclose(popen("""
        cd "\(project.deletingLastPathComponent().path)"; \
        git add .
        """, "w"))
    for _ in 1...10 {
        let phaseTwo = extractAnyErrors(project: project, xcode: xcode)

        var reedits = 0
        for (file, patches) in phaseTwo {
            if let patched = addressErrors(file: file, patches: patches) {
                if file.contains("/checkouts/") {
                    print("Having to patch file in dependency:",
                          file, patches)
                    chmod(file, 0o644)
                }
                try? patched.write(toFile: file,
                                   atomically: true, encoding: .utf8)
            }
            reedits += patches.count
//            print(retry, reedits, file, patches)
        }

        if reedits == 0 {
            break
        }
    }
}

print(edits, "edits in",
      Date.timeIntervalSinceReferenceDate-start, "seconds")
