//
//  Document.swift
//  Unbreak
//
//  Created by John Holdsworth on 23/10/2023.
//

import Cocoa
import WebKit
import Popen

class Document: NSDocument, WKUIDelegate, WKNavigationDelegate {

    @IBOutlet var webView: WKWebView!
    @IBOutlet var progress: NSProgressIndicator!
    var running: UnsafeMutablePointer<FILE>?

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
        NSLog(Popen.system("""
            cd "\(project.deletingLastPathComponent().path)"; git stash
            """) ?? "⚠️ Stash error: \(project)")
    }

    @IBAction func processProject(_ button: NSButton) {
        webView.window!.representedURL = fileURL
        if let script = Bundle.main.path(forResource: "opaqueify", ofType: nil),
           let project = fileURL {
            if button.title == "Cancel" {
                button.title = "Prepare for Swift 6"
                progress.stopAnimation(nil)
                progress.isHidden = true
                _ = pclose(running)
                running = nil
                return
            }
            progress.isHidden = false
            progress.startAnimation(nil)
            webView.evaluateJavaScript(
                "append(\(["Building to generate logs..\n"]))")
            if let stdout = popen("""
                \(script) \(project.path) /Applications/Xcode.app 2>&1
                """, "r") {
                self.running = stdout
                button.title = "Cancel"
                DispatchQueue.global().async {
                    while let line = stdout.readLine() {
                        let line = line
                            .replacingOccurrences(of: "&", with: "&amp;")
                            .replacingOccurrences(of: "<", with: "&lt;")
                            .replacingOccurrences(of: "^/[^:]+",
                                with: "<a href='file://$0'>$0</a>",
                                options: .regularExpression)
                        DispatchQueue.main.async {
                            self.webView.evaluateJavaScript(
                                "append.apply(null, \([line+"\n"]))")
                        }
                    }

                    _ = pclose(stdout)

                    DispatchQueue.main.async {
                        self.progress.stopAnimation(nil)
                        self.progress.isHidden = true
                        button.isEnabled = true
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.isFileURL {
            if url.path.hasSuffix("Console.html") {
                decisionHandler(.allow)
            } else {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
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

