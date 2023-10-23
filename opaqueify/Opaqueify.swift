//
//  Opaqueify.swift
//  opaqueify
//
//  Created by John Holdsworth on 18/10/2023.
//  Copyright © 2023 John Holdsworth. All rights reserved.
//
//  Repo: https://github.com/johnno1962/opaqueify
//

import Foundation
// Defines a subscript of a string by a raw
// string which is interpreted as a regex.
import SwiftRegex // See https://github.com/johnno1962/SwiftRegex5
import Popen // To read lines from the build process.
#if SWIFT_PACKAGE
import SourceKitHeader
#endif

let sourceKit = SourceKit(logRequests: false)

func extract(build: String) -> [String] {
    guard let stdout = popen(build, "r") else {
        print("⚠️ Could not launch \(build)")
        return []
    }

    var commands = [String]()
    while let line = stdout.readLine() {
        if line.contains(" -primary-file ") {
            commands.append(line)
        }
    }

    _ = pclose(stdout)
    return commands
}

func lastLog(project: URL) -> String? {
    let projectName = project
        .deletingPathExtension().lastPathComponent
    let search = "ls -t ~/Library/Developer/Xcode/DerivedData/\(projectName)-*/Logs/Build/*.xcactivitylog"
    guard let logs = popen(search, "r"),
          let log = logs.readLine() else {
        print("⚠️ Could not find logs using: \(search)")
        return nil
    }

    _ = pclose(logs)
    return log
}

func build(project: URL, xcode: String? = nil) -> [String] {
    let build: String
    if project.lastPathComponent == "Package.swift" {
        build = "rm -rf .build; swift build -v"
    } else if let log = lastLog(project: project) {
        build = "/usr/bin/gunzip <\(log) | /usr/bin/tr '\\r' '\\n'"
    } else {
        let xcbuild = (xcode ?? "/Applications/Xcode.app") + "/Contents/Developer/usr/bin/xcodebuild"
        build = "\(xcbuild) clean; \(xcbuild) -project \(project.lastPathComponent)"
    }

    let root = project.deletingLastPathComponent().path
    return extract(build: """
        cd "\(root)" && \(build) 2>&1 | /usr/bin/tee /tmp/build.txt
        """)
}

var argumentsToRemove = Set([
        #"-target-sdk-version \S+ "#,
        #"-target-sdk-name \S+ "#,
        "-Xccerror",
        #"-I\S+ "#,
])

typealias ProtocolInfo = [String: String]

