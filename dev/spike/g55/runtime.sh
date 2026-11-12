# shellcheck shell=bash
# Sourced by the 5.5 spike scripts: which JDK, and the runtime classpath
# from kernel/build-kernel-jars.sh's build/kernel/jars.

# shellcheck disable=SC2034  # read by the scripts that source this file
G55_KERNEL_VERSION="8.30.5"

g55_jdk_home() { # g55_jdk_home 8|21 — prints that JDK's home, or fails
  # G55_JDK<v>_HOME first (CI: setup-java's path output); not $JAVA_HOME,
  # which CI points at the Zulu 8 the 4.6 jobs use
  local override="G55_JDK$1_HOME" java_version="$1" home
  [[ "$1" == 8 ]] && java_version=1.8
  if [[ -n "${!override:-}" ]]; then
    home="${!override}"
  else
    home="$(/usr/libexec/java_home -v "$java_version" 2>/dev/null)" || return 1
  fi
  # java_home answers a version it cannot match with the default JDK and
  # exit 0, so check what it found
  grep -Eq "^JAVA_VERSION=\"${java_version}[.\"_]" "$home/release" 2>/dev/null || return 1
  printf '%s\n' "$home"
}

# Kernel jars first, android-port last: the substitute carries the 5.5.1.8
# apk's own com.atakmap.* classes (an Android Log whose android.util.Log
# throws "Stub!"), which must not shadow the kernel's desktop ones.
g55_kernel_classpath() { # g55_kernel_classpath JARS_DIR — prints the classpath
  local jars="$1" cp jar
  cp="$(printf '%s:' "$jars"/takkernel-*.jar)"
  for jar in "$jars"/*.jar; do
    case "$(basename "$jar")" in takkernel-*|android-port-*) ;; *) cp+="$jar:" ;; esac
  done
  cp+="$(printf '%s' "$jars"/android-port-*.jar)"
  printf '%s\n' "$cp"
}
