# CLAUDE.md — GlassineOS/images

System images (see `README.md`); the design is GlassineOS/hub#8. Every change: build the
chain for linux/arm64 and refresh the locks it affects (`scripts/lock.sh`).

- Generic stages stay generic: no device names, no personal choices, no applications
  (people install those live). A package earns its place in `glassine-common` only if
  every GlassineOS system needs it.

- No vendor firmware in any stage or image.
- Commits carry an `Assisted-by:` or `Co-Authored-By:` trailer. Never add
  `Signed-off-by`. Run `.glassine/org/scripts/safety-scan.sh --staged` before committing.
- Organization guidance for coding agents, including the project knowledge search
  (run `git submodule update --init` if the import below is missing):

@.glassine/org/AGENTS.md
