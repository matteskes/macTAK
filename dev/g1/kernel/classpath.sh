# shellcheck shell=bash
# Sourced: where the takkernel jars are and the order they go on a classpath.
# dev/g1/kernel/build-kernel-jars.sh writes them (engine + its resolved
# runtime classpath) into MACTAK_KERNEL_DIST, default dev/g1/kernel-dist.
# Nothing here reads ~/.m2 (issue #150): the jars that run are the ones
# built from src/, unless MACTAK_KERNEL_DIST names other ones, and then
# the classpath says so on stderr, so a run's log shows which jars ran.

# shellcheck disable=SC2034  # read by the scripts that source this file
MACTAK_KERNEL_VERSION="8.30.5"
MACTAK_KERNEL_DIST_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kernel-dist"
MACTAK_KERNEL_DIST="${MACTAK_KERNEL_DIST:-$MACTAK_KERNEL_DIST_DEFAULT}"

# Kernel jars first, android-port last: the substitute carries the
# ATAK-CIV 5.5.1.8 apk's own com.atakmap.* classes (an Android Log whose
# android.util.Log throws "Stub!"), which must not shadow the kernel's
# desktop ones (dev/spike/g55/NOTES.md trap 6).
mactak_kernel_classpath() { # prints the classpath, or returns 1 if the jars are missing
  local jars="$MACTAK_KERNEL_DIST" cp jar
  compgen -G "$jars/takkernel-engine-*.jar" >/dev/null || return 1
  [[ "$jars" -ef "$MACTAK_KERNEL_DIST_DEFAULT" ]] \
    || echo "[kernel] takkernel jars from MACTAK_KERNEL_DIST=$jars, not the build from src/" >&2
  cp="$(printf '%s:' "$jars"/takkernel-*.jar)"
  for jar in "$jars"/*.jar; do
    case "$(basename "$jar")" in takkernel-*|android-port-*) ;; *) cp+="$jar:" ;; esac
  done
  cp+="$(printf '%s' "$jars"/android-port-*.jar)"
  printf '%s\n' "$cp"
}
