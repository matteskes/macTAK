#!/usr/bin/env python3
"""
Generate android.opengl.GLES20 / GLES30 runtime classes for macOS plus the
JNI C file that forwards them to the real GL ES entry points (ANGLE's
libGLESv2, already linked into libtakenginejni).

Inputs:
  - `javap -s -constants` of android.opengl.GLES20/GLES30 from the android-port
    transplant jar (the Android API surface: constants + method descriptors)
  - src/khronos/OpenGL/api/GLES3/gl3.h prototypes (the C parameter types)

Each Java method is matched to its C prototype by name; Java (array, offset)
pairs and java.nio.Buffers collapse to one C pointer. Where the shapes do not
line up (String-returning queries, glShaderSource, glMapBufferRange, …) the
method is either hand-written in HANDWRITTEN below or emitted as a Java stub
throwing UnsupportedOperationException, so a miss is loud, not silent.

Also emits <stub-out-file>: a no-op libGLESv2 covering every gl3.h entry
point, so the shim links in MACTAK_GLES=stub mode (CI has no ANGLE).

Usage: gen-gles-shim.py <android-port.jar> <gl3.h> <java-out-dir> <c-out-file> <stub-out-file>
"""
import os
import re
import subprocess
import sys
from pathlib import Path

JAR, GL3_H, JAVA_OUT, C_OUT, STUB_OUT = sys.argv[1:6]
# JAVA_HOME (CI: setup-java's JDK 21) else the local JDK 21; any JDK's javap reads these class files.
JAVA_HOME = os.environ.get("JAVA_HOME") or subprocess.run(["/usr/libexec/java_home", "-v", "21"], capture_output=True, text=True).stdout.strip()
JAVAP = JAVA_HOME + "/bin/javap"

# ---------------------------------------------------------------- gl3.h ----
PROTO_RE = re.compile(r"GL_APICALL\s+(.+?)\s*GL_APIENTRY\s+(gl\w+)\s*\((.*?)\);")
c_protos = {}
for ret, name, params in PROTO_RE.findall(Path(GL3_H).read_text()):
    plist = []
    if params.strip() != "void":
        for p in params.split(","):
            p = p.strip()
            # split trailing identifier off the type
            m = re.match(r"(.+?)\s*\**\s*(\w+)$", p)
            typ = p[: p.rfind(m.group(2))].strip()
            plist.append(typ)
    c_protos[name] = (ret.strip(), plist)

# ------------------------------------------------------------- javap -----
def javap(cls):
    out = subprocess.run([JAVAP, "-s", "-constants", "-cp", JAR, cls], capture_output=True, text=True, check=True).stdout
    consts, methods = [], []
    lines = out.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"\s*public static final int (GL_\w+) = (-?\d+);", line)
        if m:
            consts.append((m.group(1), int(m.group(2))))
            continue
        m = re.match(r"\s*public static (?:native )?(\S+) (gl\w+)\((.*)\);", line)
        if m:
            desc = re.match(r"\s*descriptor: (\S+)", lines[i + 1]).group(1)
            jparams = [t.strip() for t in m.group(3).split(",")] if m.group(3).strip() else []
            methods.append((m.group(1), m.group(2), jparams, desc))
    return consts, methods

BUFFER_ELEM = {"java.nio.ByteBuffer": 1, "java.nio.ShortBuffer": 2, "java.nio.IntBuffer": 4,
               "java.nio.FloatBuffer": 4, "java.nio.LongBuffer": 8, "java.nio.Buffer": 0}
JNI_T = {"int": "jint", "float": "jfloat", "boolean": "jboolean", "long": "jlong", "byte": "jbyte",
         "java.lang.String": "jstring", "int[]": "jintArray", "float[]": "jfloatArray",
         "boolean[]": "jbooleanArray", "byte[]": "jbyteArray", "long[]": "jlongArray",
         "java.lang.String[]": "jobjectArray"}
JNI_T.update({b: "jobject" for b in BUFFER_ELEM})
ARR_ELEM = {"int[]": ("Int", "jint"), "float[]": ("Float", "jfloat"), "boolean[]": ("Boolean", "jboolean"),
            "byte[]": ("Byte", "jbyte"), "long[]": ("Long", "jlong")}
