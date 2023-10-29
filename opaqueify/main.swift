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
// Defines a subscript of a string by a raw
// string which is interpreted as a regex.
import SwiftRegex // See https://github.com/johnno1962/SwiftRegex5
/** Some examples:
var numbers = "phone: 555 666-1234 fax: 555 666-4321"

if let match: (String, String, String) = numbers["(\\d+) (\\d+)-(\\d+)"] {
    XCTAssert(match == ("555", "666","1234"), "single match")
}
numbers["(\\d+) (\\d+)-(\\d+)"] = [("555", "777", "1234")]
XCTAssertEqual(numbers, "phone: 555 777-1234 fax: 555 666-4321")
 **/
import Fortify // Catch fatal errors and stack trace
import Popen // To read lines from the build process.
import DLKit

extension Date {
    static var nowInterval: TimeInterval {
        return Date.timeIntervalSinceReferenceDate
    }
}

let start = Date.nowInterval
let argv = CommandLine.arguments

guard argv.count > 1 else {
    print("Usage: \(argv[0]) <project>")
    exit(EXIT_FAILURE)
}

do {
    try Fortify.protect {
        opaqueify(argv: argv)
        exit(EXIT_SUCCESS)
    }
} catch {
    if let info = (error as NSError).userInfo[NSLocalizedDescriptionKey] {
        print(info)
    }
    print("""
        🔥 Oh noes, the script has crashed. Please file an issue at \
        https://github.com/johnno1962/opaqueify with this debug \
        information along with the URL of the repo if possible.
        """)
    exit(EXIT_FAILURE)
}

