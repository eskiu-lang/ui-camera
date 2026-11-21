# ui-camera documentation

Guides and reference for ui-camera. The [README](../README.md) has the overview.

<!-- pages -->
- [Live frames](frames.md)
- [API reference](api.md): every public function and type
<!-- /pages -->

## Platforms

| Platform | Library | Camera | Live view |
|---|---|---|---|
| iOS | `PHPickerViewController` | `UIImagePickerController` | `AVCaptureSession` and `AVCapturePhotoOutput` |
| Android | The photo picker (`ACTION_PICK_IMAGES`, Android 13+), else `ACTION_GET_CONTENT` | `ACTION_IMAGE_CAPTURE` into a MediaStore entry the package deletes after (Android 10+) | Camera2 into a `TextureView`, closed while the app is in the background |
| Web | A file input | A file input with `capture` (phones open the camera; desktops choose a file) | `getUserMedia` into a `<video>` |
| macOS | `NSOpenPanel` (any image file), decoded with ImageIO | None: `PhotoUnavailable` (macOS has no system camera screen) | `AVCaptureSession` and `AVCapturePhotoOutput`, the built-in camera or the default one |
| Linux | GTK's file dialog (any image file), decoded with GdkPixbuf | None: `PhotoUnavailable` | None: the view reports `PhotoUnavailable` and `use_camera_frames` gets no frames |
| Windows | The system's open dialog (any image file), decoded with GDI+ | None: `PhotoUnavailable` | None: the view reports `PhotoUnavailable` and `use_camera_frames` gets no frames |

On macOS an app that takes photos shows a `CameraView` and calls `camera_capture`, since
there is no system camera screen to open; frames come as NV12, upright as they are (rotation
0), and a Mac's built-in camera is the front one. On Linux a camera would need PipeWire's
camera portal or V4L2, and on Windows Media Foundation's capture; neither is done yet, so the
camera is unavailable there and never shows a made-up picture. Photos chosen on the desktops
are saved in the user's cache directory (macOS, Linux) or temporary folder (Windows). The
desktop's `--webview` builds use the web's file input and `getUserMedia`.

The simulator has no camera: `CameraView` and `camera_take_photo` give `PhotoUnavailable`
there, and the library works. The Android emulator's virtual camera works.

`camera_supported()` says before a `CameraView` is mounted whether there is a camera to show:

| Platform | `camera_supported()` |
|---|---|
| iOS | true with a camera; false on the simulator |
| Android | true with a camera (`FEATURE_CAMERA_ANY`) |
| Web | true where the browser has `getUserMedia` (a page served over https or from localhost) |
| macOS, Linux, Windows | false |

The library (`camera_pick_photo`) needs no camera. True does not mean the camera is allowed:
the permission is asked when the first `CameraView` mounts.

## The example

`examples/snap` shows the camera in a card with its shutter and a switch between cameras, the
library and the camera app, and the photos taken:

```bash
cd examples/snap
ui run android    # or ios, web, macos, linux, windows
```

## Tests

`eskiuc test` runs `tests/camera.esk` on this computer, with stand-ins for the platform's side:
each call reaching it, photos with paths that have spaces and with `blob:` URLs, each failure,
a malformed message, and no handler after the screen unmounts. `tests/frames.esk` checks the
YUV to RGB conversion against the reference formulas, each frame layout turned upright, and
`use_camera_frames` against a stand-in that lends frames.
