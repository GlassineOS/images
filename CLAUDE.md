# CLAUDE.md — GlassineOS/images

System images (see `README.md`); the design is GlassineOS/hub#8. Every change: build the
chain for linux/arm64 and refresh the locks it affects (`scripts/lock.sh`).

- Generic stages stay generic: no device names, no personal choices, no applications
  (people install those live). A package earns its place in `glassine-common` only if
  every GlassineOS system needs it.

- Nothing copied from a device or a vendor's own images in any stage or image (decision
  0016). Firmware published for redistribution (`linux-firmware`) may go in a stage only
  as a locked package with its license; never commit the files.
- Commits carry an `Assisted-by:` or `Co-Authored-By:` trailer. Never add
  `Signed-off-by`. Run `.glassine/org/scripts/safety-scan.sh --staged` before committing.
- Organization guidance for coding agents, including the project knowledge search
  (run `git submodule update --init` if the import below is missing):

@.glassine/org/AGENTS.md
