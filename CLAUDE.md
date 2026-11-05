# CLAUDE.md — GlassineOS/images

System images (see `README.md`). Nothing builds here yet; the design is GlassineOS/hub#8.

- No vendor firmware in any stage or image.
- Commits carry an `Assisted-by:` or `Co-Authored-By:` trailer. Never add
  `Signed-off-by`. Run `.glassine/org/scripts/safety-scan.sh --staged` before committing.
- Organization guidance for coding agents, including the project knowledge search
  (run `git submodule update --init` if the import below is missing):

@.glassine/org/AGENTS.md
