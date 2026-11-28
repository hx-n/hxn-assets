#include <jni.h>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    JavaVM *vm;
    jobject manager;
    AAssetManager *native;
} HxnFileAndroid;

static JNIEnv *attach(JavaVM *vm, int *attached) {
    JNIEnv *env = NULL;
    *attached = 0;
    jint result = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (result == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return NULL;
        *attached = 1;
    } else if (result != JNI_OK) return NULL;
    return env;
}
void *hxn_file_android_new(void *given_vm, void *context, char **directory) {
    JavaVM *vm = (JavaVM *)given_vm;
    int attached = 0;
    JNIEnv *env = attach(vm, &attached);
    HxnFileAndroid *state = NULL;
    *directory = NULL;
    if (!env) return NULL;
    if ((*env)->PushLocalFrame(env, 24) < 0) goto end;
    state = calloc(1, sizeof(*state));
    if (!state) goto frame;
    state->vm = vm;
    jclass cls = (*env)->GetObjectClass(env, (jobject)context);
    if (!cls) goto fail;
    jmethodID assets = (*env)->GetMethodID(env, cls, "getAssets", "()Landroid/content/res/AssetManager;");
    if (!assets) goto fail;
    jobject manager = (*env)->CallObjectMethod(env, (jobject)context, assets);
    if ((*env)->ExceptionCheck(env) || !manager) goto fail;
    state->manager = (*env)->NewGlobalRef(env, manager);
    if (!state->manager) goto fail;
    state->native = AAssetManager_fromJava(env, manager);
    if (!state->native) goto fail;
    jmethodID files = (*env)->GetMethodID(env, cls, "getFilesDir", "()Ljava/io/File;");
    if (!files) goto fail;
    jobject folder = (*env)->CallObjectMethod(env, (jobject)context, files);
    if ((*env)->ExceptionCheck(env) || !folder) goto fail;
    jclass file_cls = (*env)->GetObjectClass(env, folder);
    if (!file_cls) goto fail;
    jmethodID absolute = (*env)->GetMethodID(env, file_cls, "getAbsolutePath", "()Ljava/lang/String;");
    if (!absolute) goto fail;
    jstring path = (jstring)(*env)->CallObjectMethod(env, folder, absolute);
    if ((*env)->ExceptionCheck(env) || !path) goto fail;
    const char *bytes = (*env)->GetStringUTFChars(env, path, NULL);
    if (!bytes) goto fail;
    *directory = strdup(bytes);
    (*env)->ReleaseStringUTFChars(env, path, bytes);
    if (!*directory) goto fail;
    goto frame;
fail:
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (state->manager) (*env)->DeleteGlobalRef(env, state->manager);
    free(state); state = NULL;
frame:
    (*env)->PopLocalFrame(env, NULL);
end:
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (attached) (*vm)->DetachCurrentThread(vm);
    return state;
}
void hxn_file_android_free(void *pointer) {
    HxnFileAndroid *state = pointer;
    int attached = 0;
    JNIEnv *env = attach(state->vm, &attached);
    if (env) (*env)->DeleteGlobalRef(env, state->manager);
    if (attached) (*state->vm)->DetachCurrentThread(state->vm);
    free(state);
}
void hxn_file_string_free(char *value) { free(value); }

/* Defined by the window host of a program built as an Android app. Weak, so a program
   without one, such as an executable run under adb shell, links and finds no host. */
extern int hxn_android_context(void **vm, void **activity) __attribute__((weak));

int hxn_file_android_host(void **vm, void **activity) {
    return hxn_android_context ? hxn_android_context(vm, activity) : 0;
}
void *hxn_file_android_open(void *pointer, const char *name, int64_t *size) {
    HxnFileAndroid *state = pointer;
    AAsset *asset = AAssetManager_open(state->native, name, AASSET_MODE_STREAMING);
    if (asset) *size = AAsset_getLength64(asset);
    return asset;
}
int hxn_file_android_read(void *asset, void *bytes, unsigned size) { return AAsset_read(asset, bytes, size); }
void hxn_file_android_close(void *asset) { AAsset_close(asset); }
