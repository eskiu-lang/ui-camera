// The live "camera" view on Android: Camera2 into a TextureView, cropped to fill the box the
// layout gives it, a JPEG still from an ImageReader for camera_capture, and with
// use_camera_frames a YUV_420_888 ImageReader whose latest Image is lent to Eskiu (camera.c
// reads its planes' direct buffers by address).
package org.eskiu.camera;

import android.Manifest;
import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.graphics.ImageFormat;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Range;
import android.util.Size;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import java.nio.ByteBuffer;
import java.util.Arrays;
import org.eskiu.ui.UiActivity;

public final class CameraView extends TextureView implements TextureView.SurfaceTextureListener {
    // The view mounted last, which camera_capture captures from and frames come from.
    private static CameraView live;

    // What use_camera_frames asks for (camera_native_frames), read when the camera opens.
    private static boolean framesOn;
    private static int framesWidth, framesHeight, framesFps;

    // The latest frame, the one lent to Eskiu (they may be the same), and whether "frame" was
    // posted since the last acquire; guarded by `frameLock`. A new frame closes the one waiting
    // unless it is lent, so a busy handler sees the newest frame and the others are dropped.
    private static final Object frameLock = new Object();
    private static Image latest, lent;
    private static boolean latestFront, posted;
    private static int latestSensor;

    private String facing = "back";
    private CameraDevice device;
    private CameraCaptureSession session;
    private ImageReader still;
    private ImageReader frames;
    private Range<Integer> fpsRange;
    private Size preview;
    private int sensorOrientation;
    private boolean front;
    private HandlerThread thread;
    private Handler handler;

    static void register() {
        UiActivity.registerView("camera", new UiActivity.ViewFactory() {
            @Override public View create(Context context, UiActivity.ViewEvents events) { return new CameraView(context); }
            @Override public void set(View view, String name, String value) {
                CameraView camera = (CameraView)view;
                if (!name.equals("facing")) return;
                String next = value.isEmpty() ? "back" : value;
                if (next.equals(camera.facing)) return;
                camera.facing = next;
                if (camera.device != null) { camera.close(); camera.open(); }
            }
        });
    }

    CameraView(Context context) {
        super(context);
        setSurfaceTextureListener(this);
    }

