// <camera> on the web: the "camera" view (a <video> on getUserMedia, cropped to fill its box),
// the photo helpers camera.js calls through window.eskiuCamera, and frames for
// use_camera_frames: a timer at the asked rate posts "frame" when none is waiting, and
// camera_native_frame_acquire reads the video through a canvas as RGBA (the web gives no YUV).
export function setup(ui) {
  const emit = payload => ui.emit('camera', payload);
  let live = null;
  let liveFront = false;

  // Frames: the options asked for, the timer, whether "frame" waits for an acquire, and the
  // canvas the video is read through.
  const frames = {on: false, width: 0, height: 0, fps: 0, timer: 0, posted: false, canvas: null};

  // A drawable (an image, a video frame) as a JPEG blob: URL, scaled to 2048 pixels.
  const save = (source, width, height) => {
    const scale = Math.min(1, 2048 / Math.max(width, height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(width * scale);
    canvas.height = Math.round(height * scale);
    canvas.getContext('2d').drawImage(source, 0, 0, canvas.width, canvas.height);
    canvas.toBlob(blob => {
      if (!blob) { emit('failed'); return; }
      emit(`photo ${canvas.width} ${canvas.height} ${URL.createObjectURL(blob)}`);
    }, 'image/jpeg', 0.9);
  };

  window.eskiuCamera = {
    // A file input, in the page so automation and assistive tools can find it.
    choose(capture) {
      const input = document.createElement('input');
      input.type = 'file';
      input.accept = 'image/*';
      if (capture) input.capture = 'environment';
      input.style.display = 'none';
      document.body.append(input);
      input.addEventListener('cancel', () => { input.remove(); emit('cancelled'); });
      input.addEventListener('change', () => {
        const file = input.files[0];
        input.remove();
        if (!file) { emit('cancelled'); return; }
        const url = URL.createObjectURL(file);
        const image = new Image();
        // The browser applies the photo's EXIF orientation when it draws it.
        image.onload = () => { save(image, image.naturalWidth, image.naturalHeight); URL.revokeObjectURL(url); };
        image.onerror = () => { URL.revokeObjectURL(url); emit('failed'); };
        image.src = url;
      });
      input.click();
    },
    capture() {
      const video = live;
      if (!video || !video.videoWidth) { emit('unavailable'); return; }
      save(video, video.videoWidth, video.videoHeight);
    },
  };

  // Frames are read at most at the asked rate; one "frame" waits at a time, so a busy app
  // gets the newest picture when it asks.
  window.eskiuCamera.frames = (on, width, height, fps) => {
    clearInterval(frames.timer);
    Object.assign(frames, {on: !!on, width, height, fps, timer: 0, posted: false});
    if (!on) return;
    frames.timer = setInterval(() => {
      if (frames.posted || !live || !live.videoWidth || live.readyState < 2) return;
      frames.posted = true;
      emitFrame();
    }, 1000 / Math.max(1, Math.min(fps || 30, 60)));
  };
  // The video's current picture, scaled down to fit the asked size, as RGBA.
  window.eskiuCamera.grab = () => {
    frames.posted = false;
    const video = live;
    if (!video || !video.videoWidth) return null;
    const scale = Math.min(1, frames.width / video.videoWidth || 1, frames.height / video.videoHeight || 1);
    const width = Math.max(1, Math.round(video.videoWidth * scale));
    const height = Math.max(1, Math.round(video.videoHeight * scale));
    const canvas = frames.canvas || (frames.canvas = document.createElement('canvas'));
    if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
    const context = canvas.getContext('2d', {willReadFrequently: true});
    context.drawImage(video, 0, 0, width, height);
    return {width, height, front: liveFront, time: Math.round(performance.now() * 1e6),
            data: context.getImageData(0, 0, width, height).data};
  };
  const emitFrame = () => ui.emit('camera_frame', 'frame');

  ui.registerView('camera', {
    create() {
      const video = document.createElement('video');
      video.autoplay = true;
      video.muted = true;
      video.playsInline = true;
      Object.assign(video.style, {width: '100%', height: '100%', objectFit: 'cover', background: '#000'});
      let stream = null;
      const start = facing => {
        if (stream) stream.getTracks().forEach(track => track.stop());
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { emit('unavailable'); return; }
        navigator.mediaDevices.getUserMedia({video: {facingMode: facing === 'front' ? 'user' : 'environment'}})
          .then(s => { stream = s; video.srcObject = s; live = video; liveFront = facing === 'front'; })
          .catch(error => emit(error && error.name === 'NotAllowedError' ? 'denied' : 'unavailable'));
      };
      let facing = 'back';
      start(facing);
      return {
        element: video,
        set(name, value) {
          if (name === 'facing' && (value || 'back') !== facing) { facing = value || 'back'; start(facing); }
        },
        dispose() {
          if (stream) stream.getTracks().forEach(track => track.stop());
          if (live === video) live = null;
        },
      };
    },
  });
}
