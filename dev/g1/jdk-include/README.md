# Pinned JDK headers (build-only)

`jni.h` and `jni_md.h` are OpenJDK 8's JNI headers, pinned here so the
native engine build (`dev/g1/build-native.sh`) compiles against a fixed
JNI ABI no matter which JDK is installed on the build machine.

Every file here carries the Oracle header marking it **GPL-2.0 with the
Classpath Exception 1.1** ("This code is free software; you can
redistribute it and/or modify it under the terms of the GNU General
Public License version 2 only, as published by the Free Software
Foundation. Oracle designates this particular file as subject to the
"Classpath" exception as provided by Oracle in the LICENSE file that
accompanied this code.") — keep the headers intact. The exception's text:
<https://openjdk.org/legal/gplv2+ce.html>; the GPL-2.0 text macTAK
keeps is `licenses/texts/gpl-2.0.txt`.

These are build inputs only: nothing from this directory ships in the
app bundle (inventory row `build:jdk-include`,
[../../../docs/license-audit.md](../../../docs/license-audit.md), F4).
