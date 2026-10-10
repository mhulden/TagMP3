# Contributing to tagmp3

Read `AGENTS.md` before changing the project. Work on the earliest incomplete
roadmap substage unless a maintainer asks for a different slice.

Before opening a change:

1. keep metadata and filesystem access behind the package protocols;
2. add deterministic tests for model and I/O behavior;
3. preserve staged-edit and safe-write semantics;
4. run `./scripts/test.sh` on macOS;
5. update documentation and the roadmap when behavior changes.

Do not add copyrighted music, downloaded artwork, credentials, user library
paths, or third-party proprietary assets to fixtures or screenshots.

