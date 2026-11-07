// <camera> on Android: the externs Eskiu calls, into EskiuCamera and CameraView (Java) through
// JNI. A lent frame's planes are the direct buffers of a YUV_420_888 Image, read in place.
#include <jni.h>
#include <stdint.h>
#include "ui_native.h"

static void call(const char *method) {
    JNIEnv *env = ui_jni_env();
    jclass type = ui_find_class("org.eskiu.camera.EskiuCamera");
    if (!type) return;
    (*env)->CallStaticVoidMethod(env, type, (*env)->GetStaticMethodID(env, type, method, "()V"));
    (*env)->DeleteLocalRef(env, type);
}

void camera_native_pick(void) { call("pick"); }

void camera_native_take(void) { call("take"); }

void camera_native_capture(void) { call("capture"); }

void camera_native_frames(int on, int width, int height, int fps) {
    JNIEnv *env = ui_jni_env();
    jclass type = ui_find_class("org.eskiu.camera.CameraView");
    if (!type) return;
    jmethodID method = (*env)->GetStaticMethodID(env, type, "frames", "(ZIII)V");
    (*env)->CallStaticVoidMethod(env, type, method, (jboolean)(on != 0), width, height, fps);
    (*env)->DeleteLocalRef(env, type);
}

void camera_native_frame_release(void) {
    JNIEnv *env = ui_jni_env();
    jclass type = ui_find_class("org.eskiu.camera.CameraView");
    if (!type) return;
    (*env)->CallStaticVoidMethod(env, type, (*env)->GetStaticMethodID(env, type, "frameRelease", "()V"));
    (*env)->DeleteLocalRef(env, type);
}

// The planes' layout from Java, their addresses from the buffers. U and V samples two bytes
// apart in one buffer, a byte from each other, are one interleaved plane: NV12 when U comes
// first, NV21 when V does; one byte apart (pixel stride 1) they are I420; else the general
// three-plane layout.
int camera_native_frame_acquire(int64_t *info) {
    JNIEnv *env = ui_jni_env();
    jclass type = ui_find_class("org.eskiu.camera.CameraView");
    if (!type) return 0;
    jmethodID method = (*env)->GetStaticMethodID(env, type, "frameAcquire", "([J)[Ljava/nio/ByteBuffer;");
    jlongArray values = (*env)->NewLongArray(env, 24);
    jobjectArray buffers = (jobjectArray)(*env)->CallStaticObjectMethod(env, type, method, values);
    (*env)->DeleteLocalRef(env, type);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); buffers = NULL; }
    if (!buffers) { (*env)->DeleteLocalRef(env, values); return 0; }
    jlong got[24];
    (*env)->GetLongArrayRegion(env, values, 0, 24, got);
    (*env)->DeleteLocalRef(env, values);
    uint8_t *data[3] = {0, 0, 0};
    int ok = 1;
    for (int p = 0; p < 3; p++) {
        jobject buffer = (*env)->GetObjectArrayElement(env, buffers, p);
        uint8_t *base = buffer ? (uint8_t *)(*env)->GetDirectBufferAddress(env, buffer) : NULL;
        if (buffer) (*env)->DeleteLocalRef(env, buffer);
        if (!base) { ok = 0; break; }
        data[p] = base + got[9 + p * 4];
    }
    (*env)->DeleteLocalRef(env, buffers);
    if (!ok) { camera_native_frame_release(); return 0; }
    for (int i = 0; i < 24; i++) info[i] = got[i];
    for (int p = 0; p < 3; p++) info[9 + p * 4] = (int64_t)(intptr_t)data[p];
    int64_t u_pixel = got[11 + 4], v_pixel = got[11 + 8];
    int64_t u_row = got[10 + 4], v_row = got[10 + 8];
    uint8_t *u = data[1], *v = data[2];
    int64_t u_size = got[12 + 4], v_size = got[12 + 8];
    if (u_pixel == 2 && v_pixel == 2 && u_row == v_row && (v == u + 1 || u == v + 1)) {
        uint8_t *first = v == u + 1 ? u : v;
        uint8_t *end_u = u + u_size, *end_v = v + v_size;
        info[2] = v == u + 1 ? 0 : 1;
        info[3] = 2;
        info[13] = (int64_t)(intptr_t)first;
        info[16] = (int64_t)((end_u > end_v ? end_u : end_v) - first);
        for (int i = 17; i < 21; i++) info[i] = 0;
    } else {
        info[2] = u_pixel == 1 && v_pixel == 1 ? 2 : 3;
        info[3] = 3;
    }
    return 1;
}
