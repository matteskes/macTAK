---
name: clean-code-smells
description: Clean Code smell checklist for macTAK — rigidity, fragility, immobility, needless complexity, needless repetition, opacity — with where each shows up in this repo and what to do about it. Use first when reviewing, auditing or planning a refactor of macTAK-owned code, then follow up with the topic clean-code skills.
---

# Clean Code: smells (macTAK)

Walk this list during a review or audit. For each hit: name it, point to
the file and line, and propose the smallest fix. A fix to code outside
the PR's purpose becomes its own focused PR.

| Smell | Symptom | macTAK example / where to look |
|---|---|---|
| **Rigidity** | A small change cascades into many files | A tunable buried in several scripts instead of read once at the top |
| **Fragility** | A change breaks something unrelated | Context drift in engine patches: applying at `--fuzz=0` makes this fail loudly instead of landing "close enough" |
| **Immobility** | Code can't be reused elsewhere without dragging its context | Logic stuck in `HeadlessCLI.main` that a test can't reach; the cure is extracting it (as `CotXml` and `ConnectOptions` were) |
| **Needless complexity** | Machinery for needs that don't exist | Options, env vars or abstractions with no current caller |
| **Needless repetition** | The same logic copied | The kernel classpath was once built by a `jar()` helper copied into five scripts; the 5.5 re-pin factored it into one sourced file, `dev/g1/kernel/classpath.sh`. Source a shared file like that instead of adding a copy |
| **Opacity** | Code is hard to understand | Unnamed literals (`HeadlessCLI`'s exit codes `2`/`3`/`4` against `LayerCLI`'s named `EXIT_*`), unexplained engine quirks with no patch-site comment |

## Review procedure

1. Run the smell table over the diff (and, for an audit, the files it
   touches).
2. For each hit, apply the matching topic skill (`clean-code-naming`,
   `clean-code-functions`, etc.).
3. Decide in-PR vs follow-up: in-PR only if it is within the lines
   being changed; otherwise note it and propose a separate PR.
4. Never "clean" `src/`, generated headers or the GLES shim output by
   hand; never restyle upstream lines inside an engine patch.
5. Report what you found in the PR, or in NOTES if it is a trap, with
   file:line references.
