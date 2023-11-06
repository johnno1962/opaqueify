//
//  Opaqueifier.swift
//  opaqueify
//
//  Created by John Holdsworth on 29/10/2023.
//

import Foundation
import Cocoa
import Popen

// Defines a subscript of a string by a raw
// string which is interpreted as a regex.
import SwiftRegex // See https://github.com/johnno1962/SwiftRegex5
/** Some examples:
var numbers = "phone: 555 666-1234 fax: 555 666-4321"

if let match: (String, String, String) = numbers[#"(\\d+) (\\d+)-(\\d+)"#] {
    XCTAssert(match == ("555", "666","1234"), "single match")
}
numbers["(\\d+) (\\d+)-(\\d+)"] = [("555", "777", "1234")]
XCTAssertEqual(numbers, "phone: 555 777-1234 fax: 555 666-4321")
 **/
#if SWIFT_PACKAGE
import SourceKitHeader
#endif

extension Date {
    static var nowInterval: TimeInterval {
        return Date.timeIntervalSinceReferenceDate
    }
}

open class Opaqueifier {

    let start = Date.nowInterval

    public init() {}
    
    open func log(_ items: Any..., separator: String = " ",
                      terminator: String = "\n") {
        print(items.map { "\($0)" }.joined(
            separator: separator), terminator: terminator)
    }

