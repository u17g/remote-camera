import SwiftUI

@main
struct RemoteCameraApp: App {
    var body: some Scene {
        #if os(iOS)
        // The iPhone is the camera.
        WindowGroup {
            CameraHostView()
        }
        #elseif os(macOS)
        // The Mac is the remote. One window: a second one would open a second connection.
        Window("Remote Camera", id: "controller") {
            ControllerView()
        }
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