// Criterion for chosing some over any
func someAnyPolicy(proto: String, context: String,
    type: String, protocols: ProtocolInfo) -> String {
    let notSystemProtocol = !proto.hasPrefix("NS") &&
        protocols[proto]?.hasPrefix("$ss") != true &&
        protocols[proto]?.hasPrefix("$sS") != true &&
        protocols[proto]?.hasPrefix("$s7Combine") != true &&
        protocols[proto]?.hasPrefix("$s10Foundation") != true
    // Package pointfreeco/swift-overture
    return //type[proto+#">"#] ||
        objc_getClass(proto) != nil ? "" :
        context.hasSuffix("parameter") &&
        // Not inside a container or closure
        !type[proto+#"[\]>?]|\)(?:throws )? ->"#] &&
        // and never `some` for a system protocol
        // to avoid breaking common conformances.
        notSystemProtocol //|| proto == "Error"
        ? "some " : "any "
}


// Code that actually patches the source.
// Some pretty intense regular expressions.
// Assigning to a raw String subscript is a
// replacement of capture groups in the regex.
func sourcePatcher(line: inout String, patch: Replace) {
    // Prevents repatching if you run the script twice
    let notPreceededBy =
        #"any |some |protocol |extension |& |\.|<"#
        .components(separatedBy: #"|"#)
        .map { #"(?<!\#($0))"# }.joined()

    // patch in prefix decided by someAnyPolicy()
    let ident = #"\b((?:\w+\.)*"# + patch.from + #"(?:\.Type)?)"#
    line[notPreceededBy + ident +
         #"\b(?![:(]|>\(|\s+\{\}|\.self)"#] = [patch.to]

    // a few special cases to revert to any
    // varargs, default arguments, protocol types
    line[#"(some (\#(ident)\s*))(?=\.\.\.| =|\.Type|\) in)"#]
        = ["any $2"]
}

func fixOptionals(source: inout String, protoRegex: String) {
    // fix up optional syntax (I don't judge)
    let optional = #"\b((?:\w+\.)*"# + protoRegex + #"(?:\.Type)?)"#
    source[#"\b((?:any|some)(\s+\#(optional)))([?!])"#] = "(any $3)$5"
}

func adhocFixes(source: inout String, protoRegex: String) {
    // A few ad-hoc patches improve the odds.
    // is/as seems to get missed by the syntax tree
    let cast = #"(\s+(?:is|as[?!]?)\s+)((?:\w+\.)?"# +
        protoRegex + #"(?:\.Type)?)(?![:])"#
    source[cast] = "$1any $2"

    // "constrained to non-protocol, non-class type"
    source[#"<\w+:( any) "#] = ""

    for _ in 1...5 {
        // @objc or cases cannot have generic params
        // allow "case .some" though
        source[#"(?:@objc|\bcase)\s+[^)]*[^\.]\b(some)\b"#] = "any"
    }

    fixOptionals(source: &source, protoRegex: protoRegex)
}

// regex matching any known protocol identifier
func protocolRegex(protocols: ProtocolInfo) -> String {
    return #"\b(\#(protocols.keys.joined(separator: "|")))\b"#
}

// Policy factored out, the script starts here..
func opaqueify(argv: [String]) {
    let project = URL(fileURLWithPath: argv[1])
    guard let project = (try? project.resourceValues(
            forKeys: [.canonicalPathKey]).canonicalPath)
        .flatMap({ URL(fileURLWithPath: $0) }) else {
        fatalError("⚠️ Bad path to project \(project)")
    }
    chdir(project.deletingLastPathComponent().path)

    // First build the package so we can determine
    // the Swift compiler arguments for SourceKit.
    let commands = build(project: project)

    // Use a combination of the syntax map and
    // Cursor-info requests to determine the
    // set of identifiers that are protocols.
    var (protocols, files) 
        = extractProtocols(from: project, commands: commands)
    print("Protocols detected:", protocols); fflush(stdout)
    for others in [CocoaProtocols, UIKitProtocols] {
        protocols.merge(others) { current, _ in current }
    }
    protocols["Sendable"] = nil
    protocols["Sequence"] = nil
    protocols["Collection"] = nil

    var edits = 0, protoRegex = protocolRegex(protocols: protocols)
    for (file, syntax) in files {
        // re-use the syntax map to find the patches to any/some
        let patches = process(syntax: syntax, for: file,
                              protocols: protocols,
                              protoRegex: protoRegex,
                              decider: someAnyPolicy)
        
        if patches.count != 0, // apply any patches and save
           var patched = apply(patches: patches, for: file,
                               applier: sourcePatcher) {

            adhocFixes(source: &patched, protoRegex: protoRegex)

            try! patched.write(toFile: file,
                               atomically: true, encoding: .utf8)
            edits += patches.count
        }
    }

    print(edits, "edits after", 
          Int(Date.nowInterval-start), "seconds")

    // Second pass, use ExistentialAny errors for fixups..
    if argv.count > 2 {
        verify(project: project, xcode: argv[2],
               protocols: &protocols, commands: commands)
    }
}

func verify(project: URL, xcode: String,
            protocols: inout ProtocolInfo, commands: [String]) {
    for _ in 1...10 {
        print("Rebuilding to verify.."); fflush(stdout)
        let phaseTwo = extractAnyErrors(project: project, xcode: xcode,
            protocols: &protocols, commands: commands)
        let protoRegex = protocolRegex(protocols: protocols)
        var packagesToVerify = Set<String>()

        var fixups = 0
        for (file, patches) in phaseTwo.patches {
            _ = stagePhaseOnce
            if var patched = addressErrors(file: file, patches: patches) {
                fixOptionals(source: &patched, protoRegex: protoRegex)
                
                if let package: String = file[#"^.*\.build/checkouts/[^/]+"#] {
                    packagesToVerify.insert(package+"/Package.swift")
                    print("ℹ️ Having to patch file in dependency:",
                          file, patches)
                    chmod(file, 0o644)
                }
                try? patched.write(toFile: file,
                    atomically: true, encoding: .utf8)
            }
            fixups += patches.count
//            print(reedits, file, patches)
        }

//        for package in packagesToVerify {
//            print("Sub-verifying", package)
//            verify(project: URL(fileURLWithPath: package),
//                   xcode: xcode, protocols: &protocols)
//        }

        if fixups == 0 {
            print("Completed fixups after",
                  Int(Date.nowInterval-start), "seconds")
            let errors = Set(phaseTwo.errors).count
            if errors == 0 {
                print("Package seems to have built 👍")
            } else {
                print("Please correct remaining \(errors) errors manually")
            }
            break
        }
        print(fixups, "fixups after",
              Int(Date.nowInterval-start), "seconds")
    }
}

func extractAnyErrors(project: URL, xcode: String,
    protocols: inout ProtocolInfo, commands: [String])
    -> (patches: [String: [ErrorPatch]], errors: [String]) {
    let name = (project.lastPathComponent == "Package.swift" ?
                project.deletingLastPathComponent() :
                project.deletingPathExtension()).lastPathComponent,
        log = "\"/tmp/rebuild_\(name).txt\"", builder =
            "\(xcode)/Contents/Developer/usr/bin/xcodebuild",
        xcbuild = """
            \(builder) OTHER_SWIFT_FLAGS=\
            '-DDEBUG -enable-upcoming-feature ExistentialAny' \
            -project \(project.lastPathComponent)
            """,
        rebuild = project
            .lastPathComponent == "Package.swift" ? """
            \(xcode)/Contents/Developer/\
            Toolchains/XcodeDefault.xctoolchain/usr/bin/\
            swift build -Xswiftc -enable-upcoming-feature \
            -Xswiftc ExistentialAny
            """ : """
            \(xcbuild) || \(builder) clean && \(xcbuild)
            """
    guard let stdout = Popen(cmd: """
            (\(rebuild)) >\(log) 2>&1; STATUS=$?; sort -u \(log); exit $STATUS
            """) else {
        print("⚠️ Could not open rebuild: "+rebuild)
        return ([:], [])
    }

    var out = [String: [ErrorPatch]]()
    var errors = parseErrors(stdout: stdout,
         protocols: &protocols, out: &out)

    if !stdout.terminatedOK(),
        project.lastPathComponent != "Package.swift" {
        print("ℹ️ Compiling individual files as xcodebuild failed: "+rebuild)
        errors = fallbackBuild(using: commands, log: log,
                       protocols: &protocols, out: &out)
    }

    return (out, errors ?? [])
}

func fallbackBuild(using commands: [String], log: String,
                   protocols: inout ProtocolInfo,
                   out: inout [String: [ErrorPatch]]) -> [String] {
    var total = [String]()
    for var command in commands {
        command[#"builtin-swiftTaskExecution -- "#] = ""
        command[#"( -c) "#] =
            "$1 -enable-upcoming-feature ExistentialAny"
        command[#"-supplementary-output-file-map \S+ "#] = ""
        command[#"Bridging-Header-swift_(\w+)"#] = "*"
        command[#"-frontend-parseable-output "#] = ""
        command += " 2>&1 | tee -a \(log)"
        for _ in 1...3 {
            guard let stdout = Popen(cmd: command) else {
                print("⚠️ Could not execute: "+command)
                break
            }
            if let errors = parseErrors(stdout: stdout,
                protocols: &protocols, out: &out) {
                _ = stagePhaseOnce
                total += errors
                break
            }
        }
    }
    return total
}

func parseErrors(stdout: Popen,
                 protocols: inout ProtocolInfo,
                 out: inout [String: [ErrorPatch]]) -> [String]? {
    var errors = [String]()
    for output in stdout {
        if let (path, before, after):
            (String, String, String) = output[
            #"PCH file '(([^']+?-Bridging-Header-swift_)\w+(-clang_\w+.pch))' not found:"#] {
            print(Popen.system("/bin/bash -xc '/bin/ln -s \(before)*\(after) \(path)'") ??
                  "⚠️ Linking PCH failed")
            return nil
        }
        if let (file, line, col): (String, String, String) =
            output[#"^([^:]+):(\d+)(?::(\d+))?: error: "#],
            let line = Int(line) {
            let col = Int(col) ?? -1
            let offset = "^(?:.*\n){\(line-1)}" +
                          ".{\(max(col-20,1))}.*?"
            let once = #"(?<!any )(?<!some )"#

            if let proto: String = output[
                #"use of (?:protocol )?'(?:[^'.]+\.)*(\w+)(?:\.Type)?' (?:\(aka '[^']+'\) )?as a type"#] {
                let change = #"\b((?:\w+\.)?\#(proto))"#
                out[file, default: []].append((line, col,
                    (from: offset+once+change, to: "any $1")))
                if protocols[proto] == nil {
                    protocols[proto] = file
                }
            } else if let proto: String = output[
                #"'any' has no effect on (?:type parameter|concrete type) '(?:[^'.]+\.)*(\w+)(?:\.Type)?'"#] {
                let change = #"(any (?:\w+\.)*\#(proto))"#
                out[file, default: []].append((line, col,
                    (from: offset+once+change, to: proto)))
                if protocols[proto] == nil {
                    protocols[proto] = file
                }
            } else if output[
                #"instance method cannot be (an implementation|a member) of an @objc"#] ||
                output[#"method does not override any method from its superclass"#] ||
                output[#"initializer does not override a designated initializer"#] {
                let change = "[^)]+ (some) "
                out[file, default: []].append((line, col,
                    (from: offset+once+change, to: "any")))
            } else {
                print(output)
                errors.append(output)
            }
        }
    }
    return errors
}
