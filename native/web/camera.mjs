// <camera> on the web: the "camera" view (a <video> on getUserMedia, cropped to fill its box)
// and the photo helpers camera.js calls through window.eskiuCamera.
export function setup(ui) {
  const emit = payload => ui.emit('camera', payload);
  let live = null;

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
          .then(s => { stream = s; video.srcObject = s; live = video; })
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
