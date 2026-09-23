# remote-camera

Control an iPhone's camera from a Mac: see a live preview with sound, take photos and record
videos. Everything is saved to the iPhone's Photos library.

One SwiftUI codebase and one Xcode target build both apps. `#if os(iOS)` in
`RemoteCamera/App/RemoteCameraApp.swift` makes the iPhone build the camera and the Mac build the
remote.

## Build

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and is not checked in. Everything goes through the Makefile:

```sh
make mac_run      # build and launch the Mac app
make ios_device   # build, install and launch on the connected iPhone
make ios_run      # the iPhone app in the Simulator (streams a test pattern: there is no camera)
make build        # compile both
```

See the top of the `Makefile` for the rest and for the knobs (`CONFIGURATION`, `DEVICE`, `TEAM`, …).

## Use

1. Open Remote Camera on the iPhone and leave it in the foreground. iOS stops the camera of an
   app in the background.
2. Open it on the Mac, on the same Wi-Fi (or close by: peer-to-peer Wi-Fi works too), and pick the
   iPhone on the left.
3. The first time, the iPhone asks whether to allow that Mac. After that it reconnects on its own.

Space is the shutter. In Video mode it starts and stops recording.

The sidebar picks the camera (back or front), the zoom and the video resolution (1080p or 4K).
Zoom works as in the Camera app: one continuous range, 0.5× to 25× on a 16 Pro, with a button for
each lens (0.5×, 1×, 5×) and a slider and stepper for anything in between, in tenths. The iPhone
moves between lenses as the zoom crosses them and zooms digitally in between, so 1.2× is the main
lens. Zoom can change while recording; the camera and resolution cannot.

**Mirror** flips the picture left to right, and what you see is what is saved: the preview on the
Mac and on the iPhone, and the photos and videos in Photos. Each camera remembers its own setting;
the front one starts mirrored, like a selfie view. The flip and the rotation are made in the
pixels rather than recorded as metadata, which some players and sites ignore.

In Video mode, **Background Blur** turns on Cinematic mode and sets its simulated f-number: lower
blurs the background more. It is the Camera app's Cinematic effect (iOS 26, iPhone 13 or later),
visible in the Mac's preview and recorded into the video. The physical aperture of an iPhone lens
is fixed; there is nothing to set for photos.

## How it works

- The iPhone advertises `_remotecam._tcp` over Bonjour; the Mac browses for it and connects over
  TCP (`Shared/PeerConnection.swift`).
- Frames are length-prefixed. Control messages are JSON; the preview is ~15 fps of 960 px JPEGs,
  and the microphone is 16-bit mono PCM (`Shared/Wire.swift`). Media that the network cannot keep
  up with is dropped rather than queued, so the preview stays live.
- Photos come from `AVCapturePhotoOutput`. Videos are written with `AVAssetWriter` from the same
  sample buffers that feed the preview (`iOS/CameraService.swift`, `iOS/MovieRecorder.swift`).

The link is not encrypted, and the iPhone recognises an allowed Mac by an ID the Mac sends in the
clear. That is fine on a home network; on a network you do not trust, someone could watch the
preview or pose as your Mac.
