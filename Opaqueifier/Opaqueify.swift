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

extension Opaqueifier { // Was originally a script, now encapsulated in a class

func extract(build: String) -> [String] {
    guard let stdout = Popen(cmd: build) else {
        log("⚠️ Could not launch \(build)")
        return []
    }

    let commands = stdout.filter { $0.contains(" -primary-file ") }

    if !stdout.terminatedOK() {
        log("⚠️ Build failed: \(build)")
    }
    return commands
}

func lastLog(project: URL) -> String? {
    let projectName = project
        .deletingPathExtension().lastPathComponent
    let search = "ls -t ~/Library/Developer/Xcode/DerivedData/\(projectName)-*/Logs/Build/*.xcactivitylog"
    guard let logs = Popen(cmd: search),
          let log = logs.readLine() else {
        log("⚠️ Could not find logs using: \(search)")
        return nil
    }

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
        build = "\(xcbuild) clean; \(xcbuild) -project \(project.relativePath)"
    }

    return extract(build: "\(build) 2>&1 | /usr/bin/tee /tmp/build.txt")
}

public typealias ProtocolInfo = [String: String]

func extractProtocols(from project: URL, commands: [String])
    -> (ProtocolInfo, [String: sourcekitd_response_t]) {
    var protocols = ["Error": "$ss5ErrorP",
                     "Encoder": "$ss7EncoderP",
                     "Decoder": "$ss7DecoderP"]
    var fileSyntax = [String: sourcekitd_response_t]()
    let root = project.deletingLastPathComponent().path
    guard let enumerator =
        FileManager.default.enumerator(atPath: root) else {
        fatalError("⚠️ Could not enumerate \(project)")
    }
    var argumentsToRemove = Set([
        #"-target-sdk-version \S+ "#,
        #"-target-sdk-name \S+ "#,
        "-Xccerror",
        #"-I\S+ "#,
    ])

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
        fileSyntax[fullURL.path] = resp

        guard var command = commands.first(where: {
            $0.contains(" -primary-file \(fullURL.path) ") }) else {
            if !fullURL.path[#"/Tests/|\.build/|Examples?/"#] {
                log("Missing compiler args for \(fullURL.path)")
            }
            continue
        }

        log("Processing", fullURL.relativePath,
            protocols.count, "protocols"); fflush(stdout)

        #if false
        continue // no longer use Cursor-Info requests (too slow in Xcode 15)
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
                    self.log(error)
                    break
                }

                let dict = SKApi.response_get_value(info)
                if let notes = dict.getString(key: sourceKit.fullyAnnotatedID) ??
                               dict.getString(key: sourceKit.annotatedID),
                   notes.contains("ref.protocol") {
//                    log(notes)
                    for (usr, name): (String, String) in notes[
                        #"<ref.protocol usr=\"[sc]:([^"]*)\">([^<]*)</ref.protocol>"#] {
                        protocols[name] = "$s"+usr
                    }
                }

                break
            }
        }
        #endif
    }

    return (protocols, fileSyntax)
}

public typealias Replace = (from: String, to: String)
public typealias Patch = (offset: Int, replace: Replace)

func process(syntax: sourcekitd_response_t, for fullpath: String,
             protocols: ProtocolInfo, protoRegex: String,
             decider: @escaping (
                _ proto: String, _ context: String,
                _ type: String, _ protocols: ProtocolInfo)
             -> String) -> [Patch] {
    var patches = [Patch]()

    let syntax = SKApi.response_get_value(syntax)
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

//    log("PATCHES", patches)
    return patches
}

func apply(patches: [Patch], for file: String, applier:
    (_ line: inout String,
     _ patch: Replace,
     _ count: UnsafeMutablePointer<Int>) -> (),
           count: UnsafeMutablePointer<Int>) -> String? {
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
        applier(&lines[0], patch, count)
    }

    parts.append(String(cString: bytes))
    return parts.reversed().joined()[#"some some"#, "some"]
}

public typealias ErrorPatch = (line: Int, col: Int, replace: Replace)

func addressErrors(file: String, patches: [ErrorPatch],
                   count: UnsafeMutablePointer<Int>) -> String? {
    guard var source = try? String(contentsOfFile: file) else {
        log("⚠️ Could not read file: \(file)")
        return nil
    }

    for patch in patches.sorted(by: { $0.line > $1.line }) {
        source[patch.replace.from, count: count] = [patch.replace.to]
    }

    return source
}

}
