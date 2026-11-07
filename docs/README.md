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

The simulator has no camera: `CameraView` and `camera_take_photo` give `PhotoUnavailable`
there, and the library works. The Android emulator's virtual camera works.

## The example

`examples/snap` shows the camera in a card with its shutter and a switch between cameras, the
library and the camera app, and the photos taken:

```bash
cd examples/snap
ui run android    # or ios, web
```

## Tests

`eskiuc test` runs `tests/camera.esk` on this computer, with stand-ins for the platform's side:
each call reaching it, photos with paths that have spaces and with `blob:` URLs, each failure,
a malformed message, and no handler after the screen unmounts. `tests/frames.esk` checks the
YUV to RGB conversion against the reference formulas, each frame layout turned upright, and
`use_camera_frames` against a stand-in that lends frames.
