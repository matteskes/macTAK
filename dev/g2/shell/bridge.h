#ifndef MACTAK_SHELL_BRIDGE_H
#define MACTAK_SHELL_BRIDGE_H

/* The JVM bootstrap surface the Swift shell uses (main.swift). The fiddly
 * bits — dlopen path probing for libjli and the JNI_CreateJavaVM call —
 * live in jni_boot.c; everything above this line is Swift. jni.h comes from
 * -I"$JDK/include" -I"$JDK/include/darwin" (build-shell.sh). */

#include <jni.h>
#include <stddef.h>

/* Locate, dlopen and bind JNI_CreateJavaVM from libjli.dylib.
 * Probes (NOTES §M3, verified 2026-11-05): $JAVA_HOME (run.sh sets JDK 21)
 * or /usr/libexec/java_home -v 21, then — relative to that home — the JDK 8
 * layout jre/lib/jli/libjli.dylib, its bundle copy
 * Contents/MacOS/libjli.dylib, and the JDK 9+ layout lib/libjli.dylib.
 * Returns the path that loaded (static storage), or NULL with err filled. */
const char *mactak_find_libjli(char *err, size_t errLen);

/* Create the JVM with the given options (char* strings; copied by
 * JNI_CreateJavaVM, but must stay valid for the duration of the call).
 * Returns JNI_OK (0) on success; on failure the JNI error code, with a
 * message in err. The resulting JavaVM/JNIEnv are kept here — fetch with
 * mactak_vm()/mactak_env(). */
int mactak_create_jvm(char **options, int nOptions, char *err, size_t errLen);

/* JNIEnv is `const struct JNINativeInterface_ *` in this header's C mode, so
 * these return pointer-to-that — the JNIEnv* every JNI function takes as its
 * first argument, whose target is the function table (C: (*env)->FindClass). */
JavaVM *mactak_vm(void);
JNIEnv *mactak_env(void);

#endif /* MACTAK_SHELL_BRIDGE_H */