// <camera> on Android: the system's photo picker and camera app through activity results, and
// the live "camera" view (CameraView.java). Every photo is saved upright, at most 2048 pixels
// on its longer side, as a JPEG in the app's cache; results go to the "camera" channel.
// camera.c calls pick, take and capture from Eskiu.
package org.eskiu.camera;

import android.Manifest;
import android.app.Activity;
import android.content.ContentValues;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import org.eskiu.ui.UiActivity;

public final class EskiuCamera {
    public static void setup() { CameraView.register(); }

    static void emit(String payload) { UiActivity.emit("camera", payload); }

    public static void pick() {
        Intent intent;
        if (Build.VERSION.SDK_INT >= 33) {
            intent = new Intent(MediaStore.ACTION_PICK_IMAGES);
        } else {
            intent = new Intent(Intent.ACTION_GET_CONTENT);
            intent.setType("image/*");
            intent.addCategory(Intent.CATEGORY_OPENABLE);
        }
        UiActivity.startForResult(intent, (code, data) -> {
            Uri uri = data == null ? null : data.getData();
            if (code != Activity.RESULT_OK || uri == null) { emit("cancelled"); return; }
            saveFrom(uri, 0, false);
        });
    }

    // The camera app writes into a MediaStore entry of ours; the photo is copied out of it
    // and the entry deleted.
    public static void take() {
        Activity activity = UiActivity.current();
        if (activity == null) return;
        if (!activity.getPackageManager().hasSystemFeature(android.content.pm.PackageManager.FEATURE_CAMERA_ANY)) {
            emit("unavailable");
            return;
        }
        // An app that declares the camera permission must hold it to use the camera app.
        UiActivity.requestPermissions(new String[] {Manifest.permission.CAMERA}, granted -> {
            if (!granted) { emit("denied"); return; }
            ContentValues values = new ContentValues();
            values.put(MediaStore.Images.Media.DISPLAY_NAME, "eskiu-" + System.currentTimeMillis() + ".jpg");
            values.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg");
            Uri uri = activity.getContentResolver().insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
            if (uri == null) { emit("failed"); return; }
            Intent intent = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
            intent.putExtra(MediaStore.EXTRA_OUTPUT, uri);
            intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            UiActivity.startForResult(intent, (code, data) -> {
                if (code != Activity.RESULT_OK) {
                    activity.getContentResolver().delete(uri, null, null);
                    emit("cancelled");
                    return;
                }
                saveFrom(uri, 0, true);
            });
        });
    }

    public static void capture() { CameraView.captureLive(); }

    // The image at `uri` saved as a photo, off the UI thread, turned `extra` degrees on top of
    // what its EXIF says; `delete` removes the MediaStore entry after.
    static void saveFrom(Uri uri, int extra, boolean delete) {
        Activity activity = UiActivity.current();
        if (activity == null) return;
        new Thread(() -> {
            try {
                int rotation = extra;
                try (InputStream in = activity.getContentResolver().openInputStream(uri)) {
                    rotation += degrees(new ExifInterface(in).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL));
                }
                Bitmap bitmap;
                try (InputStream in = activity.getContentResolver().openInputStream(uri)) {
                    bitmap = BitmapFactory.decodeStream(in);
                }
                if (delete) activity.getContentResolver().delete(uri, null, null);
                save(bitmap, rotation);
            } catch (Exception error) {
                emit("failed");
            }
        }).start();
    }

    static int degrees(int orientation) {
        if (orientation == ExifInterface.ORIENTATION_ROTATE_90) return 90;
        if (orientation == ExifInterface.ORIENTATION_ROTATE_180) return 180;
        if (orientation == ExifInterface.ORIENTATION_ROTATE_270) return 270;
        return 0;
    }

    // `bitmap` turned `rotation` degrees and scaled to 2048 pixels, written as a JPEG.
    static void save(Bitmap bitmap, int rotation) {
        Activity activity = UiActivity.current();
        if (bitmap == null || activity == null) { emit("failed"); return; }
        float scale = Math.min(1f, 2048f / Math.max(bitmap.getWidth(), bitmap.getHeight()));
        Matrix matrix = new Matrix();
        matrix.postScale(scale, scale);
        matrix.postRotate(rotation % 360);
        Bitmap upright = Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, true);
        File file = new File(activity.getCacheDir(), "photo-" + System.currentTimeMillis() + ".jpg");
        try (FileOutputStream out = new FileOutputStream(file)) {
            upright.compress(Bitmap.CompressFormat.JPEG, 90, out);
        } catch (Exception error) {
            emit("failed");
            return;
        }
        emit("photo " + upright.getWidth() + " " + upright.getHeight() + " " + file.getAbsolutePath());
    }
}
