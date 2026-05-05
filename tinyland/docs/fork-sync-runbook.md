# Fork-Sync Runbook — Tinyland's `caldera` Fork

**Goal:** keep this fork merge-friendly with `mitre/caldera` indefinitely while
carrying Tinyland-specific deployment tooling, the patched SAML plugin
submodule, and a reproducible Nix dev environment.

**Cadence:** weekly tracking-branch update; merge into `master` gated by CI.

---

## Layout invariants

These are the rules merges depend on. Break them and you'll fight upstream
forever.

### Files we own (disjoint from upstream paths)

- `tinyland/` — everything Tinyland-specific (docs, deploy artifacts, scripts).
- `flake.nix` + `flake.lock` — Nix devShell + container build.
- `.envrc` — direnv hook for the flake.
- `.github/workflows/build-tinyland.yml` (and any other `*-tinyland.yml`).

Upstream does not maintain any of these paths, so they never collide on merge.

### Files we mutate (minimal, additive)

- `Dockerfile` — **only** the `apt-get install` line in the runtime stage,
  appending xmlsec native libs (`libxml2-dev libxslt1-dev libxmlsec1-dev
  libxmlsec1-openssl pkg-config xmlsec1`) so the SAML plugin's pinned
  `xmlsec==1.3.9` wheel can build at image-bake time.

  Any other Dockerfile change goes through the flake's `packages.container`
  target instead — that path is ours and doesn't risk merge conflicts.

- `.gitmodules` — adds the `plugins/saml` submodule pointing at our fork
  `tinyland-inc/caldera-saml#v5-compat`. Upstream does not ship a `saml`
  submodule, so the addition is purely additive.

### Files we never touch

- Upstream Python code (`app/`, `server.py`, `conf/`).
- Upstream plugin submodules (`plugins/{access,atomic,builder,...}`).
- Upstream `.github/workflows/{quality,security,publish_docker_image,
  greetings,stale}.yml`.
- Upstream `requirements.txt` / `requirements-dev.txt`.
- Upstream `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`.

If you find yourself needing to edit these, **stop** and reach for an alternate
mechanism (a Tinyland helper script, a tofu-side patch, an init container) —
or open an upstream PR.

## Branches

- `mitre-master` — clean tracking branch following `upstream/master`. Never
  push to this branch directly; only `git fetch upstream` + fast-forward.
- `master` — our fork's main branch. Contains all Tinyland additions plus
  every clean merge of `mitre-master`. **Always merge, never rebase.**
- `tinyland/<topic>` — feature branches for our changes. Squash-merge into
  `master` via PR.

## Remotes

```
git remote add upstream https://github.com/mitre/caldera.git
git remote add origin   https://github.com/Jesssullivan/caldera.git   # this fork
```

(Adjust `origin` if the fork moves to `tinyland-inc/caldera`.)

## Weekly sync recipe

```bash
# 1. Refresh the upstream tracking branch.
git fetch upstream
git checkout mitre-master
git merge --ff-only upstream/master

# 2. Dry-run the merge into master to spot friction early.
git checkout master
git merge --no-commit --no-ff mitre-master
# Review the diff. If the only changes are in our merge-conflict zones
# (Dockerfile apt line, .gitmodules), abort and resolve manually. Otherwise:
git commit -m "merge: upstream mitre/caldera $(git -C ../caldera rev-parse --short upstream/master)"

# 3. Push and let CI gate.
git push origin master
```

## Conflict resolution rules

| Conflict file | Resolution |
|---|---|
| `Dockerfile` apt line | Take both — our xmlsec deps + whatever upstream added. |
| `.gitmodules` | Take both — our `plugins/saml` entry + upstream's plugin set. |
| Anything in `tinyland/` | Take ours — upstream never edits this. |
| Anything else | **Stop.** Investigate why upstream is touching a path we thought was ours, or why we drifted into upstream territory. |

## Verifying merge health

Before pushing a merge:

```bash
# Flake still evaluates.
nix flake check

# Dev shell still instantiates.
nix develop --command true

# Submodules still resolve.
git submodule status

# Linear regression: SAML plugin patch still applies.
cd plugins/saml || git submodule update --init plugins/saml
nix-shell -p 'python312.withPackages(ps: with ps; [ pytest pytest-asyncio aiohttp ])' \
  --run "python -m pytest plugins/saml/tests/test_v5_compat_unit.py -v"
```

## Upstream contribution path

Where our patches are upstreamable, prefer that over indefinite carry:

- The 3-line `mitre/saml#9` fix — we should open a real PR upstream once the
  v5-compat branch has been live a few weeks. Track in Linear TIN-957.
- The xmlsec Dockerfile addition — only if upstream decides to support SAML
  in the official image. Probably not worth pushing.

## Why not rebase

`master` is published. Our deploys reference specific commit SHAs in
`tofu/stacks/caldera/`. Rebasing would invalidate those references and force
re-bumps across blahaj. Merging keeps history honest and SHAs stable.

Same reason `mitre-master` is fast-forward-only — if upstream ever
force-pushes (they don't, but defensively), we'd see it as a new diverging
branch on the next fetch and could investigate before clobbering anything.
