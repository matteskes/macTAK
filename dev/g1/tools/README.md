# dev/g1 tooling — waves 5–7 JNI hygiene reference tooling

The audit, patch-generation and verification scripts behind the G1.7 (wave 5)
and G1.8 (wave 6) JNI bridge hygiene sweeps, and the lookup check wave 7
(G1.21, issue #142) runs before it adds init guards. The outcomes live in the
committed patches (`dev/g1/patches/`) and in `dev/g1/NOTES.md`; these
scripts are the reference tooling that produced — and can re-derive — those
outcomes from the repo alone. They are **not wired into CI** and gate
nothing; they are run by hand to reproduce, re-audit or extend the waves.

## What's here

| Script | What it does |
|---|---|
| `wave5/audit_roster.py` | Roster heuristic (JNI `Call*`/`New*Method` sites with no `ExceptionCheck` within 4 lines) over the pristine engine vs the staged+patched verify tree |
| `wave5/residuals.py` | The post-patch residual unguarded sites in the wave-5-touched files — the honest list for `NOTES.md` |
| `wave5/gen_patches.py` | Regenerates the 7 wave-5 patches from the staged authoring trees; replays gdal-drift + the committed patches on a pristine copy and asserts every wave-5 change landed |
| `wave6/class_init_audit.py` | Classifies every class/init function (lookup calls, bail guards, unconditional-`true` tails) plus the `static bool v = fn(env)` caller idiom; reports out-of-build TUs separately |
| `wave6/guard_inits.py` | The sweep's body-editing pass: inserts `if(!x) return <bail>;` guards after unguarded lookups in tree b (authoring; its outcome is baked into the committed patches) |
| `wave6/fix_inline.py` | The sweep's cleanup pass: rewrites hoisted-`fid` blocks so the `New*Ref` statement uses the hoisted id (authoring, as above) |
| `wave6/gen_patches.py` | Regenerates the 11 wave-6 patches from the staged authoring trees; replays the full patch set on a pristine copy and asserts the jni tree equals tree b |
| `wave7/check_lookups.py` | Checks one class init's member lookups (`env.Get*ID(cls, "name", "sig")` or `env->`, split over lines or not, and `SET_METHOD_DEFINITION`) against the kernel jars with `javap`, walking superclasses and interfaces; run before guarding an init with `if(!x) return false;`, which makes one missing lookup disable the whole wrapper |
| `wave6/stage_baseline.py` | Rebuilds both wave-6 staging trees from the repo alone: a/ = pristine + gdal-drift + every committed patch except the wave-6 set (the post-wave-5 baseline), b/ = pristine + gdal-drift + the full set (the post-sweep tree) |

Deliberately not committed (one-offs whose outcomes are already baked into
the committed patches and `NOTES.md`): wave-5 `apply_edits.py` (the one-shot
edit driver; `gen_patches.py` covers its patch-generation step), wave-6
`split_patch.py` (repartitioned hunks into the committed names) and the
`probe_jgltf.py` / `probe_layer.py` screens.

## Prerequisites

- `src/` populated per [CONTRIBUTING.md](../../../CONTRIBUTING.md). Waves 5
  and 6 ran against the 4.6 pin (`deptofdefense/AndroidTacticalAssaultKit-CIV`
  @ `889eee2`); since the re-pin, `src/` is `TAK-Product-Center/atak-civ`
  5.5.1.10 @ `9f6893d` (`dev/spike/g55/NOTES.md`), and the wave-5/6 scripts'
  recorded numbers describe the 4.6 tree. On 5.5, audit the patched tree
  `build-native.sh` leaves in `dev/g1/build/engine`:
  `python3 dev/g1/tools/wave6/class_init_audit.py dev/g1/build/engine/jni`
  (G1.21 records its 5.5 numbers). The scripts read the engine from
  `src/takkernel/engine/src/main/` exactly like `build-native.sh`.
- `python3` plus the macOS builtins `rsync`, `patch`, `diff`.
- Patch *regeneration* additionally needs the wave's staged `a/`+`b/`
  authoring trees under the staging root. Those existed only on the machine
  that ran the wave (`/tmp/g1wave5`, `/tmp/g1wave6` — and `/tmp` does not
  survive a reboot); `stage_baseline.py` rebuilds them from the repo, so
  the authoring state is disposable now.

## Paths

Defaults assume this directory lives inside the repo it audits. Every
script resolves its repo from its own location (`<repo>/dev/g1/tools/…`),
overridable for checkouts elsewhere:

- `G1_REPO` — the checkout whose `dev/g1/patches/` and `src/` are used
  (default: the repo containing this file).
- `G1_STAGING` — the staging root (defaults: `/tmp/g1wave5`, `/tmp/g1wave6`).
- `G1_AUDIT_ROOT` — `class_init_audit.py`'s audit tree (default:
  `$G1_STAGING/a/tmp/takeng-src/jni`); a positional argument works too.

