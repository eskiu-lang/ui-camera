// <camera> on Linux: GTK's file dialog for the photo library (any image file), decoded with
// GdkPixbuf, which GTK already links, and saved upright, at most 2048 pixels on its longer
// side, as a JPEG in the user's cache directory. There is no camera support yet (it would need
// PipeWire's camera portal or V4L2): camera_take_photo, a CameraView and camera_capture answer
// unavailable, and use_camera_frames gets no frames. Results go to the "camera" channel
// (src/camera.esk).
#include <stdint.h>
#include <stdio.h>
#include "ui_native.h"

static void emit(const char *payload) { ui_native_emit("camera", payload); }

static void savePhoto(const char *file) {
    GdkPixbuf *loaded = gdk_pixbuf_new_from_file(file, NULL);
    if (!loaded) { emit("failed"); return; }
    GdkPixbuf *upright = gdk_pixbuf_apply_embedded_orientation(loaded);
    g_object_unref(loaded);
    if (!upright) { emit("failed"); return; }
    int width = gdk_pixbuf_get_width(upright), height = gdk_pixbuf_get_height(upright);
    int longer = width > height ? width : height;
    if (longer > 2048) {
        double scale = 2048.0 / longer;
        int w = (int)(width * scale + 0.5), h = (int)(height * scale + 0.5);
        GdkPixbuf *scaled = gdk_pixbuf_scale_simple(upright, w > 0 ? w : 1, h > 0 ? h : 1, GDK_INTERP_BILINEAR);
        g_object_unref(upright);
        if (!scaled) { emit("failed"); return; }
        upright = scaled;
        width = gdk_pixbuf_get_width(upright);
        height = gdk_pixbuf_get_height(upright);
    }
    const char *app = g_get_prgname();
    char *folder = g_build_filename(g_get_user_cache_dir(), app ? app : "eskiu-ui", NULL);
    g_mkdir_with_parents(folder, 0700);
    char name[64];
    snprintf(name, sizeof name, "photo-%lld.jpg", (long long)(g_get_real_time() / 1000));
    char *path = g_build_filename(folder, name, NULL);
    gboolean ok = gdk_pixbuf_save(upright, path, "jpeg", NULL, "quality", "90", NULL);
    g_object_unref(upright);
    if (ok) {
        char *payload = g_strdup_printf("photo %d %d %s", width, height, path);
        emit(payload);
        g_free(payload);
    } else {
        emit("failed");
    }
    g_free(path);
    g_free(folder);
}

static void chosen(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error);
    if (!file) {
        emit(error && g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED) ? "cancelled" : "failed");
        if (error) g_error_free(error);
        return;
    }
    char *path = g_file_get_path(file);
    g_object_unref(file);
    if (path) savePhoto(path);
    else emit("failed");
    g_free(path);
}

void camera_native_pick(void) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Choose a photo");
    GtkFileFilter *images = gtk_file_filter_new();
    gtk_file_filter_set_name(images, "Images");
    gtk_file_filter_add_mime_type(images, "image/*");
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, images);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    gtk_file_dialog_set_default_filter(dialog, images);
    g_object_unref(filters);
    g_object_unref(images);
    gtk_file_dialog_open(dialog, ui_native_window(), NULL, chosen, NULL);
    g_object_unref(dialog);
}

void camera_native_take(void) { emit("unavailable"); }

void camera_native_capture(void) { emit("unavailable"); }

void camera_native_frames(int on, int width, int height, int fps) {
    (void)on;
    (void)width;
    (void)height;
    (void)fps;
}

int camera_native_frame_acquire(int64_t *info) {
    (void)info;
    return 0;
}

void camera_native_frame_release(void) {}

// The "camera" view: a black box that says, once mounted, that there is no camera.
static GtkWidget *create(UiViewEmitter *emitter) {
    (void)emitter;
    emit("unavailable");
    return gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
}

static void set(GtkWidget *view, const char *name, const char *value) {
    (void)view;
    (void)name;
    (void)value;
}

UI_NATIVE_SETUP(camera) { ui_register_view("camera", create, set); }
