# shellcheck shell=bash
# Sourced, not run. Finds the JDK macTAK uses: JDK 21, for every JVM macTAK
# starts (canaries, atak-headless and its tests, the render harness,
# jni-tests, the Swift shell), the javac for macTAK's own Java and the
# takkernel Gradle build (8.13). JDK 8 left with the 5.5 re-pin: 4.6's
# Gradle 6.9.1 and javah were its last users.
#
# mactak_jdk_home 21 prints that JDK's home, or returns 1. Order:
#   MACTAK_JDK21_HOME, then $JAVA_HOME if it is that version, then
#   setup-java's JAVA_HOME_21_AARCH64 (CI), then /usr/libexec/java_home.
# Every candidate is checked against the JAVA_VERSION in its release
# file: java_home answers a version it cannot match with the default JDK
# and exit 0 (dev/spike/g55/NOTES.md trap 5).

mactak_jdk_is() { # mactak_jdk_is HOME VERSION — true when HOME is that JDK
  [[ -n "$1" ]] && grep -Eq "^JAVA_VERSION=\"$2[.\"_]" "$1/release" 2>/dev/null
}

mactak_jdk_home() { # mactak_jdk_home VERSION (21)
  local v="$1" override="MACTAK_JDK$1_HOME" setup="JAVA_HOME_$1_AARCH64" home
  for home in "${!override:-}" "${JAVA_HOME:-}" "${!setup:-}"; do
    if mactak_jdk_is "$home" "$v"; then
      printf '%s\n' "$home"
      return 0
    fi
  done
  home="$(/usr/libexec/java_home -v "$v" 2>/dev/null)" || return 1
  mactak_jdk_is "$home" "$v" || return 1
  printf '%s\n' "$home"
}