C_RET = {"void": "void", "int": "jint", "boolean": "jboolean", "long": "jlong"}
ATTRIB_INDEX_FUNCS = {"glEnableVertexAttribArray", "glDisableVertexAttribArray", "glVertexAttribPointer",
                      "glVertexAttribIPointer", "glVertexAttribDivisor",
                      "glVertexAttrib1f", "glVertexAttrib2f", "glVertexAttrib3f", "glVertexAttrib4f",
                      "glVertexAttrib1fv", "glVertexAttrib2fv", "glVertexAttrib3fv", "glVertexAttrib4fv",
                      "glVertexAttribI4i", "glVertexAttribI4ui", "glVertexAttribI4iv", "glVertexAttribI4uiv"}

# Entry points whose pointer GL keeps after the call returns (client-side
# vertex arrays). Only a direct Buffer has a stable address, so these take
# bufferDirect, not bufferAcquire, and refuse anything else as Android does.
RETAINED_POINTER_FUNCS = {"glVertexAttribPointer", "glVertexAttribIPointer"}

def mangle(desc):
    # JNI overload mangling of the parameter descriptor
    sig = desc[1:desc.index(")")]
    out = []
    for ch in sig:
        if ch == "_": out.append("_1")
        elif ch == ";": out.append("_2")
        elif ch == "[": out.append("_3")
        elif ch == "/": out.append("_")
        elif ch.isalnum(): out.append(ch)
        else: out.append("_0%04x" % ord(ch))
    return "".join(out)

# Methods whose shapes don't match the C prototype 1:1; hand-written C bodies.
# Key: (name, descriptor). Value: C body using the generated arg names a0..aN.
HANDWRITTEN = {
    ("glShaderSource", "(ILjava/lang/String;)V"): """
    const char *src = (*env)->GetStringUTFChars(env, a1, NULL);
    const GLchar *srcs[1] = { src };
    glShaderSource((GLuint)a0, 1, srcs, NULL);
    (*env)->ReleaseStringUTFChars(env, a1, src);""",
    ("glGetShaderInfoLog", "(I)Ljava/lang/String;"): """
    GLint len = 0; glGetShaderiv((GLuint)a0, GL_INFO_LOG_LENGTH, &len);
    char *buf = (char *)calloc((size_t)len + 1, 1);
    if (len > 0) glGetShaderInfoLog((GLuint)a0, len, NULL, buf);
    jstring s = (*env)->NewStringUTF(env, buf); free(buf); return s;""",
    ("glGetProgramInfoLog", "(I)Ljava/lang/String;"): """
    GLint len = 0; glGetProgramiv((GLuint)a0, GL_INFO_LOG_LENGTH, &len);
    char *buf = (char *)calloc((size_t)len + 1, 1);
    if (len > 0) glGetProgramInfoLog((GLuint)a0, len, NULL, buf);
    jstring s = (*env)->NewStringUTF(env, buf); free(buf); return s;""",
    ("glGetString", "(I)Ljava/lang/String;"): """
    const GLubyte *s = glGetString((GLenum)a0);
    return (*env)->NewStringUTF(env, s ? (const char *)s : "");""",
    ("glGetStringi", "(II)Ljava/lang/String;"): """
    const GLubyte *s = glGetStringi((GLenum)a0, (GLuint)a1);
    return (*env)->NewStringUTF(env, s ? (const char *)s : "");""",
    ("glMapBufferRange", "(IIII)Ljava/nio/Buffer;"): """
    void *p = glMapBufferRange((GLenum)a0, (GLintptr)a1, (GLsizeiptr)a2, (GLbitfield)a3);
    return p ? (*env)->NewDirectByteBuffer(env, p, (jlong)a2) : NULL;""",
    ("glDeleteProgram", "(I)V"): """
    forgetProgram((GLuint)a0);   /* GL reuses program ids; drop cached uniform/attrib types */
    glDeleteProgram((GLuint)a0);""",
    ("glGetActiveUniform", "(II[II[II)Ljava/lang/String;"): """
    GLint len = 0; glGetProgramiv((GLuint)a0, GL_ACTIVE_UNIFORM_MAX_LENGTH, &len);
    char *buf = (char *)calloc((size_t)len + 1, 1);
    jint *size = (*env)->GetIntArrayElements(env, a2, NULL);
    jint *type = (*env)->GetIntArrayElements(env, a4, NULL);
    glGetActiveUniform((GLuint)a0, (GLuint)a1, len, NULL, (GLint *)(size + a3), (GLenum *)(type + a5), buf);
    (*env)->ReleaseIntArrayElements(env, a2, size, 0);
    (*env)->ReleaseIntArrayElements(env, a4, type, 0);
    jstring s = (*env)->NewStringUTF(env, buf); free(buf); return s;""",
    ("glGetActiveAttrib", "(II[II[II)Ljava/lang/String;"): """
    GLint len = 0; glGetProgramiv((GLuint)a0, GL_ACTIVE_ATTRIBUTE_MAX_LENGTH, &len);
    char *buf = (char *)calloc((size_t)len + 1, 1);
    jint *size = (*env)->GetIntArrayElements(env, a2, NULL);
    jint *type = (*env)->GetIntArrayElements(env, a4, NULL);
    glGetActiveAttrib((GLuint)a0, (GLuint)a1, len, NULL, (GLint *)(size + a3), (GLenum *)(type + a5), buf);
    (*env)->ReleaseIntArrayElements(env, a2, size, 0);
    (*env)->ReleaseIntArrayElements(env, a4, type, 0);
    jstring s = (*env)->NewStringUTF(env, buf); free(buf); return s;""",
}