    @Override protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        live = this;
    }

    @Override protected void onDetachedFromWindow() {
        close();
        if (live == this) live = null;
        super.onDetachedFromWindow();
    }

    // Off screen (the app in the background, another app's camera in front) the camera is
    // closed, for that app and for the battery, and opened again on the way back.
    @Override protected void onWindowVisibilityChanged(int visibility) {
        super.onWindowVisibilityChanged(visibility);
        if (visibility != VISIBLE) close();
        else if (isAvailable() && device == null && isAttachedToWindow()) open();
    }

    @Override public void onSurfaceTextureAvailable(SurfaceTexture texture, int width, int height) {
        UiActivity.requestPermissions(new String[] {Manifest.permission.CAMERA}, granted -> {
            if (!granted) { EskiuCamera.emit("denied"); return; }
            if (isAttachedToWindow()) open();
        });
    }
    @Override public void onSurfaceTextureSizeChanged(SurfaceTexture texture, int width, int height) { crop(); }
    @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture texture) { close(); return true; }
    @Override public void onSurfaceTextureUpdated(SurfaceTexture texture) {}

    @SuppressLint("MissingPermission")
    private void open() {
        if (thread != null) return;
        if (getContext().checkSelfPermission(Manifest.permission.CAMERA) != android.content.pm.PackageManager.PERMISSION_GRANTED) return;
        CameraManager manager = (CameraManager)getContext().getSystemService(Context.CAMERA_SERVICE);
        try {
            String chosen = null;
            int wanted = facing.equals("front") ? CameraCharacteristics.LENS_FACING_FRONT : CameraCharacteristics.LENS_FACING_BACK;
            for (String id : manager.getCameraIdList()) {
                Integer lens = manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING);
                if (lens != null && lens == wanted) { chosen = id; break; }
                if (chosen == null) chosen = id;
            }
            if (chosen == null) { EskiuCamera.emit("unavailable"); return; }
            CameraCharacteristics info = manager.getCameraCharacteristics(chosen);
            Integer orientation = info.get(CameraCharacteristics.SENSOR_ORIENTATION);
            sensorOrientation = orientation == null ? 90 : orientation;
            Integer lens = info.get(CameraCharacteristics.LENS_FACING);
            front = lens != null && lens == CameraCharacteristics.LENS_FACING_FRONT;
            StreamConfigurationMap map = info.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            preview = largest(map.getOutputSizes(SurfaceTexture.class), 1920);
            Size jpeg = largest(map.getOutputSizes(ImageFormat.JPEG), 4096);
            thread = new HandlerThread("camera");
            thread.start();
            handler = new Handler(thread.getLooper());
            still = ImageReader.newInstance(jpeg.getWidth(), jpeg.getHeight(), ImageFormat.JPEG, 2);
            still.setOnImageAvailableListener(this::stillReady, handler);
            fpsRange = null;
            if (framesOn) {
                Size size = frameSize(map.getOutputSizes(ImageFormat.YUV_420_888), framesWidth, framesHeight);
                // One waiting, one lent, and two for acquireLatestImage to step through.
                frames = ImageReader.newInstance(size.getWidth(), size.getHeight(), ImageFormat.YUV_420_888, 4);
                frames.setOnImageAvailableListener(this::frameReady, handler);
                fpsRange = frameRate(info.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES), framesFps);
            }
            manager.openCamera(chosen, new CameraDevice.StateCallback() {
                @Override public void onOpened(CameraDevice opened) { device = opened; startPreview(); }
                @Override public void onDisconnected(CameraDevice gone) { gone.close(); device = null; }
                @Override public void onError(CameraDevice failed, int error) { failed.close(); device = null; EskiuCamera.emit("unavailable"); }
            }, handler);
        } catch (CameraAccessException | RuntimeException error) {
            EskiuCamera.emit("unavailable");
        }
    }

    // The largest size whose longer side is at most `limit`.
    private static Size largest(Size[] sizes, int limit) {
        Size best = sizes[0];
        long area = 0;
        for (Size size : sizes) {
            long a = (long)size.getWidth() * size.getHeight();
            if (Math.max(size.getWidth(), size.getHeight()) <= limit && a > area) { best = size; area = a; }
        }
        return best;
    }

    // The smallest size that holds `width` x `height` (as landscape), else the largest.
    private static Size frameSize(Size[] sizes, int width, int height) {
        int longer = Math.max(width, height), shorter = Math.min(width, height);
        Size best = null, largest = sizes[0];
        for (Size size : sizes) {
            long area = (long)size.getWidth() * size.getHeight();
            if (area > (long)largest.getWidth() * largest.getHeight()) largest = size;
            int l = Math.max(size.getWidth(), size.getHeight()), s = Math.min(size.getWidth(), size.getHeight());
            if (l >= longer && s >= shorter && (best == null || area < (long)best.getWidth() * best.getHeight())) best = size;
        }
        return best != null ? best : largest;
    }

    // The auto-exposure range for at most `fps` frames a second: the highest top at or under
    // it, the widest of those (so exposure can still lengthen in the dark); null for any.
    private static Range<Integer> frameRate(Range<Integer>[] ranges, int fps) {
        if (ranges == null || fps <= 0) return null;
        Range<Integer> best = null;
        for (Range<Integer> range : ranges) {
            if (range.getUpper() > fps) continue;
            if (best == null || range.getUpper() > best.getUpper() ||
                (range.getUpper().equals(best.getUpper()) && range.getLower() < best.getLower())) best = range;
        }
        return best;
    }

    private void startPreview() {
        try {
            SurfaceTexture texture = getSurfaceTexture();
            if (texture == null || device == null) return;
            texture.setDefaultBufferSize(preview.getWidth(), preview.getHeight());
            Surface surface = new Surface(texture);
            CaptureRequest.Builder request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            request.addTarget(surface);
            java.util.List<Surface> targets = new java.util.ArrayList<>(Arrays.asList(surface, still.getSurface()));
            if (frames != null) {
                request.addTarget(frames.getSurface());
                targets.add(frames.getSurface());
                if (fpsRange != null) request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange);
            }
            device.createCaptureSession(targets, new CameraCaptureSession.StateCallback() {
                @Override public void onConfigured(CameraCaptureSession configured) {
                    session = configured;
                    try {
                        request.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);
                        configured.setRepeatingRequest(request.build(), null, handler);
                    } catch (CameraAccessException | IllegalStateException error) { /* closed meanwhile */ }
                    post(CameraView.this::crop);
                }
                @Override public void onConfigureFailed(CameraCaptureSession failed) { EskiuCamera.emit("unavailable"); }
            }, handler);
        } catch (CameraAccessException | IllegalStateException error) {
            EskiuCamera.emit("unavailable");
        }
    }

    // The preview's buffer is the sensor's landscape; on a portrait screen it is turned, and
    // scaled so it covers the view, as an aspect fill.
    private void crop() {
        if (preview == null || getWidth() == 0 || getHeight() == 0) return;
        boolean turned = sensorOrientation % 180 != 0;
        float bufferWidth = turned ? preview.getHeight() : preview.getWidth();
        float bufferHeight = turned ? preview.getWidth() : preview.getHeight();
        float cover = Math.max(getWidth() / bufferWidth, getHeight() / bufferHeight);
        Matrix matrix = new Matrix();
        matrix.setScale(bufferWidth * cover / getWidth(), bufferHeight * cover / getHeight(), getWidth() / 2f, getHeight() / 2f);
        setTransform(matrix);
    }

    static void captureLive() {
        CameraView view = live;
        if (view == null || view.device == null || view.session == null) { EskiuCamera.emit("unavailable"); return; }
        try {
            CaptureRequest.Builder request = view.device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE);
            request.addTarget(view.still.getSurface());
            view.session.capture(request.build(), null, view.handler);
        } catch (CameraAccessException | IllegalStateException error) {
            EskiuCamera.emit("failed");
        }
    }

    private void stillReady(ImageReader reader) {
        try (Image image = reader.acquireLatestImage()) {
            if (image == null) return;
            ByteBuffer buffer = image.getPlanes()[0].getBuffer();
            byte[] bytes = new byte[buffer.remaining()];
            buffer.get(bytes);
            // Portrait: the sensor's frame turned upright; a front camera's mirrored back.
            android.graphics.Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            if (front && bitmap != null) {
                Matrix mirror = new Matrix();
                mirror.preScale(-1, 1);
                bitmap = android.graphics.Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), mirror, true);
            }
            EskiuCamera.save(bitmap, front ? (360 - sensorOrientation) % 360 : sensorOrientation);
        }
    }

    // The frame reader's newest image becomes the one waiting; "frame" is posted if none is.
    private void frameReady(ImageReader reader) {
        Image image;
        try { image = reader.acquireLatestImage(); }
        catch (IllegalStateException error) { return; }
        if (image == null) return;
        boolean post;
        synchronized (frameLock) {
            if (frames != reader) { image.close(); return; }
            if (latest != null && latest != lent) latest.close();
            latest = image;
            latestFront = front;
            latestSensor = sensorOrientation;
            post = !posted;
            posted = true;
        }
        if (post) UiActivity.emit("camera_frame", "frame");
    }

    // camera_native_frames: frames on with these options, or off; the live camera is opened
    // again to add or drop the frame stream.
    static void frames(boolean on, int width, int height, int fps) {
        boolean changed = framesOn != on || (on && (framesWidth != width || framesHeight != height || framesFps != fps));
        framesOn = on;
        framesWidth = width;
        framesHeight = height;
        framesFps = fps;
        // A handler that went away may have left a post unanswered: post again with the next.
        synchronized (frameLock) { posted = false; }
        CameraView view = live;
        if (changed && view != null && view.device != null) { view.close(); view.open(); }
    }

    // camera_native_frame_acquire: lends the waiting frame. `info` gets the layout of
    // camera_frame_read (src/camera.esk) but the plane addresses, which camera.c reads from
    // the returned buffers, and each plane's buffer position in the address slots.
    static java.nio.ByteBuffer[] frameAcquire(long[] info) {
        frameRelease();
        Image image;
        boolean isFront;
        int sensor;
        synchronized (frameLock) {
            image = latest;
            posted = false;
            if (image == null) return null;
            lent = image;
            isFront = latestFront;
            sensor = latestSensor;
        }
        try {
            Image.Plane[] planes = image.getPlanes();
            if (planes.length != 3) { frameRelease(); return null; }
            int display = 0;
            android.app.Activity activity = UiActivity.current();
            if (activity != null) display = 90 * activity.getWindowManager().getDefaultDisplay().getRotation();
            info[0] = image.getWidth();
            info[1] = image.getHeight();
            info[3] = 3;
            info[4] = isFront ? (sensor + display) % 360 : (sensor - display + 360) % 360;
            info[5] = isFront ? 1 : 0;
            info[6] = 0;
            info[7] = 1;
            info[8] = image.getTimestamp();
            java.nio.ByteBuffer[] buffers = new java.nio.ByteBuffer[3];
            for (int p = 0; p < 3; p++) {
                buffers[p] = planes[p].getBuffer();
                info[9 + p * 4] = buffers[p].position();
                info[10 + p * 4] = planes[p].getRowStride();
                info[11 + p * 4] = planes[p].getPixelStride();
                info[12 + p * 4] = buffers[p].remaining();
            }
            return buffers;
        } catch (IllegalStateException error) {
            frameRelease();
            return null;
        }
    }

    // camera_native_frame_release: the lent frame is closed unless it is still the one waiting.
    static void frameRelease() {
        synchronized (frameLock) {
            if (lent != null && lent != latest) lent.close();
            lent = null;
        }
    }

    private void close() {
        if (session != null) { session.close(); session = null; }
        if (device != null) { device.close(); device = null; }
        if (still != null) { still.close(); still = null; }
        if (frames != null) {
            ImageReader reader = frames;
            synchronized (frameLock) {
                frames = null;
                if (latest != null && latest != lent) latest.close();
                latest = null;
                posted = false;
            }
            reader.close();
        }
        if (thread != null) { thread.quitSafely(); thread = null; }
    }
}
