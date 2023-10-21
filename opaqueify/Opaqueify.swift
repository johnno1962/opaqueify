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

func lastLog(project: URL) -> String {
    let projectName = project
        .deletingPathExtension().lastPathComponent
    let search = "ls -t ~/Library/Developer/Xcode/DerivedData/\(projectName)-*/Logs/Build/*.xcactivitylog"
    guard let logs = popen(search, "r"),
          let log = logs.readLine() else {
        print("⚠️ Could not find logs using: \(search)")
        return "/tmp/build.log"
    }

    _ = pclose(logs)
    return log
}

func build(project: URL) -> [String] {
    let root = project.deletingLastPathComponent().path
    if project.lastPathComponent == "Package.swift" {
        let build = "rm -rf .build; swift build -v"
        return extract(build: "cd \"\(root)\" && \(build)")
    } else {
        return extract(build: "gunzip <\(lastLog(project: project)) | /usr/bin/tr '\\r' '\\n' | tee /tmp/build.txt")
    }
}

var argumentsToRemove = Set([
        #"-target-sdk-version \S+ "#,
        #"-target-sdk-name \S+ "#,
        "-Xccerror",
        #"-I\S+ "#,
])

func extractProtocols(from project: URL, commands: [String])
    -> ([String: String], [String: sourcekitd_variant_t]) {
    var protocolMap = ["Error": "$ss5ErrorP"]
    var filePaths = [String: sourcekitd_variant_t]()
    guard let root = try? project.deletingLastPathComponent()
            .resourceValues(forKeys: [.canonicalPathKey])
            .canonicalPath,
          let enumerator = FileManager.default.enumerator(atPath: root) else {
        fatalError("⚠️ Bad path to project: \(project)")
    }

    for relative in enumerator {
        let fullpath = URL(fileURLWithPath: root)
            .appendingPathComponent(relative as! String)
        guard fullpath.path.hasSuffix(".swift") else {
            continue
        }

        if let source = try? String(contentsOfFile: fullpath.path) {
            for proto: String in
                source[#"\bprotocol\s+(\w+)\b"#] {
                protocolMap[proto] = fullpath.path
            }
        }

        let resp = sourceKit.syntaxMap(filePath: fullpath.path, subSyntax: true)
//        SKApi.response_description_dump(resp)
        let dict = SKApi.response_get_value(resp)
        filePaths[fullpath.path] = dict

        guard var command = commands.first(where: {
            $0.contains(" -primary-file \(fullpath.path) ") }) else {
            if !fullpath.path.contains("/Tests/") {
                print("Missing compiler args for \(fullpath)")
            }
            continue
        }

        print("Processing", fullpath); fflush(stdout)
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
                        #"(?:unexpected|duplicate) input file: (.*?)error:"#] {
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
                        protocolMap[name] = "$s"+usr
                    }
                }

                break
            }
        }
    }

    print("Protocols are:", protocolMap)
    protocolMap["Sendable"] = nil
    protocolMap["Sequence"] = nil
    protocolMap["Collection"] = nil
    return (protocolMap, filePaths)
}

typealias Patch = (offset: Int, (from: String, to: String))