def gen_method(cls, ret, name, jparams, desc):
    """Return (java_decl, c_func or None). None c_func => Java stub throwing."""
    jni_name = "Java_android_opengl_%s_%s__%s" % (cls, name, mangle(desc))
    args = ", ".join("%s a%d" % (JNI_T[t], i) for i, t in enumerate(jparams))
    head = "JNIEXPORT %s JNICALL %s(JNIEnv *env, jclass cls%s)" % (C_RET.get(ret, "jobject"), jni_name, (", " + args) if args else "")
    java_sig = "%s %s(%s)" % (ret, name, ", ".join("%s a%d" % (t, i) for i, t in enumerate(jparams)))

    hw = HANDWRITTEN.get((name, desc))
    if hw is not None:
        return "    public static native %s;" % java_sig, "%s\n{%s\n}\n" % (head, hw)

    proto = c_protos.get(name)
    if proto is None or ret not in C_RET:
        return "    public static %s { throw new UnsupportedOperationException(\"macTAK GLES shim: %s %s\"); }" % (java_sig, name, desc), None
    cret, cparams = proto

    # collapse Java params into C args
    cargs, pre, post, i = [], [], [], 0
    while i < len(jparams):
        t = jparams[i]
        if t in ARR_ELEM and i + 1 < len(jparams) and jparams[i + 1] == "int":
            fn, jt = ARR_ELEM[t]
            pre.append("    %s *p%d = a%d ? (*env)->Get%sArrayElements(env, a%d, NULL) : NULL;" % (jt, i, i, fn, i))
            post.append("    if (a%d) (*env)->Release%sArrayElements(env, a%d, p%d, 0);" % (i, fn, i, i))
            cargs.append("(p%d ? p%d + a%d : NULL)" % (i, i, i + 1)); i += 2; continue
        if t in BUFFER_ELEM and name in RETAINED_POINTER_FUNCS:
            pre.append("    void *p%d = bufferDirect(env, a%d, %d);\n    if ((*env)->ExceptionCheck(env)) return;" % (i, i, BUFFER_ELEM[t]))
            cargs.append("p%d" % i); i += 1; continue
        if t in BUFFER_ELEM:
            pre.append("    BufRef b%d; void *p%d = bufferAcquire(env, a%d, %d, &b%d);" % (i, i, i, BUFFER_ELEM[t], i))
            post.append("    bufferRelease(env, &b%d);" % i)
            cargs.append("p%d" % i); i += 1; continue
        if t == "java.lang.String":
            pre.append("    const char *p%d = a%d ? (*env)->GetStringUTFChars(env, a%d, NULL) : NULL;" % (i, i, i))
            post.append("    if (a%d) (*env)->ReleaseStringUTFChars(env, a%d, p%d);" % (i, i, i))
            cargs.append("p%d" % i); i += 1; continue
        if t in ("int", "float", "boolean", "long", "byte"):
            cargs.append(("a%d", i)); i += 1; continue
        return "    public static %s { throw new UnsupportedOperationException(\"macTAK GLES shim: %s %s\"); }" % (java_sig, name, desc), None

    if len(cargs) != len(cparams):
        return "    public static %s { throw new UnsupportedOperationException(\"macTAK GLES shim: %s %s (shape)\"); }" % (java_sig, name, desc), None

    # Java int where C wants a pointer = buffer offset (glDrawElements, glVertexAttribPointer, PBO variants)
    final = []
    for a, ct in zip(cargs, cparams):
        if isinstance(a, tuple):
            idx = a[1]
            if "*" in ct:
                final.append("(%s)(intptr_t)a%d" % (ct, idx))
            else:
                final.append("(%s)a%d" % (ct.replace("const ", ""), idx))
        else:
            # pointer params: strip const so out-params (char*, void*) accept our void*/const char*
            final.append("(%s)(uintptr_t)%s" % (ct, a) if "*" in ct else "(%s)%s" % (ct, a))
    call = "%s(%s)" % (name, ", ".join(final))
    body = "\n".join(pre)
    # Attribute-index entry points: Android drivers quietly ignore index -1
    # (an inactive attribute); ANGLE raises GL_INVALID_VALUE. Match Android.
    if name in ATTRIB_INDEX_FUNCS:
        body = "    if (a0 < 0) { attribMinusOne(env, \"%s\"); return; }\n" % name + body
    # Integer-typed shader attributes must be fed with glVertexAttribIPointer;
    # the engine uses glVertexAttribPointer everywhere (Android tolerates it,
    # Metal rejects the pipeline). Redirect when the bound program says so.
    if name == "glVertexAttribPointer":
        call = ("(attribIsInteger((GLuint)a0) ? glVertexAttribIPointer((GLuint)a0, (GLint)a1, signedTwin((GLenum)a2), (GLsizei)a4, %s)"
                " : %s)") % (final[5], call)
    # glUniform1ui on a sampler/int uniform is GL_INVALID_OPERATION in ES 3.0
    # (Android drivers accept it; the engine does it for texture units).
    if name == "glUniform1ui":
        call = "(uniformIsUnsigned((GLint)a0) ? glUniform1ui((GLint)a0, (GLuint)a1) : glUniform1i((GLint)a0, (GLint)a1))"
    if ret == "void":
        body += "\n    %s;\n" % call + "\n".join(post)
    else:
        body += "\n    %s r = (%s)%s;\n" % (C_RET[ret], C_RET[ret], call) + "\n".join(post) + "\n    return r;"
    return "    public static native %s;" % java_sig, "%s\n{\n%s\n}\n" % (head, body)

