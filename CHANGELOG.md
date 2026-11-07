# Changelog

All notable changes to this package are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-11-07

### Added

- Live frames: `use_camera_frames(CameraFrameOptions, fn(*CameraFrame))` gets the mounted
  `CameraView`'s frames on the UI thread, borrowed by pointer from the platform's buffer for
  the handler's call (no copy, no text message). A frame that arrives while the handler is
  busy replaces the one waiting, so nothing queues. `CameraFrame` has the size, `format`
  (`CameraNV12`, `CameraNV21`, `CameraI420`, `CameraYUV420`, `CameraRGBA`), up to three
  `CameraPlane`s with row and pixel strides and sizes, `rotation`, `timestamp_ns`, `front`,
  `matrix` (`CameraBT601`, `CameraBT709`) and `full_range`. iOS lends the
  `AVCaptureVideoDataOutput`'s NV12 `CVPixelBuffer`, Android a `YUV_420_888` `Image`'s
  planes, the web the `<video>` read back as RGBA. See [docs/frames.md](docs/frames.md).
- `CameraFrame_to_rgba` (optionally turned upright), `CameraFrame_out_width` and
  `out_height`, `camera_yuv_coeffs` and `camera_yuv_to_rgb`: BT.601 and BT.709, full and
  limited range, in pure Eskiu.
- iOS links CoreMedia and CoreVideo.