func extractProtocols(from project: URL, commands: [String])
    -> (ProtocolInfo, [String: sourcekitd_variant_t]) {
    var protocolInfo = ["Error": "$ss5ErrorP"]
    var fileSyntax = [String: sourcekitd_variant_t]()
    guard let root = try? project.deletingLastPathComponent()
            .resourceValues(forKeys: [.canonicalPathKey])
            .canonicalPath,
          let enumerator = FileManager.default.enumerator(atPath: root) else {
        fatalError("⚠️ Bad path to project: \(project)")
    }

    for relative in enumerator {
        guard let relative = relative as? String else { continue }
        let fullpath = URL(fileURLWithPath: relative,
            relativeTo: URL(fileURLWithPath: root))
        guard fullpath.path.hasSuffix(".swift") else {
            continue
        }

        if let source = try? String(contentsOfFile: fullpath.path) {
            for proto: String in
                source[#"\bprotocol\s+(\w+)\b"#]
                where protocolInfo[proto] == nil {
                protocolInfo[proto] = fullpath.path
            }
        }

        let resp = sourceKit.syntaxMap(filePath: fullpath.path, subSyntax: true)
//        SKApi.response_description_dump(resp)
        let dict = SKApi.response_get_value(resp)
        fileSyntax[fullpath.path] = dict

        guard var command = commands.first(where: {
            $0.contains(" -primary-file \(fullpath.path) ") }) else {
            if !fullpath.path[#"/Tests/|\.build/|Examples?/"#] {
                print("Missing compiler args for \(fullpath.path)")
            }
            continue
        }

        print("Processing", fullpath.relativePath,
              protocolInfo.count, "protocols"); fflush(stdout)
        sourceKit.recurseOver(childID: sourceKit.structureID,
                              resp: dict) { node in
            let offset = node.getInt(key: sourceKit.offsetID)

            while node.getString(key: sourceKit.typenameID) != nil {
                command[""+argumentsToRemove
                    .joined(separator: "|")] = ""

                let options = Array(command.components(
                    separatedBy: " ").dropFirst(2))

                let info = sourceKit.cursorInfo(filePath: fullpath.path, byteOffset: Int32(offset), compilerArgs: sourceKit.array(argv: options))
                if let error = sourceKit.error(resp: info) {
                    let toRemove = argumentsToRemove.count
                    for argh: String in error[
                        #"(?:unknown argument:|error: option) '([^']*)'"#] {
                        argumentsToRemove.insert(argh
                            .replacingOccurrences(of: "\\", with: "\\\\"))
                    }
                    for argh: String in error[
                        #"(?:unexpected|duplicate) input file: '(.*?)'?error:"#] {
                        argumentsToRemove.insert(argh)
                    }
                    if argumentsToRemove.count > toRemove {
                        continue
                    }
                    print(error)
                    break
                }
                let dict = SKApi.response_get_value(info)
                if let notes = dict.getString(key: sourceKit.fullyAnnotatedID) ?? node.getString(key: sourceKit.annotatedID),
                   notes.contains("ref.protocol") {
//                    print(notes)
                    for (usr, name): (String, String) in notes[
                        #"<ref.protocol usr=\"[sc]:([^"]*)\">([^<]*)</ref.protocol>"#] {
                        protocolInfo[name] = "$s"+usr
                    }
                }

                break
            }
        }
    }

    protocolInfo["Sendable"] = nil
    protocolInfo["Sequence"] = nil
    protocolInfo["Collection"] = nil
    return (protocolInfo, fileSyntax)
}

typealias Replace = (from: String, to: String)
typealias Patch = (offset: Int, replace: Replace)

func process(syntax: sourcekitd_variant_t, for fullpath: String,
             protocols: ProtocolInfo, protoRegex: String,
             decider: @escaping (
                _ proto: String, _ context: String,
                _ type: String, _ protocols: ProtocolInfo)
             -> String) -> [Patch] {
    var patches = [Patch]()

    sourceKit.recurseOver(childID: sourceKit.structureID,
                          resp: syntax) { node in
        let offset = node.getInt(key: sourceKit.offsetID)
        if let kind = node.getUUIDString(key: sourceKit.kindID),
           let type = node.getString(key: sourceKit.typenameID),
           let proto: String = type[protoRegex] {
            // Elide this parameter to some/any?
            let prefix = decider(proto, kind, type, protocols)
            patches.append((offset: offset, (
                             from: proto, to: prefix+"$1")))
        }
    }

//    print("PATCHES", patches)
    return patches
}

func apply(patches: [Patch], for file: String, applier:
    (_ line: inout String,
     _ patch: Replace) -> ()) -> String? {
    guard let data = NSMutableData(contentsOfFile: file) else {
        return nil
    }

    var zero: Int8 = 0
    data.append(&zero, length: 1)

    let bytes = UnsafeMutablePointer<CChar>(mutating:
        data.bytes.assumingMemoryBound(to: CChar.self))

    var parts = [String]() // apply patches in reverse order
    for (offset, patch) in patches.sorted(by: { $0.0 > $1.0 }) {
        var lines = String(cString: bytes+offset)
            .components(separatedBy: "\n")
        defer {
            parts.append(lines.joined(separator: "\n"))
        }
        bytes[offset] = 0
        
        let before = String(cString: bytes)
        guard !before[#"<\#(patch.from): "#] else { continue }
        applier(&lines[0], patch)
    }

    parts.append(String(cString: bytes))
    return parts.reversed().joined()[#"some some"#, "some"]
}

typealias ErrorPatch = (line: Int, col: Int, replace: Replace)

func addressErrors(file: String, patches: [ErrorPatch]) -> String? {
    guard var source = try? String(contentsOfFile: file) else {
        print("Could not open file: \(file)")
        return nil
    }

    for patch in patches.sorted(by: { $0.line > $1.line }) {
        source[patch.replace.from] = [patch.replace.to]
    }

    return source
}
