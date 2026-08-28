# Third-party notices

DubLab's optional local dialogue-removal feature installs the following components only after the user requests it:

- **bandit-infer** — Apache License 2.0, pinned to revision `d45cdec634bf1ee01cdd2acea74a2d100e639c8a`.
- **Bandit v2 multi-domain checkpoint** — CC BY-SA 4.0. The checkpoint is downloaded separately from the official Zenodo record and verified with SHA-256 before use. It is not included in this repository or the application bundle.
- **MLX and its Python dependencies** — installed into DubLab's private Application Support directory for the development implementation.

The development runtime is replaceable. A distribution build should bundle a reviewed, signed runtime or use a native Swift/MLX implementation rather than depending on a package manager installed on the user's Mac.
