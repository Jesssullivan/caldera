# Caldera On-Prem Lab Plan — SAML-First Deployment

**Status:** Planning · **Owner:** Jess · **Started:** 2026-05-04
**Linear initiative:** Caldera On-Prem Lab (caldera.tinyland.dev)
**Target host:** `caldera.tinyland.dev` (Tailnet-private, real LE cert)

---

## 1. Goal

Stand up MITRE Caldera as a long-lived public fork of `mitre/caldera` on blahaj
infrastructure, authenticated via our own Shibboleth IdP 5.2, with everything
managed through OpenTofu + GloriousFlywheel CI. Primary motivation: model
production-shape SAML/IdP security flows in a controllable adversary-emulation
sandbox.

## 2. Constraints (from research)

### Caldera runtime
- **Single-replica only** — in-process state, writes to `data/` + `conf/local.yml`. RWO PVC, `Recreate` strategy.
- **`data/` skeleton must pre-exist** on the PVC — init container required on first mount.
- **`builder` plugin doesn't work in containers.** Agent updates require image rebuild, not runtime.
- **CVE-2025-27364** (unauth RCE on `/file/download`) fixed in v5.1.0. Image floor `>=5.1.0`, NetworkPolicy denies non-Tailnet traffic.

### SAML plugin (`mitre/saml`)
- **Known broken on Caldera v5** — [issue #9](https://github.com/mitre/saml/issues/9). PR #11 (unreviewed) appears to fix.
- Pinned to `xmlsec==1.3.9`, `python3-saml==1.10.1`. Needs `libxmlsec1-dev libxml2-dev pkg-config` natively.
- python3-saml's `settings.json` takes a single IdP triple — no `<EntityDescriptor>` consumption. We need a metadata fetch-and-cache helper.
- Attribute matching is by SAML `Name` URI, not `FriendlyName`. Common gotcha.
- No SLO. No multi-replica session sharing — sticky sessions or pin to one replica.

### Shibboleth IdP target
- IdP 4 EOL Sept 2024 — skip. Target **IdP 5.2.x** on Java 17/21.
- Defaults: signed assertions, often encrypted assertions, SHA-256, transient NameID.
- SP `security` block must match: `wantAssertionsSigned: true`, `wantAssertionsEncrypted: true`, `requestedAuthnContext: false`, NameID format `unspecified`.

### blahaj infra (already live)
- 3-node RKE2: honey (CP), bumble (storage/OpenEBS ZFS), sting (compute).
- **Tailscale operator** annotation-based: `tailscale.com/expose=true`, `tailscale.com/hostname`, `tailscale.com/proxy-class=honey-sting-tailnet`. HTTP-only — TLS is the SP's problem.
- **cert-manager + Let's Encrypt prod** via DreamHost DNS-01 webhook is live for `*.tinyland.dev`.
- **NGINX Ingress** controller (no Gateway API).
- **OpenTofu stacks** in `blahaj/tofu/stacks/<app>/`. Apply via reusable workflow `_tofu-agent-shadow.yml` on `tinyland-nix` runner with GitHub Environment approval.
- **SOPS + age** for secrets. **GHCR** for images, `imagePullSecrets`.
- New-app pattern reference: `blahaj/tofu/stacks/massageithaca/`.

### GloriousFlywheel CI (already live)
- ARC self-hosted runners on K8s. Labels: `tinyland-nix`, `tinyland-docker`, `tinyland-dind`, `-heavy`/`-kvm`/`-gpu`.
- **Attic Nix cache** at `https://nix-cache.tinyland.dev`. **Bazel remote cache** auto-injected via `BAZEL_REMOTE_CACHE`.
- Composite actions: `setup-flywheel`, `nix-job`, `docker-job`.
- Container builds via `nix2container` (no Docker daemon), cosign-signed.
- Reference: `GloriousFlywheel/flake.nix` `devShells.default` for the devShell pattern.

## 3. Repo layout (this fork)

All custom code lives under disjoint paths so upstream merges stay clean.

```
caldera/
├── plugins/saml/                  # submodule → tinyland-inc/caldera-saml (our fork)
├── plugins/{modbus,dnp3,bacnet,profinet,iec61850,gems}/  # submodules from mitre/* (Phase 5)
├── tinyland/
│   ├── docs/
│   │   ├── plan-onprem-saml.md    # this file
│   │   ├── fork-sync-runbook.md
│   │   └── saml-troubleshooting.md
│   ├── deploy/
│   │   ├── helm/caldera/          # our Helm chart
│   │   ├── helm/simplesamlphp/    # IdP-001
│   │   ├── helm/shibboleth-idp/   # IdP-002 (Phase 4)
│   │   └── overlays/              # SOPS-encrypted values per env
│   └── scripts/
│       └── fetch-idp-metadata.sh  # SP-side metadata cache helper
├── flake.nix                      # devShell + container build
├── flake.lock
├── Dockerfile                     # upstream — minimal additive xmlsec apt extension
└── .github/workflows/
    ├── build.yml                  # consumes Flywheel composite actions
    └── deploy.yml                 # invokes blahaj _tofu-agent-shadow.yml
```

Tofu stack lives in `blahaj/tofu/stacks/caldera/` (separate repo, blahaj's domain).

## 4. Phases

### Phase 0 — Fork `mitre/saml`, carry v5-compat patch *(prerequisite, highest risk)*

**Investigation outcome (2026-05-04): PR #11 rejected.** It's a 404-line bot-generated refactor of `saml_svc.py` + `hook.py` that doesn't address issue #9 — it doesn't even touch `saml_login_handler.py` where the bug lives. It silently adds auto-user-provisioning, role mapping, ALB shims, SLO — none of which we want; all of which fight the upstream "pre-created accounts mapped by IdP application username" design.

**Real fix is 3 lines.** Caldera v5's login form POSTs empty `username` / `password` form fields on initial page load (i.e. the form-data string `username=&` followed by `pass` `word=`), so the existing key-presence check is always falsy. Mirror v5's `DefaultLoginHandler.handle_login` truthy semantic.

Patch:

```diff
--- a/app/saml_login_handler.py
+++ b/app/saml_login_handler.py
@@ -20,7 +20,7 @@ class SamlLoginHandler(LoginHandlerInterface):
     async def handle_login(self, request, **kwargs):
         data = await request.post()
-        if 'username' not in data and 'password' not in data:
+        if not data.get('username') or not data.get('password'):
             self.log.debug('Handling SAML login')
             await self.handle_login_redirect(request)
         else:
```

Steps:

1. Fork `mitre/saml` → `tinyland-inc/caldera-saml`.
2. Branch `v5-compat` off master.
3. Apply the 3-line patch above. Update docstring to explain the v5 reasoning + reference issue #9.
4. Smoke test against a Caldera v5.1+ instance with a SimpleSAMLphp mock IdP locally.
5. Tag `v5.0.0-tinyland.0`.
6. (Stretch) Add `tinyland/scripts/fetch-idp-metadata.sh` companion: GETs IdP metadata, validates signature, writes pinned fields into `settings.json`. Models real-world rotation.

**Exit criteria:** local run with patched plugin successfully completes IdP-initiated SSO against SimpleSAMLphp.

**Upstream PR potential:** the 3-line patch is small, focused, and addresses a known issue with a clear reproducer. Worth opening a real PR upstream once we've validated it — separate from PR #11.

### Phase 1 — Nix flake + image build through GloriousFlywheel

1. `flake.nix` `devShells.default`: `python311` + venv hooks, `go_1_24`, `nodejs_22`, `pnpm`, `xmlsec`, `libxmlsec1`, `libxml2`, `pkg-config`, `mingw-w64-gcc`, `git-lfs`, `sops`, `age`, `kubectl`, `helm`, `opentofu`. Mirror Flywheel's `devShells.default` shape; auto-wire Attic + Bazel cache.
2. `flake.nix` `packages.container`: `nix2container.buildImage` producing the runtime image. Keep upstream `Dockerfile` working (parity for community), but route our pipeline through the flake.
3. Minimal additive `Dockerfile` extension (apt-install `libxmlsec1-dev libxml2-dev pkg-config`) so the upstream Docker build still works for users without nix.
4. `.github/workflows/build.yml` uses `tinyland-inc/GloriousFlywheel/.github/actions/setup-flywheel@main` + `nix-job@main`. Runner labels `tinyland-nix-heavy` for image, `tinyland-nix` for tests.
5. cosign-sign + push to `ghcr.io/tinyland-inc/caldera`.
6. Fork-sync runbook: `mitre-master` tracking branch, merge (don't rebase) into `master`. Documented in `tinyland/docs/fork-sync-runbook.md`.

**Exit criteria:** `nix develop` works; CI produces a signed `ghcr.io/tinyland-inc/caldera:<sha>` image; upstream merge dry-run shows zero conflicts in `tinyland/`.

### Phase 2 — Vanilla deploy through blahaj

1. `tinyland/deploy/helm/caldera/`:
   - 1-replica Deployment, `strategy: Recreate`.
   - RWO PVC `50Gi` (expandable) with new StorageClass `openebs-bumble-caldera-retain` (ZFS recordsize=128k, compression=zstd, `Retain`, `allowVolumeExpansion: true`).
   - InitContainer mirrors the `data/` skeleton from the image into the PVC on first mount (idempotent).
   - NetworkPolicy: ingress from `tailscale-system/proxy` namespace + `kube-system` only.
2. `blahaj/tofu/stacks/caldera/main.tf` mirroring `massageithaca/`:
   - Helm release pointing at our chart (or rendered manifests, matching whatever blahaj convention is for the searxng stack).
   - Service annotated for Tailscale operator: `tailscale.com/expose=true`, `tailscale.com/hostname=caldera`, `tailscale.com/proxy-class=honey-sting-tailnet`.
   - Ingress with `cert-manager.io/cluster-issuer=letsencrypt-prod` for `caldera.tinyland.dev`, NGINX upstream HTTP to Caldera.
   - SOPS-encrypted `conf/local.yml` Secret: `encryption_key`, red/blue API keys.
   - Pod-roll-on-secret-change hash trick from massageithaca.
3. CI bumps image tag → human-approve via `_tofu-agent-shadow.yml` → tofu apply.
4. Smoke test: log in red/admin, run training plugin, confirm tailnet HTTPS resolves with valid LE cert.

**Exit criteria:** `https://caldera.tinyland.dev` reachable from tailnet with green cert, vanilla Caldera UI responsive, training plugin walkthrough completes.

### Phase 3 — SAML wiring with SimpleSAMLphp (IdP-001)

1. `tinyland/deploy/helm/simplesamlphp/` — minimal Helm chart, separate Service + Tailscale annotation `idp-001.tinyland.dev`, cert-manager Ingress.
2. `blahaj/tofu/stacks/idp-001-simplesamlphp/main.tf`. Pre-create one user with `username` attribute = `red`.
3. Submodule `plugins/saml` → `tinyland-inc/caldera-saml#v5.0.0-tinyland.0`.
4. Update Caldera `Dockerfile` extension: `pip install -r plugins/saml/requirements.txt`.
5. Add `saml` to plugin enable list in `conf/local.yml`. Set `auth.login.handler.module: plugins.saml.app.saml_login_handler`.
6. SOPS-encrypted `plugins/saml/conf/settings.json`:
   - `sp.entityId = https://caldera.tinyland.dev` (no trailing slash).
   - `sp.assertionConsumerService.url = https://caldera.tinyland.dev/saml`.
   - IdP block from SimpleSAMLphp's metadata.
   - `security`: per Phase 0 research notes (signed/encrypted assertions, SHA-256, NameID unspecified, `requestedAuthnContext: false`).
7. Pre-create `red`/`blue` Caldera accounts in `local.yml` `users:`.
8. End-to-end test: SP-initiated and IdP-initiated SSO; attribute mapping; clock-skew error path; expired metadata error path.

**Exit criteria:** all four authn paths green: red SP-initiated, red IdP-initiated, blue SP-initiated, blue IdP-initiated. Documented troubleshooting in `tinyland/docs/saml-troubleshooting.md`.

### Phase 4 — Build + deploy our own Shibboleth IdP 5.2 image

1. Build a Shibboleth IdP 5.2 image from a current Java 21 base. Don't trust stale `Unicon/shibboleth-idp-dockerized` tags. Pinned via Nix derivation in our flake (or separate Bazel target if cleaner).
2. Helm chart cribbed from `MiamiOH/helm-shibboleth-idp` (unmaintained — expect to fork into `tinyland-inc/helm-shibboleth-idp`).
3. `blahaj/tofu/stacks/idp-002-shibboleth/main.tf`:
   - Separate signing + encryption keypairs (SOPS-encrypted, never co-mingled).
   - `attribute-resolver.xml`: define `username` attribute, stable URN `urn:tinyland:caldera:username`, source-mapped from chosen attribute (uid/eppn/mail).
   - `attribute-filter.xml`: release `username` to Caldera's entityID only.
   - `metadata-providers.xml`: consume Caldera SP metadata with `<SignatureValidation>` filter pinning SP signing cert.
   - Tailscale-exposed at `idp-002.tinyland.dev` with cert-manager Ingress.
4. SP-side: build `tinyland/scripts/fetch-idp-metadata.sh` properly. Run as initContainer or CronJob seeding ConfigMap. Document rotation behavior.
5. Switch Caldera's `settings.json` from IdP-001 to IdP-002. Keep IdP-001 running as a fallback for diagnostics.
6. End-to-end test against Shibboleth: encrypted assertions decrypt, signed metadata exchange validates both directions, attribute filter works, clock-skew failure modes reproduce as expected, NameID transient handling correct.

**Exit criteria:** Caldera SSO flow against Shibboleth IdP 5.2 green for both SP- and IdP-initiated paths. Deliberate failure tests reproduce expected error pages with diagnostics. Metadata rotation drill: rotate IdP signing cert, verify SP picks up new cert via fetch-and-cache helper without manual intervention.

### Phase 5 — caldera-ot plugins (parallel, low-risk)

1. Add submodules under `plugins/`: modbus, dnp3, bacnet, profinet, iec61850, gems (all from `mitre/<name>`).
2. Pull `mitre/iec61850-payloads` latest release into `plugins/iec61850/payloads/` — initJob or build-time download via flake.
3. Enable in `conf/local.yml` plugin list.
4. Smoke: each plugin's UI tab loads, abilities visible. No actual OT-target testing this phase (separate follow-on).

**Exit criteria:** all six OT plugins enabled, UI loads, no regression to Caldera startup or SAML flow.

## 5. Open items / future work

- **tsidp adoption** — defer until ≥1.0 GA + maintained Caldera OIDC plugin exists. Migration path: either write/fork an OIDC plugin, or run Authentik as a SAML↔OIDC bridge in front of tsidp.
- **Multi-replica / external session store** — would require non-trivial Caldera changes (not currently designed for it). Out of scope.
- **OT agent placement on a real OT segment** — separate follow-on once we have an OT lab segment.
- **Public-fork community contribution** — once stabilized, evaluate whether the SAML v5-compat patch should be PR'd back upstream, and whether the Helm chart belongs in a public `tinyland-inc/caldera-helm` repo for community use.

## 6. References

### Upstream
- `mitre/caldera` Dockerfile + docker-compose.yml
- [CVE-2025-27364 advisory](https://medium.com/@mitrecaldera/mitre-caldera-security-advisory-remote-code-execution-cve-2025-27364-5f679e2e2a0e)
- [`mitre/saml` README + issue #9 + PR #11](https://github.com/mitre/saml)
- [`mitre/caldera-ot`](https://github.com/mitre/caldera-ot)

### Shibboleth
- [Shibboleth IdP downloads](https://shibboleth.net/downloads/identity-provider/)
- [IdPReleaseSchedule](https://shibboleth.atlassian.net/wiki/spaces/DEV/pages/4570349571/IdPReleaseSchedule)
- [Shibboleth AttributeNaming](https://shibboleth.atlassian.net/wiki/spaces/CONCEPT/pages/928645306/AttributeNaming)
- [Shibboleth NameIDGenerationConfiguration](https://shibboleth.atlassian.net/wiki/spaces/IDP4/pages/1265631671/NameIDGenerationConfiguration)
- [SAML-Toolkits/python3-saml](https://github.com/SAML-Toolkits/python3-saml)

### Local infra
- `~/git/blahaj/CLAUDE.md` — cluster topology
- `~/git/blahaj/tofu/stacks/massageithaca/main.tf` — new-app reference pattern
- `~/git/blahaj/.github/workflows/_tofu-agent-shadow.yml` — deploy orchestration
- `~/git/GloriousFlywheel/flake.nix` — devShell pattern
- `~/git/GloriousFlywheel/.github/actions/setup-flywheel/action.yml` — cache hint injection
- `~/git/GloriousFlywheel/examples/github/cache-backed-workflow.yml` — consumer template
