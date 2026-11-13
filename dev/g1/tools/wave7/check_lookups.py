#!/usr/bin/env python3
"""Check a JNI class init's lookups against the kernel jars (wave 7, issue 142).

Wave 7 guards each lookup in an init with `if(!x) return false;`, so an
init that loses one lookup now disables the whole wrapper. Before adding
those guards, this script confirms every member lookup in the init
resolves on a healthy JVM: each `env.Get{Method,StaticMethod,Field,
StaticField}ID(cls, "name", "sig")` is looked up with javap in the class
the init found for `cls`, walking superclasses and interfaces (JNI
resolves inherited members, e.g. FeatureDataStore2.dispose comes from
gov.tak.api.util.Disposable).

Only the `env.` form with a literal name and signature is parsed; the
report says how many of the init's lookups that covers.

usage: check_lookups.py CLASSPATH SOURCE.cpp INIT_FUNCTION [JAVAP]
  CLASSPATH  the kernel jars, e.g. $(ls dev/g1/kernel-dist/*.jar | paste -sd: -)
  JAVAP      default: javap from `/usr/libexec/java_home -v 21`
exit: 0 when every parsed lookup resolves, 1 otherwise
"""
import re
import subprocess
import sys


def javap_default():
    home = subprocess.run(["/usr/libexec/java_home", "-v", "21"],
                          capture_output=True, text=True, check=True).stdout.strip()
    return home + "/bin/javap"


def init_body(source, init):
    start = re.search(r"^    bool %s\(JNIEnv [&*]env\) NOTHROWS\n    \{\n" % re.escape(init),
                      source, re.M)
    if not start:
        sys.exit("no definition of %s" % init)
    return source[start.start():source.index("\n    }\n", start.start())]


class Members:
    """(name, descriptor) pairs a class declares or inherits, from javap."""

    def __init__(self, classpath, javap):
        self.classpath, self.javap, self.cache = classpath, javap, {}

    def _javap(self, cls):
        return subprocess.run([self.javap, "-s", "-p", "-cp", self.classpath, cls],
                              capture_output=True, text=True).stdout

    def of(self, cls):
        cls = cls.replace("/", ".")
        if cls in self.cache:
            return self.cache[cls]
        found, todo, seen = set(), [cls], set()
        while todo:
            c = todo.pop()
            if c in seen or c == "java.lang.Object":
                continue
            seen.add(c)
            out = self._javap(c)
            header = out.split("{")[0].replace("\n", " ")
            for keyword in ("extends", "implements"):
                m = re.search(keyword + r" (.+?)(?: implements | extends |\s*$)", header)
                if m:
                    todo += [x.split("<")[0].strip() for x in m.group(1).split(",") if x.strip()]
            simple = c.split(".")[-1].split("$")[-1]
            name = None
            for line in out.splitlines():
                t = line.strip()
                if t.startswith("descriptor:"):
                    if name:
                        found.add((name, t.split(None, 1)[1]))
                    continue
                if t.endswith(";"):
                    m = re.search(r"([\w$.<>]+)\(", t)
                    if m:
                        n = m.group(1).split(".")[-1].split("$")[-1]
                        name = "<init>" if n == simple else m.group(1).split(".")[-1]
                    else:
                        name = t[:-1].split()[-1]
        self.cache[cls] = found
        return found


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    classpath, source_path, init = sys.argv[1:4]
    javap = sys.argv[4] if len(sys.argv) > 4 else javap_default()
    body = init_body(open(source_path).read(), init)
    classes = dict(re.findall(r'([\w.]+?)(?:\.id)? = ATAKMapEngineJNI_findClass\([^,]+, "([^"]+)"\)', body))
    members = Members(classpath, javap)
    total = len(re.findall(r"= (?:env[.]|env->)?(?:GetMethodID|GetStaticMethodID|GetFieldID|"
                           r"GetStaticFieldID)\(|= ATAKMapEngineJNI_findClass\(", body))
    checked, missing = 0, []
    for m in re.finditer(r'= env\.(?:GetMethodID|GetStaticMethodID|GetFieldID|GetStaticFieldID)'
                         r'\(([\w.]+?)(?:\.id)?, "([^"]+)", "([^"]+)"\)', body):
        var, name, sig = m.groups()
        checked += 1
        cls = classes.get(var)
        if not cls:
            missing.append("no findClass for %s (%s %s)" % (var, name, sig))
        elif (name, sig) not in members.of(cls):
            missing.append("MISSING %s.%s %s" % (cls, name, sig))
    print("%s: %d lookups; %d member lookups checked in %d classes; %d not found"
          % (init, total, checked, len(classes), len(missing)))
    for line in missing:
        print("  " + line)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
