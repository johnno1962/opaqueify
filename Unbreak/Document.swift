//
//  Document.swift
//  Unbreak
//
//  Created by John Holdsworth on 23/10/2023.
//

import Cocoa
import Popen
import WebKit
import SwiftRegex

class Document: NSDocument, WKUIDelegate, WKNavigationDelegate {

    @IBOutlet var webView: WKWebView!
    @IBOutlet var progress: NSProgressIndicator!

    var xcode = "/Applications/Xcode.app"
    var running: Popen?

    override init() {
        super.init()
        // Add your subclass-specific initialization here.
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        if let console = Bundle.main.path(forResource: "Console", ofType: "html") {
            webView.load(URLRequest(url: URL(fileURLWithPath: console)))
            progress.isHidden = true
        }
    }

    @IBAction func openProject(_ sender: Any?) {
        NSWorkspace.shared.open(self.fileURL!)
    }

    @IBAction func stashProject(_ sender: Any?) {
        guard let project = fileURL else { return }
        output(cmd: """
            cd "\(project.deletingLastPathComponent().path)"; git stash
            """)
    }

    @IBAction func processProject(_ button: NSButton) {
        if let project = fileURL {
            if running != nil {
                button.title = "Prepare for Swift 6"
                _ = running?.terminatedOK()
                progress.stopAnimation(nil)
                progress.isHidden = true
                running = nil
                return
            }
            
            let prepare = button.title
            progress.isHidden = false
            progress.startAnimation(nil)
            webView.evaluateJavaScript(
                "append(\(["Building to generate logs..\n"]))")
            
            if let script = Bundle.main.path(
                forResource: "opaqueify", ofType: nil) {
                button.title = "Cancel"
                    output(cmd: """
                        "\(script)" "\(project.path)" "\(xcode)" 2>&1
                        """) {
                        self.progress.stopAnimation(nil)
                        self.progress.isHidden = true
                        button.isEnabled = true
                        button.title = prepare
                }
            }
        }
    }

    func output(cmd: String, completion: @escaping () -> () = {}) {
        running = Popen(cmd: cmd)
        guard let running = running else { return }
        DispatchQueue.global().async {
            for line in running {
                let line = line
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: "^/[^:]+",
                                          with: "<a href='#$0'>$0</a>",
                                          options: .regularExpression)
                DispatchQueue.main.async {
                    self.webView.evaluateJavaScript(
                        "append.apply(null, \([line+"\n"]))")
                }
            }

            self.running = nil
            DispatchQueue.main.async(execute: completion)
        }
    }

    @IBAction func selectXcode(_ sender: Any) {
        let open = NSOpenPanel()
        open.prompt = "Select Xcode"
        open.canChooseDirectories = false
        open.canChooseFiles = true
        if open.runModal() == .OK,
           let url = open.url, url.pathExtension == "app" {
            xcode = url.path()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.isFileURL {
            if url.path.hasSuffix("Console.html") {
                if let path = url.fragment {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
            }
        }
    }

    @objc func webView(_ aWebView: WKWebView!,
                       addMessageToConsole message: [AnyHashable : Any]) {
        NSLog("%@", message)
    }

    override class var autosavesInPlace: Bool {
        return false
    }

    override var windowNibName: NSNib.Name? {
        // Returns the nib file name of the document
        // If you need to use a subclass of NSWindowController or if your document supports multiple NSWindowControllers, you should remove this property and override -makeWindowControllers instead.
        return NSNib.Name("Document")
    }

    override nonisolated func read(from fileWrapper:
        FileWrapper, ofType typeName: String) throws {
    }

    override func data(ofType typeName: String) throws -> Data {
        // Insert code here to write your document to data of the specified type, throwing an error in case of failure.
        // Alternatively, you could remove this method and override fileWrapper(ofType:), write(to:ofType:), or write(to:ofType:for:originalContentsURL:) instead.
        throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        // Insert code here to read your document from the given data of the specified type, throwing an error in case of failure.
        // Alternatively, you could remove this method and override read(from:ofType:) instead.
        // If you do, you should also override isEntireFileLoaded to return false if the contents are lazily loaded.
//        throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
    }


}

