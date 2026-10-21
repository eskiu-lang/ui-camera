// The live "camera" view on Android: Camera2 into a TextureView, cropped to fill the box the
// layout gives it, and a JPEG still from an ImageReader for camera_capture.
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
import android.util.Size;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import java.nio.ByteBuffer;
import java.util.Arrays;
import org.eskiu.ui.UiActivity;

public final class CameraView extends TextureView implements TextureView.SurfaceTextureListener {
    // The view mounted last, which camera_capture captures from.
    private static CameraView live;

    private String facing = "back";
    private CameraDevice device;
    private CameraCaptureSession session;
    private ImageReader still;
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

    private void startPreview() {
        try {
            SurfaceTexture texture = getSurfaceTexture();
            if (texture == null || device == null) return;
            texture.setDefaultBufferSize(preview.getWidth(), preview.getHeight());
            Surface surface = new Surface(texture);
            CaptureRequest.Builder request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            request.addTarget(surface);
            device.createCaptureSession(Arrays.asList(surface, still.getSurface()), new CameraCaptureSession.StateCallback() {
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

    private void close() {
        if (session != null) { session.close(); session = null; }
        if (device != null) { device.close(); device = null; }
        if (still != null) { still.close(); still = null; }
        if (thread != null) { thread.quitSafely(); thread = null; }
    }
}
