// <camera> on Android: the externs Eskiu calls, into EskiuCamera (Java) through JNI.
#include <jni.h>
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