    // Criterion for chosing some over any
    open func someAnyPolicy(proto: String, context: String,
        type: String, protocols: ProtocolInfo) -> String {
        let notSystemProtocol = !proto.hasPrefix("NS") &&
            protocols[proto]?.hasPrefix("$ss") != true &&
            protocols[proto]?.hasPrefix("$sS") != true &&
            protocols[proto]?.hasPrefix("$s7Combine") != true &&
            protocols[proto]?.hasPrefix("$s10Foundation") != true
        return proto.hasPrefix("Any") || //type[proto+#">"#] ||
            proto.count == 1 || // likely to be generic constraint
            objc_getClass(proto) != nil ? "" : // concrete class
            context.hasSuffix("parameter") && // elide to some?
            // not inside a container, Result or closure
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
    open func sourcePatcher(line: inout String, patch: Replace,
                            count: UnsafeMutablePointer<Int>) {
        // Prevents repatching if you run the script twice
        let notPreceededBy =
            #"any |some |protocol |extension |where |& |\.|<"#
            .components(separatedBy: #"|"#)
            .map { #"(?<!\#($0))"# }.joined()

        // patch in prefix decided by someAnyPolicy()
        let ident = #"\b((?:\w+\.)*"# + patch.from + #"(?:\.Type)?)"#
        line[notPreceededBy + ident +
             #"\b(?![:(]|>\(|\s+\{\}|\.self)"#, count: count] = [patch.to]

        // a few special cases to revert to any
        // varargs, default arguments, protocol types, closures
        line[#"(some (\#(ident)\s*))(?=\.\.\.| =|\.Type|\) in)"#]
            = ["any $2"]
    }

    open func fixOptionals(source: inout String, protoRegex: String,
                           count: UnsafeMutablePointer<Int>) {
        // fix up optional syntax (I don't judge)
        let optional = #"\b((?:\w+\.)*("# + protoRegex + #")(?:\.Type)?)"#
        source[#"\b((?:any|some)(\s+\#(optional)))([?!])"#,
               0, count: count] = "(any $3)$5"
    }

    open func adhocFixes(source: inout String, protoRegex: String,
                         count: UnsafeMutablePointer<Int>) {
        // A few ad-hoc patches improve the odds.
        // is/as seems to get missed by the syntax tree
        let cast = #"(\s+(?:is|as[?!]?)\s+)((?:\w+\.)?("# +
            protoRegex + #")(?:\.Type)?)(?![:a-z])"#
        source[cast, count: count] = { (groups: [String], stop) in
            let elide = objc_getClass(groups[2]) != nil ||
                groups[2].hasPrefix("Any") ? "" : "any "
            return groups[1]+elide+groups[2]
        }

        // "constrained to non-protocol, non-class type"
        source[#"<\w+:( any) "#, count: count] = ""

        // promote returning some (with exceptions e.g Disposable in RxSwift)
        source[#"-> (any) (?!Encoder|Decoder|Disposable)\#(protoRegex) \{"#,
               1, count: count] = "some"

        for _ in 1...5 {
            // @objc or cases cannot have generic params
            // allow "case .some" though
            source[#"(?:@objc|\bcase)\s+.*[^\.]\b(some)\b"#, count: count] = "any"
        }

        fixOptionals(source: &source, protoRegex: protoRegex, count: count)
    }

    // regex matching any known protocol identifier
    open func protocolRegex(protocols: ProtocolInfo) -> String {
        return #"\b(?:\#(protocols.keys.joined(separator: "|")))\b"#
    }

    open lazy var stagePhaseOnce: () = {
        log(Popen.system("git add .") ?? "⚠️ Stage failed", terminator: "")
    }()

    // Policy factored out, the script starts here..
    open func main(projectPath: String, xcodePath: String?,
                   knownPotocols: [[String: String]]) -> CInt {
        let projectURL: URL
        if projectPath.hasPrefix("/") {
            let pathURL = URL(fileURLWithPath: projectPath)
            guard let absolute = (try? pathURL.resourceValues(
                forKeys: [.canonicalPathKey]).canonicalPath)
                .flatMap({ URL(fileURLWithPath: $0) }) else {
                fatalError("⚠️ Bad path to project \(pathURL)")
            }
            projectURL = URL(fileURLWithPath: absolute.lastPathComponent,
                             relativeTo: absolute.deletingLastPathComponent())
            FileManager.default.changeCurrentDirectoryPath(
                projectURL.deletingLastPathComponent().path)
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            projectURL = URL(fileURLWithPath: projectPath,
                             relativeTo: URL(fileURLWithPath: cwd))
        }

        // First build the package so we can determine
        // the Swift compiler arguments for SourceKit.
        let commands = build(project: projectURL)

        // Use a combination of the syntax map and
        // [Cursor-info requests] to determine the
        // set of identifiers that are protocols.
        var (protocols, files)
            = extractProtocols(from: projectURL, commands: commands)
        log("Protocols detected:", protocols); fflush(stdout)
        for others in knownPotocols {
            protocols.merge(others) { current, _ in current }
        }
        protocols["Sendable"] = nil
        protocols["Sequence"] = nil
        protocols["Subscript"] = nil
        protocols["Collection"] = nil

        defer {
            for resp in files.values {
                SKApi.response_dispose(resp)
            }
            SKApi.set_interrupted_connection_handler({})
        }

        var count = 0, edits = 0, protoRegex = protocolRegex(protocols: protocols)
        for (file, syntax) in files {
            // re-use the syntax map to find the patches to any/some
            let patches = process(syntax: syntax, for: file,
                                  protocols: protocols,
                                  protoRegex: protoRegex,
                                  decider: someAnyPolicy)

            if patches.count != 0, // apply any patches and save
               var patched = apply(patches: patches, for: file,
                                   applier: sourcePatcher, count: &count) {

                adhocFixes(source: &patched, protoRegex: protoRegex, count: &count)

                try! patched.write(toFile: file,
                                   atomically: true, encoding: .utf8)
                edits += patches.count
            }
        }

        log("\(count)/\(edits) edits after",
            Int(Date.nowInterval-start), "seconds")

        // Second pass, use ExistentialAny errors for fixups..
        if let xcode = xcodePath {
            return verify(project: projectURL, xcode: xcode,
                   protocols: &protocols, commands: commands)
        }

        return EXIT_SUCCESS
    }

    open func verify(project: URL, xcode: String,
        protocols: inout ProtocolInfo, commands: [String]) -> CInt {
        var count = 0
        for _ in 1...10 {
            log("Rebuilding to verify.."); fflush(stdout)
            let phaseTwo = extractAnyErrors(project: project, xcode: xcode,
                protocols: &protocols, commands: commands),
                protoRegex = protocolRegex(protocols: protocols)
            var packagesToVerify = Set<String>(), fixups = 0

            for (file, patches) in phaseTwo.patches {
                _ = stagePhaseOnce
                if var patched = addressErrors(file: file, patches: patches,
                                               count: &count) {
                    fixOptionals(source: &patched, protoRegex: protoRegex,
                                 count: &count)

                    if let package: String = file[#"^.*\.build/checkouts/[^/]+"#] {
                        packagesToVerify.insert(package+"/Package.swift")
                        log("ℹ️ Having to patch file in dependency:",
                            file, patches)
                        chmod(file, 0o644)
                    }
                    try? patched.write(toFile: file,
                        atomically: true, encoding: .utf8)
                }
                fixups += patches.count
//                log(file+":", fixups, patches)
            }

//        for package in packagesToVerify {
//            log("Sub-verifying", package)
//            verify(project: URL(fileURLWithPath: package),
//                   xcode: xcode, protocols: &protocols)
//        }

            if fixups == 0 {
                log("Completed fixups after",
                    Int(Date.nowInterval-start), "seconds")
                let errors = Set(phaseTwo.errors).count
                if errors == 0 {
                    log(project.deletingPathExtension()
                        .lastPathComponent, "seems to have built 👍")
                    return EXIT_SUCCESS
                } else {
                    log("Please correct remaining \(errors) errors manually")
                    return EXIT_FAILURE
                }
            }
            log("\(count)/\(fixups)", "fixups after",
                Int(Date.nowInterval-start), "seconds")
        }

        log("Please correct remaining errors manually")
        return EXIT_FAILURE
    }

    open func extractAnyErrors(project: URL, xcode: String,
        protocols: inout ProtocolInfo, commands: [String])
        -> (patches: [String: [ErrorPatch]], errors: [String]) {
        let name = (project.lastPathComponent == "Package.swift" ?
                    project.deletingLastPathComponent() :
                    project.deletingPathExtension()).lastPathComponent,
            tmplog = "\"/tmp/rebuild_\(name).txt\"", builder =
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
                (\(rebuild)) >\(tmplog) 2>&1; STATUS=$?; sort -u \(tmplog); exit $STATUS
                """) else {
            log("⚠️ Could not open rebuild: "+rebuild)
            return ([:], [])
        }

        var out = [String: [ErrorPatch]]()
        var errors = parseErrors(stdout: stdout,
             protocols: &protocols, out: &out)

        if !stdout.terminatedOK(),
            project.lastPathComponent != "Package.swift" {
            log("ℹ️ Compiling individual files as xcodebuild failed: "+rebuild)
            errors = fallbackBuild(using: commands, tmplog: tmplog,
                           protocols: &protocols, out: &out)
        }

        return (out, errors ?? [])
    }

    open func fallbackBuild(using commands: [String], tmplog: String,
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
            command += " 2>&1 | tee -a \(tmplog)"
            for _ in 1...3 {
                guard let stdout = Popen(cmd: command) else {
                    log("⚠️ Could not execute: "+command)
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

    open func parseErrors(stdout: Popen,
                     protocols: inout ProtocolInfo,
                     out: inout [String: [ErrorPatch]]) -> [String]? {
        var errors = [String]()
        for output in stdout {
            if let (path, before, after):
                (String, String, String) = output[
                #"PCH file '(([^']+?-Bridging-Header-swift_)\w+(-clang_\w+.pch))' not found:"#] {
                log(Popen.system("/bin/bash -xc '/bin/ln -s \(before)*\(after) \(path)'") ??
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
                    #"'any' has no effect on (?:type parameter|concrete type) '(?:[^'.]+\.)*(\w+\??)(?:\.Type)?'"#] {
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
                } else if output[
                    "'some' return types are only available in"] {
                    let change = "-> (some) "
                    out[file, default: []].append((line, col,
                        (from: offset+once+change, to: "any")))
                } else if let type: String = output[
                    #"type 'some ([^']+)' constrained to non-protocol, non-class type"#] {
                    let change = "(some )"+type
                    out[file, default: []].append((line, col,
                        (from: offset+once+change, to: "")))
                } else {
                    errors.append(output)
                    log(output)
                }
            }
        }
        return errors
    }
}
