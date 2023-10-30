//
//  AppDelegate.swift
//  Unbreak
//
//  Created by John Holdsworth on 23/10/2023.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {



    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        NSApp.dockTile.contentView = dockTile
        NSApp.dockTile.display()
    }

    @IBOutlet var dockTile: NSView!

    @IBAction func openFile(_ sender: Any) {
        let open = NSOpenPanel()
        open.prompt = "Select Project File"
        open.canChooseFiles = true
        if open.runModal() == .OK,
           let url = open.url {
            if let doc = try? Document(contentsOf: url, ofType:
                                        url.lastPathComponent),
               let nib = doc.windowNibName {
                Bundle.main.loadNibNamed(nib, owner: doc,
                                         topLevelObjects: nil)
                doc.webView.window?.title = url.lastPathComponent
                doc.webView.window?.representedURL = url
                NSDocumentController.shared.addDocument(doc)
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


}