C_HEADER = """/* GENERATED by dev/g2/gen-gles-shim.py — do not edit.
 * android.opengl.GLES20/GLES30 for macOS: JNI forwards to the GL ES entry
 * points of the libGLESv2 linked into libtakenginejni (ANGLE). Android's
 * Buffer convention: pointer = direct address + position * element size. */
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <GLES3/gl3.h>

static jclass    cls_Buffer, cls_ByteBuffer, cls_ShortBuffer, cls_IntBuffer, cls_FloatBuffer, cls_LongBuffer;
static jmethodID mid_position, mid_isDirect, mid_hasArray, mid_array, mid_arrayOffset;

static void initBuffer(JNIEnv *env)
{
    if (cls_Buffer) return;
#define GC(var, name) var = (*env)->NewGlobalRef(env, (*env)->FindClass(env, name))
    GC(cls_Buffer, "java/nio/Buffer"); GC(cls_ByteBuffer, "java/nio/ByteBuffer");
    GC(cls_ShortBuffer, "java/nio/ShortBuffer"); GC(cls_IntBuffer, "java/nio/IntBuffer");
    GC(cls_FloatBuffer, "java/nio/FloatBuffer"); GC(cls_LongBuffer, "java/nio/LongBuffer");
#undef GC
    mid_position = (*env)->GetMethodID(env, cls_Buffer, "position", "()I");
    mid_isDirect = (*env)->GetMethodID(env, cls_Buffer, "isDirect", "()Z");
    mid_hasArray = (*env)->GetMethodID(env, cls_Buffer, "hasArray", "()Z");
    mid_array = (*env)->GetMethodID(env, cls_Buffer, "array", "()Ljava/lang/Object;");
    mid_arrayOffset = (*env)->GetMethodID(env, cls_Buffer, "arrayOffset", "()I");
}

static int bufferElemSize(JNIEnv *env, jobject buf)
{
    if ((*env)->IsInstanceOf(env, buf, cls_ByteBuffer)) return 1;
    if ((*env)->IsInstanceOf(env, buf, cls_ShortBuffer)) return 2;
    if ((*env)->IsInstanceOf(env, buf, cls_IntBuffer) || (*env)->IsInstanceOf(env, buf, cls_FloatBuffer)) return 4;
    return 8;
}

/* A Buffer argument: direct => its address; array-backed => pinned backing
 * array (copied back on release, so out-params work). Android semantics:
 * pointer = base + position * element size. */
typedef struct { jarray arr; void *elems; int elem; } BufRef;

static void *bufferAcquire(JNIEnv *env, jobject buf, int elem, BufRef *ref)
{
    ref->arr = NULL; ref->elems = NULL; ref->elem = 0;
    if (!buf) return NULL;
    initBuffer(env);
    if (elem == 0) elem = bufferElemSize(env, buf);
    jint pos = (*env)->CallIntMethod(env, buf, mid_position);
    if ((*env)->CallBooleanMethod(env, buf, mid_isDirect)) {
        char *base = (char *)(*env)->GetDirectBufferAddress(env, buf);
        return base ? base + (size_t)pos * (size_t)elem : NULL;
    }
    if (!(*env)->CallBooleanMethod(env, buf, mid_hasArray)) {
        (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/IllegalArgumentException"),
                         "macTAK GLES shim: Buffer is neither direct nor array-backed");
        return NULL;
    }
    jint off = (*env)->CallIntMethod(env, buf, mid_arrayOffset);
    ref->arr = (jarray)(*env)->CallObjectMethod(env, buf, mid_array);
    ref->elem = elem;
    switch (elem) {
        case 1: ref->elems = (*env)->GetByteArrayElements(env, (jbyteArray)ref->arr, NULL); break;
        case 2: ref->elems = (*env)->GetShortArrayElements(env, (jshortArray)ref->arr, NULL); break;
        case 4: ref->elems = (*env)->IsInstanceOf(env, buf, cls_FloatBuffer)
                    ? (void *)(*env)->GetFloatArrayElements(env, (jfloatArray)ref->arr, NULL)
                    : (void *)(*env)->GetIntArrayElements(env, (jintArray)ref->arr, NULL); break;
        default: ref->elems = (*env)->GetLongArrayElements(env, (jlongArray)ref->arr, NULL); ref->elem = 8; break;
    }
    if (ref->elem == 4 && (*env)->IsInstanceOf(env, buf, cls_FloatBuffer)) ref->elem = -4;  /* float marker */
    return ref->elems ? (char *)ref->elems + (size_t)(off + pos) * (size_t)elem : NULL;
}

/* A Buffer whose pointer GL keeps after the call returns (vertex attribute
 * arrays). Only a direct Buffer has a stable address: bufferAcquire's copy
 * of a backing array is freed by bufferRelease, which would leave GL a
 * dangling pointer at draw time. Android throws IllegalArgumentException
 * for a non-direct Buffer here; so does this. */
static void *bufferDirect(JNIEnv *env, jobject buf, int elem)
{
    if (!buf) return NULL;
    initBuffer(env);
    if (!(*env)->CallBooleanMethod(env, buf, mid_isDirect)) {
        (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/IllegalArgumentException"),
                         "Must use a native order direct Buffer");
        return NULL;
    }
    if (elem == 0) elem = bufferElemSize(env, buf);
    jint pos = (*env)->CallIntMethod(env, buf, mid_position);
    char *base = (char *)(*env)->GetDirectBufferAddress(env, buf);
    return base ? base + (size_t)pos * (size_t)elem : NULL;
}

static void bufferRelease(JNIEnv *env, BufRef *ref)
{
    if (!ref->arr || !ref->elems) return;
    switch (ref->elem) {
        case 1: (*env)->ReleaseByteArrayElements(env, (jbyteArray)ref->arr, (jbyte *)ref->elems, 0); break;
        case 2: (*env)->ReleaseShortArrayElements(env, (jshortArray)ref->arr, (jshort *)ref->elems, 0); break;
        case 4: (*env)->ReleaseIntArrayElements(env, (jintArray)ref->arr, (jint *)ref->elems, 0); break;
        case -4: (*env)->ReleaseFloatArrayElements(env, (jfloatArray)ref->arr, (jfloat *)ref->elems, 0); break;
        default: (*env)->ReleaseLongArrayElements(env, (jlongArray)ref->arr, (jlong *)ref->elems, 0); break;
    }
    (*env)->DeleteLocalRef(env, ref->arr);
    ref->arr = NULL; ref->elems = NULL;
}

/* MACTAK_GL_DEBUG set: name the Java call site that used attribute -1 (once per entry point). */
static void attribMinusOne(JNIEnv *env, const char *fn)
{
    static const char *seen[32]; static int nseen;
    const char *dbg = getenv("MACTAK_GL_DEBUG");
    if (!dbg || !*dbg || !strcmp(dbg, "0")) return;
    for (int i = 0; i < nseen; i++) if (!strcmp(seen[i], fn)) return;
    if (nseen < 32) seen[nseen++] = fn;
    fprintf(stderr, "mactak_gles: %s(-1) ignored (inactive attribute); Java call site:\\n", fn);
    jclass thread = (*env)->FindClass(env, "java/lang/Thread");
    jmethodID dump = thread ? (*env)->GetStaticMethodID(env, thread, "dumpStack", "()V") : NULL;
    if (dump) (*env)->CallStaticVoidMethod(env, thread, dump);
    else (*env)->ExceptionClear(env);   /* debug aid must not leave an exception pending */
}

/* ANGLE's Metal backend refuses unsigned vertex formats for signed `int`
 * attributes (Metal signedness rule; GLES allows it). The engine feeds
 * `in int` attributes with GL_UNSIGNED_BYTE/INT data, so hand Metal the
 * signed twin — correct for values below the sign bit (stipple factors,
 * pattern bitmasks that are already GL_INT). */
static GLenum signedTwin(GLenum type)
{
    switch (type) {
        case GL_UNSIGNED_BYTE: return GL_BYTE;
        case GL_UNSIGNED_SHORT: return GL_SHORT;
        case GL_UNSIGNED_INT: return GL_INT;
        default: return type;
    }
}

/* Per-program type caches for the two redirects below. Keyed on GL program
 * ids, which GL reuses after glDeleteProgram — so that entry point evicts. */
static struct { GLuint prog; GLint loc; int isuint; } uniformCache[256];
static int nUniformCache;
static struct { GLuint prog, idx; int isint; } attribCache[256];
static int nAttribCache;

static void forgetProgram(GLuint prog)
{
    int j = 0;
    for (int i = 0; i < nUniformCache; i++) if (uniformCache[i].prog != prog) uniformCache[j++] = uniformCache[i];
    nUniformCache = j;
    j = 0;
    for (int i = 0; i < nAttribCache; i++) if (attribCache[i].prog != prog) attribCache[j++] = attribCache[i];
    nAttribCache = j;
}

/* Is uniform `location` of the current program a uint/uvec? (cached per program/location) */
static int uniformIsUnsigned(GLint location)
{
    GLint prog = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    if (prog <= 0 || location < 0) return 0;
    for (int i = 0; i < nUniformCache; i++)
        if (uniformCache[i].prog == (GLuint)prog && uniformCache[i].loc == location) return uniformCache[i].isuint;
    int isuint = 0;
    GLint count = 0;
    glGetProgramiv((GLuint)prog, GL_ACTIVE_UNIFORMS, &count);
    for (GLint u = 0; u < count; u++) {
        char name[256]; GLint size = 0; GLenum type = 0;
        glGetActiveUniform((GLuint)prog, (GLuint)u, sizeof name, NULL, &size, &type, name);
        char *br = strchr(name, '[');          /* arrays report "name[0]" */
        if (br) *br = '\\0';
        if (glGetUniformLocation((GLuint)prog, name) != location) continue;
        isuint = (type == GL_UNSIGNED_INT || type == GL_UNSIGNED_INT_VEC2 || type == GL_UNSIGNED_INT_VEC3 || type == GL_UNSIGNED_INT_VEC4);
        break;
    }
    if (nUniformCache < 256) { uniformCache[nUniformCache].prog = (GLuint)prog; uniformCache[nUniformCache].loc = location; uniformCache[nUniformCache].isuint = isuint; nUniformCache++; }
    return isuint;
}

/* Is attribute `index` of the current program integer-typed? (cached per program/index) */
static int attribIsInteger(GLuint index)
{
    GLint prog = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    if (prog <= 0) return 0;
    for (int i = 0; i < nAttribCache; i++)
        if (attribCache[i].prog == (GLuint)prog && attribCache[i].idx == index) return attribCache[i].isint;
    int isint = 0;
    GLint count = 0;
    glGetProgramiv((GLuint)prog, GL_ACTIVE_ATTRIBUTES, &count);
    for (GLint a = 0; a < count; a++) {
        char name[256]; GLint size = 0; GLenum type = 0;
        glGetActiveAttrib((GLuint)prog, (GLuint)a, sizeof name, NULL, &size, &type, name);
        if (glGetAttribLocation((GLuint)prog, name) != (GLint)index) continue;
        isint = (type == GL_INT || type == GL_INT_VEC2 || type == GL_INT_VEC3 || type == GL_INT_VEC4 ||
                 type == GL_UNSIGNED_INT || type == GL_UNSIGNED_INT_VEC2 || type == GL_UNSIGNED_INT_VEC3 || type == GL_UNSIGNED_INT_VEC4);
        break;
    }
    if (nAttribCache < 256) { attribCache[nAttribCache].prog = (GLuint)prog; attribCache[nAttribCache].idx = index; attribCache[nAttribCache].isint = isint; nAttribCache++; }
    const char *dbg = getenv("MACTAK_GL_DEBUG");
    if (dbg && atoi(dbg) >= 2)
        fprintf(stderr, "mactak_gles: program %d attrib %u integer=%d (active=%d)\\n", prog, index, isint, count);
    return isint;
}

"""

