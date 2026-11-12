/* jni_boot.c — the libjli bootstrap for the macTAK M3.2 shell (see bridge.h
 * for the surface). Why C and not Swift: the probes are string surgery over
 * dlopen paths, and JNI_CreateJavaVM's JDK1_1InitArgs/JavaVMInitArgs union
 * is C-shaped. The JVM, once created, is driven from Swift. */

#include "bridge.h"

#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static JavaVM *g_vm = NULL;
static JNIEnv *g_env = NULL;
static void *g_jli = NULL;
static char g_libjliPath[PATH_MAX];
static char g_javaHome[PATH_MAX];

typedef jint (*CreateJavaVM_t)(JavaVM **, void **, void *);

/* $JAVA_HOME (run.sh sets JDK 21), else `/usr/libexec/java_home -v 21`. Returns g_javaHome, or
 * NULL with err filled. */
static const char *resolve_java_home(char *err, size_t errLen) {
    const char *home = getenv("JAVA_HOME");
    if (home && *home) {
        snprintf(g_javaHome, sizeof g_javaHome, "%s", home);
        return g_javaHome;
    }
    FILE *p = popen("/usr/libexec/java_home -v 21 2>/dev/null", "r");
    if (!p) { snprintf(err, errLen, "could not run /usr/libexec/java_home"); return NULL; }
    char line[PATH_MAX] = {0};
    const char *got = fgets(line, sizeof line, p);
    const int rc = pclose(p);
    if (!got || rc != 0) {
        snprintf(err, errLen, "no JAVA_HOME and /usr/libexec/java_home -v 21 found nothing");
        return NULL;
    }
    line[strcspn(line, "\n")] = '\0';
    snprintf(g_javaHome, sizeof g_javaHome, "%s", line);
    return g_javaHome;
}

const char *mactak_find_libjli(char *err, size_t errLen) {
    const char *home = resolve_java_home(err, errLen);
    if (!home) return NULL;

    /* Probe order: the JDK 8 layout, the bundle copy, then the 9+ layout
     * that JDK 21 uses. First path that dlopens wins. */
    const char *rel[] = {
        "jre/lib/jli/libjli.dylib",      /* JDK 8 layout */
        "Contents/Home/jre/lib/jli/libjli.dylib",  /* a bundle root handed directly */
        "Contents/MacOS/libjli.dylib",   /* JDK 8 bundle copy */
        "lib/libjli.dylib",              /* JDK 9+ */
    };
    char path[PATH_MAX];
    for (size_t i = 0; i < sizeof rel / sizeof rel[0]; i++) {
        snprintf(path, sizeof path, "%s/%s", home, rel[i]);
        void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!h) continue;
        CreateJavaVM_t create = (CreateJavaVM_t)dlsym(h, "JNI_CreateJavaVM");
        if (!create) { dlclose(h); continue; }
        g_jli = h;
        snprintf(g_libjliPath, sizeof g_libjliPath, "%s", path);
        return g_libjliPath;
    }
    snprintf(err, errLen,
             "no loadable libjli.dylib under %s "
             "(tried jre/lib/jli, Contents/Home/jre/lib/jli, Contents/MacOS, lib)",
             home);
    return NULL;
}

int mactak_create_jvm(char **options, int nOptions, char *err, size_t errLen) {
    if (!g_jli) { snprintf(err, errLen, "call mactak_find_libjli first"); return -1; }
    CreateJavaVM_t create = (CreateJavaVM_t)dlsym(g_jli, "JNI_CreateJavaVM");
    if (!create) { snprintf(err, errLen, "JNI_CreateJavaVM vanished from libjli"); return -1; }

    JavaVMInitArgs args;
    memset(&args, 0, sizeof args);
    args.version = JNI_VERSION_1_8;   /* JDK 21 accepts it */
    args.nOptions = nOptions;
    args.options = malloc((size_t)(nOptions > 0 ? nOptions : 1) * sizeof(JavaVMOption));
    if (!args.options) { snprintf(err, errLen, "out of memory"); return -1; }
    for (int i = 0; i < nOptions; i++) {
        args.options[i].optionString = options[i];
        args.options[i].extraInfo = NULL;
    }
    args.ignoreUnrecognized = JNI_FALSE;   /* a typo'd -D must fail loudly */

    jint rc = create(&g_vm, (void **)&g_env, &args);
    free(args.options);
    if (rc != JNI_OK) {
        snprintf(err, errLen, "JNI_CreateJavaVM returned %d", (int)rc);
        return (int)rc;
    }
    return JNI_OK;
}

JavaVM *mactak_vm(void) { return g_vm; }
JNIEnv *mactak_env(void) { return g_env; }