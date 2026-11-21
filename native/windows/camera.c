// <camera> on Windows: the system's open dialog for the photo library (any image file),
// decoded with GDI+, which the host links, and saved upright, at most 2048 pixels on its
// longer side, as a JPEG in the user's temporary folder. There is no camera support yet (it
// would need Media Foundation's capture): camera_take_photo, a CameraView and camera_capture
// answer unavailable, and use_camera_frames gets no frames. comdlg32.dll is loaded at run
// time. Results go to the "camera" channel (src/camera.esk).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <commdlg.h>
#include <gdiplus.h>
#include "ui_native.h"

static void emit(const char *payload) { ui_native_emit("camera", payload); }

// GDI+'s JPEG encoder.
static const CLSID kJpeg = {0x557cf401, 0x1a04, 0x11d3, {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
static const GUID kQuality = {0x1d5be4b5, 0xfa4a, 0x452d, {0x9c, 0xdd, 0x5d, 0xb3, 0x51, 0x05, 0xe7, 0xeb}};

// The turn and flip that make an image with EXIF orientation `value` upright.
static RotateFlipType uprightFor(int value) {
    switch (value) {
    case 2: return RotateNoneFlipX;
    case 3: return Rotate180FlipNone;
    case 4: return Rotate180FlipX;
    case 5: return Rotate90FlipX;
    case 6: return Rotate90FlipNone;
    case 7: return Rotate270FlipX;
    case 8: return Rotate270FlipNone;
    default: return RotateNoneFlipNone;
    }
}

static int orientation(GpImage *image) {
    UINT size = 0;
    if (GdipGetPropertyItemSize(image, 0x0112, &size) != Ok || size < sizeof(PropertyItem)) return 1;
    PropertyItem *item = (PropertyItem *)malloc(size);
    int value = 1;
    if (item && GdipGetPropertyItem(image, 0x0112, size, item) == Ok && item->type == 3 && item->length >= 2)
        value = *(unsigned short *)item->value;
    free(item);
    return value;
}

static void savePhoto(const wchar_t *file) {
    static ULONG_PTR token;
    if (!token) {
        GdiplusStartupInput input = {1, NULL, FALSE, FALSE};
        if (GdiplusStartup(&token, &input, NULL) != Ok) { emit("failed"); return; }
    }
    GpImage *image = NULL;
    if (GdipLoadImageFromFile(file, &image) != Ok || !image) { emit("failed"); return; }
    RotateFlipType turn = uprightFor(orientation(image));
    if (turn != RotateNoneFlipNone) GdipImageRotateFlip(image, turn);
    UINT width = 0, height = 0;
    GdipGetImageWidth(image, &width);
    GdipGetImageHeight(image, &height);
    UINT longer = width > height ? width : height;
    UINT w = width, h = height;
    if (longer > 2048) {
        w = (UINT)(width * 2048.0 / longer + 0.5);
        h = (UINT)(height * 2048.0 / longer + 0.5);
        if (!w) w = 1;
        if (!h) h = 1;
    }
    GpBitmap *out = NULL;
    GpGraphics *graphics = NULL;
    int ok = GdipCreateBitmapFromScan0((INT)w, (INT)h, 0, PixelFormat24bppRGB, NULL, &out) == Ok &&
             GdipGetImageGraphicsContext((GpImage *)out, &graphics) == Ok;
    if (ok) {
        GdipSetInterpolationMode(graphics, InterpolationModeHighQualityBicubic);
        ok = GdipDrawImageRectI(graphics, image, 0, 0, (INT)w, (INT)h) == Ok;
    }
    if (graphics) GdipDeleteGraphics(graphics);
    GdipDisposeImage(image);
    wchar_t folder[MAX_PATH], path[MAX_PATH + 64];
    char utf8[4 * MAX_PATH];
    if (ok && GetTempPathW(MAX_PATH, folder)) {
        swprintf(path, sizeof path / sizeof path[0], L"%lsphoto-%llu.jpg", folder,
                 (unsigned long long)GetTickCount64());
        ULONG quality = 90;
        EncoderParameters params;
        params.Count = 1;
        params.Parameter[0].Guid = kQuality;
        params.Parameter[0].NumberOfValues = 1;
        params.Parameter[0].Type = EncoderParameterValueTypeLong;
        params.Parameter[0].Value = &quality;
        ok = GdipSaveImageToFile((GpImage *)out, path, &kJpeg, &params) == Ok &&
             WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8, sizeof utf8, NULL, NULL) > 0;
    } else {
        ok = 0;
    }
    if (out) GdipDisposeImage((GpImage *)out);
    if (!ok) { emit("failed"); return; }
    char payload[sizeof utf8 + 64];
    snprintf(payload, sizeof payload, "photo %u %u %s", w, h, utf8);
    emit(payload);
}

typedef BOOL(WINAPI *OpenFn)(OPENFILENAMEW *);

void camera_native_pick(void) {
    static OpenFn open;
    if (!open) {
        HMODULE lib = LoadLibraryW(L"comdlg32.dll");
        open = lib ? (OpenFn)(void *)GetProcAddress(lib, "GetOpenFileNameW") : NULL;
    }
    if (!open) { emit("failed"); return; }
    wchar_t file[MAX_PATH * 4] = L"";
    OPENFILENAMEW dialog;
    memset(&dialog, 0, sizeof dialog);
    dialog.lStructSize = sizeof dialog;
    dialog.hwndOwner = ui_native_window();
    dialog.lpstrFilter = L"Images\0*.jpg;*.jpeg;*.png;*.gif;*.bmp;*.tif;*.tiff\0All files\0*.*\0";
    dialog.lpstrFile = file;
    dialog.nMaxFile = sizeof file / sizeof file[0];
    dialog.lpstrTitle = L"Choose a photo";
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
    if (!open(&dialog)) { emit("cancelled"); return; }
    savePhoto(file);
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

// The "camera" view: an empty child window that says, once mounted, that there is no camera.
static void CALLBACK report(HWND view, UINT message, UINT_PTR timer, DWORD time) {
    (void)message;
    (void)time;
    KillTimer(view, timer);
    emit("unavailable");
}

static HWND create(HWND parent, UiViewEmitter *emitter) {
    (void)emitter;
    HWND view = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, parent, NULL,
                                GetModuleHandleW(NULL), NULL);
    if (view) SetTimer(view, 1, 0, report);
    return view;
}

static void set(HWND view, const char *name, const char *value) {
    (void)view;
    (void)name;
    (void)value;
}

UI_NATIVE_SETUP(camera) { ui_register_view("camera", create, set); }
