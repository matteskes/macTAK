// JavaBoot.swift — start the in-process JVM (host model A, dev/g2/NOTES.md §M3).
//
// CJavaBoot does the C-shaped part: find and dlopen libjli ($JAVA_HOME, else
// /usr/libexec/java_home -v 21) and call JNI_CreateJavaVM. Call once per
// process, on the main thread: a process gets one JVM, and the JNIEnv it
// returns belongs to the calling thread.

import CJavaBoot
import Darwin

public enum JavaBoot {
    public struct Started {
        /// The libjli that loaded.
        public let libjli: String
        public let jni: JNI
    }

    /// Create the JVM with `-Djava.class.path=classpath` plus `options`.
    public static func start(classpath: String, options: [String]) throws -> Started {
        var err = [CChar](repeating: 0, count: 1024)
        guard let libjli = mactak_find_libjli(&err, err.count) else {
            throw JNIError(String(cString: err))
        }
        let all = ["-Djava.class.path=\(classpath)"] + options
        var cOptions: [UnsafeMutablePointer<CChar>?] = all.map { strdup($0) }
        defer { cOptions.forEach { free($0) } }
        let rc = cOptions.withUnsafeMutableBufferPointer { p in
            mactak_create_jvm(p.baseAddress, Int32(p.count), &err, err.count)
        }
        guard rc == 0 else {
            throw JNIError("creating the JVM failed (\(rc)): \(String(cString: err))")
        }
        guard let env = mactak_env() else { throw JNIError("no JNIEnv after JNI_CreateJavaVM") }
        return Started(libjli: String(cString: libjli), jni: JNI(env: env))
    }
}
