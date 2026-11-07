// <camera> on the web: a file input for the library and the camera (phones open their camera
// for capture), the live view's frame for camera_capture, and its frames for
// use_camera_frames (camera.mjs). Photos are blob: URLs, upright and at most 2048 pixels on
// the longer side.
mergeInto(LibraryManager.library, {
  camera_native_pick: function() { window.eskiuCamera.choose(false); },
  camera_native_take: function() { window.eskiuCamera.choose(true); },
  camera_native_capture: function() { window.eskiuCamera.capture(); },
  camera_native_frames: function(on, width, height, fps) { window.eskiuCamera.frames(on, width, height, fps); },
  // The live view's current picture drawn into an RGBA buffer in the app's memory (kept
  // from one frame to the next), described in `info` (24 int64 values, camera_frame_read's
  // layout in src/camera.esk).
  camera_native_frame_acquire__deps: ['malloc', 'free'],
  camera_native_frame_acquire: function(info) {
    const frame = window.eskiuCamera.grab();
    if (!frame) return 0;
    const bytes = frame.width * frame.height * 4;
    const state = Module['cameraFrame'] || (Module['cameraFrame'] = {pointer: 0, bytes: 0});
    if (state.bytes < bytes) {
      if (state.pointer) _free(state.pointer);
      state.pointer = _malloc(bytes);
      state.bytes = state.pointer ? bytes : 0;
      if (!state.pointer) return 0;
    }
    HEAPU8.set(frame.data, state.pointer);
    const put = (index, value) => {
      HEAP32[(info >> 2) + index * 2] = value % 4294967296;
      HEAP32[(info >> 2) + index * 2 + 1] = Math.floor(value / 4294967296);
    };
    for (let i = 0; i < 24; i++) put(i, 0);
    put(0, frame.width);
    put(1, frame.height);
    put(2, 4);
    put(3, 1);
    put(5, frame.front ? 1 : 0);
    put(7, 1);
    put(8, frame.time);
    put(9, state.pointer);
    put(10, frame.width * 4);
    put(11, 4);
    put(12, bytes);
    return 1;
  },
  camera_native_frame_release: function() {},
});