`gen_patches.py` runs in two modes: with staged `a/`+`b/` trees it also
*regenerates* the wave's patches (authoring mode); without them it prints a
skip line and only runs the verification half, which stages
pristine + gdal-drift + the committed patches itself. Staged verify trees
are reused via their `.staged`/`.staged6` markers — delete the `verify/`
directory to force a re-stage. `stage_baseline.py` likewise no-ops when its
`.stageda`/`.stagedb` markers exist (`--force` rebuilds).

## Quickstart (fresh clone)

```bash
# both wave-6 staging trees, rebuilt from the repo alone:
python3 dev/g1/tools/wave6/stage_baseline.py --rebuild-b

# the wave-6 audit, pre- and post-sweep:
python3 dev/g1/tools/wave6/class_init_audit.py
python3 dev/g1/tools/wave6/class_init_audit.py /tmp/g1wave6/b/tmp/takeng-src/jni

# the wave-5 roster audit and residual list:
python3 dev/g1/tools/wave5/audit_roster.py
python3 dev/g1/tools/wave5/residuals.py

# replay verification (also regenerates patches when authoring trees exist):
python3 dev/g1/tools/wave5/gen_patches.py
python3 dev/g1/tools/wave6/gen_patches.py
```

## Expected output

The numbers below were re-derived with these scripts against a fresh clone;
a run that stops matching means the tree or patches drifted.

`wave5/audit_roster.py` (pristine vs staged+patched verify tree):

```text
pristine roster: 34 files with >=1 unguarded JNI call (151 sites)
patched roster:  27 files (102 sites)
```

102 is the wave-5-close number. Wave-6's F15 `ExceptionClear` hygiene in
`common.cpp` drained two more sites, so on post-wave-6 `main` the same
run prints `patched roster:  27 files (100 sites)`; the committed
per-file enumeration lives in `dev/g1/NOTES.md` §G1.7.

The wave-5-touched files drain to zero (e.g. `jglobe.cpp: 9 → 0`,
`jglmapview.cpp: 2 → 0`); what remains is the defensive roster, and
`wave5/residuals.py` enumerates it for `NOTES.md`.

`wave6/class_init_audit.py`, LIVE-on-desktop bucket — tree a (pre-sweep)
vs tree b (post-sweep):

```text
a/: fully masked 42 · partial 4 · fully guarded 1 · no-lookups 16
    unread-result callers: 25
b/: fully masked 2 · partial 11 · fully guarded 35 · no-lookups 18
    unread-result callers: 23
```

`wave6/gen_patches.py` ends with
`VERIFY OK: replay of gdal + committed + wave-6 patches reproduces tree b
exactly`; `wave5/gen_patches.py` ends with
`ALL WAVE-5 PATCHES VERIFIED AGAINST PRISTINE TREE` — but that verdict
line needs wave-5's authoring trees `a/`/`b/`, which only exist where
the wave ran. Wave-6 has `stage_baseline.py` to rebuild its pair from
the repo alone; wave-5 has no equivalent, and without `a/` the
assertion half stops at the first `added()` diff (its `pristine()` side
reads tree `a/`). The verify staging, `audit_roster.py` and
`residuals.py` all work from the repo alone. Known wave-7 tooling fix:
give `pristine()` a pristine-engine fallback.

## Provenance — how this committed copy was validated

- Script bodies are byte-identical to the wave-time originals (kept in
  `/tmp/g1wave5|6` at commit time), modulo the parameterized path header.
- With default env, the three readers reproduce the wave-time outputs
  byte-for-byte, including the recorded audit tails
  (`unread-result callers: 25` pre, `23` post).
- On a fresh clone of `main` (wave-6 patch set merged) with `src/`
  populated per CONTRIBUTING.md, `stage_baseline.py --rebuild-b` rebuilds
  a/ and b/ **byte-identical** to the wave's recorded staging trees
  (`diff -rq` clean, all 32 patch applications).
- Regenerating every wave-5 and wave-6 patch from the wave's authoring
  trees onto that clone leaves `git status` clean — the committed patches
  are byte-identical to what the pipeline produces.
- The audit against the rebuilt (not the wave-time) trees prints exactly
  the expected output above.

## Wave 7: check an init's lookups before guarding it

```bash
CP="$(ls dev/g1/kernel-dist/*.jar | paste -sd: -)"
python3 dev/g1/tools/wave7/check_lookups.py "$CP" \
  dev/g1/build/engine/jni/interop/feature/ManagedFeatureDataStore2.cpp FeatureDataStore2_init
```

Exit 0 when every parsed lookup resolves in the 5.5 jars. The `env.` and
`env->` forms with literal strings are parsed, at any indentation and
split over lines; the summary line says how many of the init's lookups
that covers (its count includes the `findClass` calls). The
`SET_METHOD_DEFINITION(cls, name, "sig")` macro some inits define is read
too. Batch 2 found
`ManagedDatabaseProvider`'s missing `DatabaseInformation` constructor
this way (`dev/g1/NOTES.md` §G1.22).
