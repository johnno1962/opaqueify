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
import DLKit // To determine system protocols.
#if SWIFT_PACKAGE
import SourceKitHeader
#endif

let sourceKit = SourceKit(logRequests: false)

let stagePhaseOnce: () = {
//    print(Popen.system("git add .") ?? "⚠️ Stage failed", terminator: "")
}()

func extract(build: String) -> [String] {
    guard let stdout = Popen(cmd: build) else {
        print("⚠️ Could not launch \(build)")
        return []
    }

    var commands = [String]()
    for line in stdout {
        if line.contains(" -primary-file ") {
            commands.append(line)
        }
    }

    if !stdout.terminatedOK() {
        print("⚠️ Build failed: \(build)")
    }
    return commands
}

func lastLog(project: URL) -> String? {
    let projectName = project
        .deletingPathExtension().lastPathComponent
    let search = "ls -t ~/Library/Developer/Xcode/DerivedData/\(projectName)-*/Logs/Build/*.xcactivitylog"
    guard let logs = Popen(cmd: search),
          let log = logs.readLine() else {
        print("⚠️ Could not find logs using: \(search)")
        return nil
    }

    return log
}

import Cocoa

let CocoaProtocols = {
    _ = NSWindow() // force load of Cocoa
    var names = [String: String]()
    "_OBJC_PROTOCOL_$_".withCString { prefix in
        let len = strlen(prefix)
        for entry in DLKit.allImages
            .entries(withPrefix: prefix) {
            names[String(cString: entry.name+len)]
                = entry.imageNumber.imageKey
        }
    }
    return names
}()

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

    return extract(build: "\(build) 2>&1 | /usr/bin/tee /tmp/build.txt")
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
    var protocols = ["Error": "$ss5ErrorP"]
    var fileSyntax = [String: sourcekitd_variant_t]()
    let root = project.deletingLastPathComponent().path
    guard let enumerator =
        FileManager.default.enumerator(atPath: root) else {
        fatalError("⚠️ Could not enumerate \(project)")
    }
        
//    var primaryFiles = Set<String>()
//    for command in commands {
//        for primaryFile: String in command[#"-primary-file (\S+\.swift) "#] {
//            primaryFiles.insert(primaryFile)
//            if let source = try? String(contentsOfFile: primaryFile) {
//                for proto: String in
//                    source[#"\bprotocol\s+(\w+)\b"#]
//                    where protocolInfo[proto] == nil {
//                    protocolInfo[proto] = primaryFile
//                }
//            }
//        }
//    }

    for relative in enumerator {
        guard let relative = relative as? String else { continue }
        let fullURL = URL(fileURLWithPath: relative,
            relativeTo: URL(fileURLWithPath: root))
        guard fullURL.path.hasSuffix(".swift") else {
            continue
        }

        if let source = try? String(contentsOf: fullURL) {
            for proto: String in
                source[#"\bprotocol\s+(\w+)\b"#]
                where protocols[proto] == nil {
                protocols[proto] = fullURL.relativePath
            }
        }

        let resp = sourceKit.syntaxMap(filePath: fullURL.path, subSyntax: true)
//        SKApi.response_description_dump(resp)
        let dict = SKApi.response_get_value(resp)
        fileSyntax[fullURL.path] = dict

        guard var command = commands.first(where: {
            $0.contains(" -primary-file \(fullURL.path) ") }) else {
            if !fullURL.path[#"/Tests/|\.build/|Examples?/"#] {
                print("Missing compiler args for \(fullURL.path)")
            }
            continue
        }

        print("Processing", fullURL.relativePath,
              protocols.count, "protocols"); fflush(stdout)
        continue // no longer use Cursor-Info requests

        sourceKit.recurseOver(childID: sourceKit.structureID,
                              resp: dict) { node in
            let offset = node.getInt(key: sourceKit.offsetID)

            while node.getString(key: sourceKit.typenameID) != nil {
                command[""+argumentsToRemove
                    .joined(separator: "|")] = ""

                let args = Array(command.components(
                    separatedBy: " ").dropFirst(2))

                let info = sourceKit.cursorInfo(filePath:
                    fullURL.path, byteOffset: Int32(offset),
                    compilerArgs: sourceKit.array(argv: args))
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
                if let notes = dict.getString(key: sourceKit.fullyAnnotatedID) ??
                               dict.getString(key: sourceKit.annotatedID),
                   notes.contains("ref.protocol") {
//                    print(notes)
                    for (usr, name): (String, String) in notes[
                        #"<ref.protocol usr=\"[sc]:([^"]*)\">([^<]*)</ref.protocol>"#] {
                        protocols[name] = "$s"+usr
                    }
                }

                break
            }
        }
    }

    return (protocols, fileSyntax)
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
        print("⚠️ Could not read file: \(file)")
        return nil
    }

    for patch in patches.sorted(by: { $0.line > $1.line }) {
        source[patch.replace.from] = [patch.replace.to]
    }

    return source
}
