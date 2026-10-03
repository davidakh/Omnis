//
//  OmnisApp.swift
//  Omnis
//
//  Created by David Akhmedbayev on 10/2/26.
//

import AppKit
import SwiftUI

@main
struct OmnisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app has no normal windows; everything lives in the floating surface.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presenter: SurfacePresenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        let presenter = SurfacePresenter { RootView(state: state) }
        self.presenter = presenter
        presenter.show()
    }
}
