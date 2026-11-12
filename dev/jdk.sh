# shellcheck shell=bash
# Sourced, not run. Finds the two JDKs macTAK uses until the 5.5 re-pin:
#
#   21  the runtime: every JVM macTAK starts (canaries, atak-headless and
#       its tests, the render harness, jni-tests, the Swift shell) and the
#       javac that compiles macTAK's own Java
#   8   4.6 build tools only: upstream's Gradle 6.9.1 (runs on JDK <= 16)
#       and javah (gone since JDK 10), which 4.6 commo's JNI Makefile and
#       gen-jni-headers.sh call. The re-pin removes it.
#
# mactak_jdk_home 21|8 prints that JDK's home, or returns 1. Order:
#   MACTAK_JDK<v>_HOME, then $JAVA_HOME if it is that version, then
#   setup-java's JAVA_HOME_<v>_AARCH64 (CI), then /usr/libexec/java_home.
# Every candidate is checked against the JAVA_VERSION in its release
# file: java_home answers a version it cannot match with the default JDK
# and exit 0 (dev/spike/g55/NOTES.md trap 5).

mactak_jdk_is() { # mactak_jdk_is HOME 21|8 — true when HOME is that JDK
  local want="$2"
  [[ "$want" == 8 ]] && want=1.8
  [[ -n "$1" ]] && grep -Eq "^JAVA_VERSION=\"${want}[.\"_]" "$1/release" 2>/dev/null
}

mactak_jdk_home() { # mactak_jdk_home 21|8
  local v="$1" override="MACTAK_JDK$1_HOME" setup="JAVA_HOME_$1_AARCH64" home
  for home in "${!override:-}" "${JAVA_HOME:-}" "${!setup:-}"; do
    if mactak_jdk_is "$home" "$v"; then
      printf '%s\n' "$home"
      return 0
    fi
  done
  home="$(/usr/libexec/java_home -v "$([[ "$v" == 8 ]] && echo 1.8 || echo "$v")" 2>/dev/null)" || return 1
  mactak_jdk_is "$home" "$v" || return 1
  printf '%s\n' "$home"
}
