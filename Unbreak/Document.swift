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

    override init() {
        super.init()
        // Add your subclass-specific initialization here.
        DispatchQueue.main.async {
            if let console = Bundle.main.path(forResource: "Console", ofType: "html") {
                self.webView.load(URLRequest(url: URL(fileURLWithPath: console)))
                self.progress.isHidden = true
            }
        }
    }

    @IBAction func openProject(_ sender: Any?) {
        NSWorkspace.shared.open(self.fileURL!)
    }

    @IBAction func processProject(_ button: NSButton) {
        if let script = Bundle.main.path(forResource: "opaqueify", ofType: nil),
           let project = fileURL {
            button.isEnabled = false
            progress.isHidden = false
            progress.startAnimation(nil)
            self.webView.evaluateJavaScript(
                "append(\(["Building to generate logs..\n"]))")
            DispatchQueue.global().async {
                if let stdout = popen("""
                    \(script) \(project.path) "/Applications/Xcode15.app"
                    """, "r") {
                    while let line = stdout.readLine() {
                        DispatchQueue.main.async {
                            let line = line.replacingOccurrences(of: "^/[^:]+",
                                     with: "<a href='file://$0'>$0</a>",
                                     options: .regularExpression)
                            self.webView.evaluateJavaScript(
                                "append(\([line+"\n"]))")
                        }
                    }

                    _ = pclose(stdout)
                }

                DispatchQueue.main.async {
                    self.progress.stopAnimation(nil)
                    self.progress.isHidden = true
                    button.isEnabled = true
                }
            }
        }
    }

    @objc func webView(_ aWebView: WKWebView!,
                       addMessageToConsole message: [AnyHashable : Any]) {
        NSLog("%@", message)
    }

    override class var autosavesInPlace: Bool {
        return true
    }

    override var windowNibName: NSNib.Name? {
        // Returns the nib file name of the document
        // If you need to use a subclass of NSWindowController or if your document supports multiple NSWindowControllers, you should remove this property and override -makeWindowControllers instead.
        return NSNib.Name("Document")
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