java_files = {}
c_parts = [C_HEADER]
for cls, parent in (("GLES20", None), ("GLES30", "GLES20")):
    consts, methods = javap("android.opengl." + cls)
    lines = ["package android.opengl;", "",
             "/** GENERATED by dev/g2/gen-gles-shim.py from the Android API surface; bodies in dev/g2/jni-extra/mactak_gles.c (JNI → ANGLE). */",
             "public class %s%s {" % (cls, (" extends " + parent) if parent else ""),
             "    protected %s() { }" % cls, ""]
    for n, v in consts:
        lines.append("    public static final int %s = %d;" % (n, v))
    lines.append("")
    for ret, name, jparams, desc in methods:
        jdecl, cfunc = gen_method(cls, ret, name, jparams, desc)
        lines.append(jdecl)
        if cfunc:
            c_parts.append(cfunc)
    lines.append("}")
    java_files[cls] = "\n".join(lines) + "\n"

out = Path(JAVA_OUT)
out.mkdir(parents=True, exist_ok=True)
for cls, text in java_files.items():
    (out / (cls + ".java")).write_text(text)
Path(C_OUT).write_text("\n".join(c_parts))

stub = ["/* GENERATED by dev/g2/gen-gles-shim.py from GLES3/gl3.h: no-op libGLESv2 for",
        " * MACTAK_GLES=stub builds. Every entry point the engine or the JNI shim can",
        " * reference resolves here; nothing renders. ANGLE replaces it at runtime. */",
        "#include <stddef.h>", "#include <GLES3/gl3.h>", ""]
for name in sorted(c_protos):
    ret, cparams = c_protos[name]
    params = ", ".join("%s a%d" % (t, i) for i, t in enumerate(cparams)) or "void"
    body = "{ }" if ret == "void" else "{ return (%s)0; }" % ret
    stub.append("%s GL_APIENTRY %s(%s) %s" % (ret, name, params, body))
Path(STUB_OUT).write_text("\n".join(stub) + "\n")

n_native = sum(p.startswith("JNIEXPORT") for p in c_parts)
n_stub = sum(t.count("UnsupportedOperationException") for t in java_files.values())
print("gen-gles-shim: %d native, %d unsupported stubs, %d no-op GLES entry points" % (n_native, n_stub, len(c_protos)))
