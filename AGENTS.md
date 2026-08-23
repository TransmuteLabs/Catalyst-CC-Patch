# Rules for agents

The canonical rule compendium for every library of the family lives at the
Nexus folder root, `AGENTS.md`. The pointer chain starts one level up from
this repository (`../AGENTS.md`) and resolves to that canon. Read the canon,
not this file: this is only a pointer, because vendor CLIs do not climb above
their own git root.

If the canon is unreachable (an isolated checkout), the minimum that always
applies:

- **Code comments — only constraints**: a boundary, an invariant, a
  "why not otherwise", a reference to the canonical home of the rule.
  Narrative (edit history, a retelling of the diff, "how it was and why it
  changed") is not written into code — its place is in the commit message
  and in the `NOTES.md` next to the code.
- **No git commits without an explicit assignment**; write only to the files
  the assignment names, staged by explicit pathspec.
- **A gate is confirmed by an honest exit-code form**: `set -o pipefail`, or
  a redirect to a file with `echo "EXIT=$?"` as the next command. The form
  `… | tail -N; echo $?` returns the exit code of the pipe tail — a failed
  run looks green.
- **The measured artifact is the shipped image, never the reconstruction.**
  A reconstructed source tree locates a mechanism; it never settles how that
  mechanism behaves. Read the behaviour out of the image before changing a
  patch that depends on it.
- **A pattern check is not a smoke test.** This repository's pipeline
  verifies patches after applying them, so a failing check means a failing
  CHECK, not an unpatched image — never swap the live binary before the
  whole set is green.

The pipeline, the patch inventory and the architecture of the judge and the
fleet watcher are in this repository's `README.md` and `docs/`.