func process(syntax: sourcekitd_variant_t,
             for fullpath: String,
             protocols: [String: String],
             protoRegexp: String) -> [Patch] {
    var patches = [Patch]()

    sourceKit.recurseOver(childID: sourceKit.structureID,
                          resp: syntax) { node in
        let offset = node.getInt(key: sourceKit.offsetID)
        if let kind = node.getUUIDString(key: sourceKit.kindID),
           let type = node.getString(key: sourceKit.typenameID),
           let proto: String = type[protoRegexp] {
            // Elide this parameter to some?
            let prefix = kind[#"parameter$"#] &&
                // Not inside a container or closure
                !type[proto+#"[\]>?]|\)(?:throws )? ->"#] &&
                // and not for a system protocol
                protocols[proto]?.hasPrefix("$ss") != true &&
                protocols[proto]?.hasPrefix("$sS") != true &&
                protocols[proto]?.hasPrefix("$s10Foundation") != true &&
                protocols[proto]?.hasPrefix("$s7Combine") != true ?
                "some " : "any "
            patches.append((offset, (proto, prefix+"$1")))
        }
    }

//    print("PATCHES", patches)
    return patches
}

func apply(patches: [Patch], to file: String) -> String? {
    guard let data = NSMutableData(contentsOfFile: file) else {
        return nil
    }

    var zero: Int8 = 0
    data.append(&zero, length: 1)

    let bytes = UnsafeMutablePointer<CChar>(mutating:
        data.bytes.assumingMemoryBound(to: CChar.self))
    let notPreceededBy =
        #"any |some |protocol |extension |& |\.|<"#
        .components(separatedBy: #"|"#)
        .map { #"(?<!\#($0))"# }.joined()

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
        func stage(_ s: String) {
//            print(s, lines[0])
        }

        stage("\n111111111111")
        // patch in prefix (once)
        let ident = #"\b((?:\w+\.)?"# + patch.from + #")"#
        lines[0][notPreceededBy + ident +
                 #"\b(?![:(]|>\(|\s+\{\}|\.self)"#]
            = [patch.to]
        
        stage("22222222222222")
        // Swift.Error
        lines[0][#"\b(\w+\.)((?:any|some)\s+)(?=\#(ident))"#]
            = [("$2", "$1")]
        
        stage("33333333333333")
        // fix up optional syntax
        lines[0][#"\b((?:any|some)(\s+\#(ident)))([?!])"#]
            = ["(any$2)$4"]

        stage("44444444444444")
        // a few special cases
        lines[0][#"(some (\#(ident)\s*))(?=\.\.\.| =|\.Type|\) in)"#]
            = ["any $2"]
        stage("55555555555555")
    }

    parts.append(String(cString: bytes))
    return parts.reversed().joined()[#"some some"#, "some"]
}

typealias AnyError = (line: Int, col: Int, proto: String)

func extractAnyErrors(project: URL, xcode: String)
    -> [String: [AnyError]] {
    let xcbuild =
            "\(xcode)/Contents/Developer/usr/bin/xcodebuild"
    let rebuild = project
        .lastPathComponent == "Package.swift" ? """
        rm -rf .build && \(xcode)/Contents/Developer/\
        Toolchains/XcodeDefault.xctoolchain/usr/bin/\
        swift build -Xswiftc -enable-upcoming-feature \
        -Xswiftc ExistentialAny 2>&1 | sort -u
        """ : """
        \(xcbuild) OTHER_SWIFT_FLAGS=\
        '-DDEBUG -enable-upcoming-feature ExistentialAny' \
        2>&1 | tee -a /tmp/rebuild.txt
        """
    guard let stdout = popen("""
        cd \"\(project.deletingLastPathComponent().path)\" &&
        """+rebuild, "r") else {
        print("⚠️ Rebuild failed: \(rebuild)")
        return [:]
    }

    var out = [String: [AnyError]]()
    while let line = stdout.readLine() {
        if let (file, line, char, proto):
            (String, String, String, String) =
            line[#"^([^:]+):(\d+):(\d+): "# +
                 #"error: use of protocol '([^']+)'"#] {
            out[file, default: []].append(
                (Int(line) ?? 0, Int(char) ?? 0, proto))
        }
    }

    return out
}

func addressErrors(file: String, patches: [AnyError]) -> String? {
    guard var source = try? String(contentsOfFile: file) else {
        print("Could not open file: \(file)")
        return nil
    }

    for patch in patches.sorted(by: { $0.line > $1.line }) {
        let offset = "^(?:.*\n){\(patch.line-1)}" +
                          ".{\(patch.col-1)}.*?"
        let change = "(?<!any )(?<!some )(\(patch.proto))"
        source[offset+change] = ["any $1"]
        source[#"(any \#(patch.proto))\#\?"#] = "($1)"
    }

    return source
}
