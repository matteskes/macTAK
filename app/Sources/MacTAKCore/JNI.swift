// JNI.swift — Swift over the JNI function table, for the AppKit main thread.
//
// A JNIEnv is bound to the thread that got it. The in-process JVM is created
// on the main thread (JavaBoot), and every call through this class must be
// made there too; the engine's own threads never come back through Swift.

import CJavaBoot

public struct JNIError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public final class JNI {
    /// The JNIEnv*: the pointer every JNI function takes first. Its target is
    /// the function table (C: (*env)->FindClass(env, ...)).
    public let env: UnsafeMutablePointer<JNIEnv?>
    /// The function table, two dereferences from env.
    public let f: JNINativeInterface_

    init(env: UnsafeMutablePointer<JNIEnv?>) {
        self.env = env
        self.f = env.pointee!.pointee
    }

    /// True (after describing and clearing it) when a Java exception is pending.
    public func exceptionPending() -> Bool {
        guard f.ExceptionCheck!(env) != 0 else { return false }
        f.ExceptionDescribe!(env)
        f.ExceptionClear!(env)
        return true
    }

    /// Throws when a Java exception is pending after `during`.
    public func check(_ during: @autoclosure () -> String) throws {
        if exceptionPending() { throw JNIError("JNI exception while \(during())") }
    }

    public func findClass(_ name: String) throws -> jclass {
        let cls = name.withCString { f.FindClass!(env, $0) }
        try check("finding class \(name)")
        guard let cls else { throw JNIError("no class \(name)") }
        return cls
    }

    public func staticMethod(_ cls: jclass, _ name: String, _ sig: String) throws -> jmethodID {
        let mid = name.withCString { n in sig.withCString { s in f.GetStaticMethodID!(env, cls, n, s) } }
        try check("resolving \(name)\(sig)")
        guard let mid else { throw JNIError("no static method \(name)\(sig)") }
        return mid
    }

    public func method(_ cls: jclass, _ name: String, _ sig: String) throws -> jmethodID {
        let mid = name.withCString { n in sig.withCString { s in f.GetMethodID!(env, cls, n, s) } }
        try check("resolving \(name)\(sig)")
        guard let mid else { throw JNIError("no method \(name)\(sig)") }
        return mid
    }

    public func field(_ cls: jclass, _ name: String, _ sig: String) throws -> jfieldID {
        let fid = name.withCString { n in sig.withCString { s in f.GetFieldID!(env, cls, n, s) } }
        try check("resolving field \(name) \(sig)")
        guard let fid else { throw JNIError("no field \(name) \(sig)") }
        return fid
    }

    public func newString(_ s: String) throws -> jstring {
        let js = s.withCString { f.NewStringUTF!(env, $0) }
        try check("creating a string")
        guard let js else { throw JNIError("NewStringUTF returned null") }
        return js
    }

    public func newStringArray(_ items: [String]) throws -> jobjectArray {
        let cls = try findClass("java/lang/String")
        let arr = f.NewObjectArray!(env, jint(items.count), cls, nil)
        try check("creating a String[\(items.count)]")
        guard let arr else { throw JNIError("NewObjectArray returned null") }
        for (n, s) in items.enumerated() {
            f.SetObjectArrayElement!(env, arr, jint(n), try newString(s))
            try check("filling a String[]")
        }
        return arr
    }

    public func newObject(_ cls: jclass, _ ctor: jmethodID) throws -> jobject {
        let obj = f.NewObjectA!(env, cls, ctor, nil)
        try check("constructing an object")
        guard let obj else { throw JNIError("NewObject returned null") }
        return obj
    }

    public func callStaticInt(_ cls: jclass, _ mid: jmethodID, _ args: [jvalue] = []) throws -> jint {
        var a = args
        let v = a.withUnsafeMutableBufferPointer { f.CallStaticIntMethodA!(env, cls, mid, $0.baseAddress) }
        try check("calling a static int method")
        return v
    }

    public func callStaticVoid(_ cls: jclass, _ mid: jmethodID, _ args: [jvalue] = []) throws {
        var a = args
        a.withUnsafeMutableBufferPointer { _ = f.CallStaticVoidMethodA!(env, cls, mid, $0.baseAddress) }
        try check("calling a static method")
    }

    // ---- fields of a plain Java data object (MapConfig) ---------------------

    public func set(_ obj: jobject, _ cls: jclass, _ name: String, string value: String?) throws {
        let fid = try field(cls, name, "Ljava/lang/String;")
        f.SetObjectField!(env, obj, fid, try value.map { try newString($0) })
    }

    public func set(_ obj: jobject, _ cls: jclass, _ name: String, strings value: [String]) throws {
        let fid = try field(cls, name, "[Ljava/lang/String;")
        f.SetObjectField!(env, obj, fid, try newStringArray(value))
    }

    public func set(_ obj: jobject, _ cls: jclass, _ name: String, double value: Double) throws {
        f.SetDoubleField!(env, obj, try field(cls, name, "D"), jdouble(value))
    }

    public func set(_ obj: jobject, _ cls: jclass, _ name: String, int value: Int) throws {
        f.SetIntField!(env, obj, try field(cls, name, "I"), jint(value))
    }

    public func set(_ obj: jobject, _ cls: jclass, _ name: String, long value: Int64) throws {
        f.SetLongField!(env, obj, try field(cls, name, "J"), jlong(value))
    }

    public func set(_ obj: jobject, _ cls: jclass, _ name: String, bool value: Bool) throws {
        f.SetBooleanField!(env, obj, try field(cls, name, "Z"), jboolean(value ? JNI_TRUE : JNI_FALSE))
    }
}
