// <camera> on the web: a file input for the library and the camera (phones open their camera
// for capture), and the live view's frame for camera_capture (camera.mjs). Photos are blob:
// URLs, upright and at most 2048 pixels on the longer side.
mergeInto(LibraryManager.library, {
  camera_native_pick: function() { window.eskiuCamera.choose(false); },
  camera_native_take: function() { window.eskiuCamera.choose(true); },
  camera_native_capture: function() { window.eskiuCamera.capture(); },
});
