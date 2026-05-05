# Phase 4 — Shibboleth IdP 5.2 deployment plan

Status: **research-converged, awaiting operator decisions** before we author
config + build the image.

This document consolidates three parallel research threads run on
2026-05-05:

1. **Bates EMS** SAML pattern extraction (`~/bates/ems`) — institutional
   schema-driven config + algebraic invariants test contract.
2. **Remote image build** options inventory — GloriousFlywheel runners +
   attic-rustfs + Nix vs. Bazel.
3. **Shibboleth IdP 5.x** institutional reference patterns from AAF,
   SWAMID, ACOnet, and shibboleth.net itself.

---

## 1. Image build — recommendation

**Option 1: CI workflow on `tinyland-dind`** (mirrors `build-tinyland-image.yml`).

Rationale (full evaluation in research notes):

- Already-proven pattern in this repo (caldera image builds via the same
  template).
- Keyless cosign attestation ties signature to GitHub OIDC subject
  (`subject` includes repo+ref+sha) — public-fork verifiers confirm
  provenance with `cosign verify --certificate-identity-regexp`.
- Ships in an afternoon. Copy-paste, swap context, drop Trivy step.
- Reproducibility caveats: APT mirror drift breaks bit-identity. SHA-pin
  bases (already done) + `SOURCE_DATE_EPOCH` gets us "close enough."

**Fallback: Option 2** — `dockerTools.buildLayeredImage` on the
`tinyland-nix` lane. Bit-for-bit reproducible by design, attic-rustfs
caches the Nix store closure for ~10s rebuilds. Worth pursuing if (a)
we need hourly rebuilds (cert rotation), or (b) supply-chain auditors
demand bit-identical rebuilds. Lift: package Jetty + IdP war + jetty-base
as fixed-output derivations (~3-4 hours).

**Skip: Option 3** — `rules_oci`. No existing Bazel footprint in caldera;
pure overhead for one image.

**Decision needed**: Option 1 default, OR jump straight to Option 2 because
public-fork bit-identity is a stated goal? *Recommendation: Option 1, ship
this week, revisit Option 2 after Phase 4.F end-to-end test passes.*

---

## 2. IdP config — institutional reference

The strongest 5.x reference is **AAF's `ausaccessfed/shibboleth-idp5-installer`**
— actively maintained, ships the four files in question, and is what
Australian universities deploy almost verbatim. SWAMID, ACOnet, and
GARR/IDEM corroborate.

### Key 5.x change to bake in

**AttributeRegistry replaces inline `<AttributeEncoder>` for standard
attributes.** In v5, `conf/attributes/default-rules.xml` ships transcoding
rules for every eduPerson/SAML-Subject-ID attribute. Don't write encoders
for `eduPersonPrincipalName`, `mail`, `samlSubjectID` — the registry
encodes them with the correct OID name + URI NameFormat for free.

### Attribute strategy decision

Two paths for the caldera SP's "user identifier" attribute:

**A. Reuse `eduPersonPrincipalName`** (federation-standard, registry-handled):
   - SP receives `jess@tinyland.dev`-style scoped value.
   - Caldera's local user accounts are bare strings (`red`, `blue`) —
     would need an SP-side mapping from `red@tinyland.dev` → `red`. Plugin
     work or Caldera's `username` attribute matching needs configuration
     to strip the scope.
   - Cleanest federation interop story; rolls up to InCommon/eduGAIN
     conventions if we ever externally federate.

**B. Custom `username` attribute** (registry-bypass, explicit encoder):
   - SP receives bare `red` / `blue`.
   - Matches what IdP-001 currently emits — caldera plugin path is
     unchanged.
   - Non-standard; doesn't carry SP-to-IdP context if IdP-002 ever needs
     to federate beyond caldera.

**Recommendation: B for the lab.** Match IdP-001's contract so the
caldera plugin's account-mapping code is unchanged. Phase 5 (or whenever
we federate beyond caldera) revisits.

### Filter pattern

Per-SP `<AttributeFilterPolicy>` keyed on `xsi:type="Requester"`
(modern v5 idiom; legacy `basic:Requester` still works but is the v3
namespace). Releases the chosen attribute(s) only to caldera's entityId.

### Metadata pattern

`<FilesystemMetadataProvider>` referencing `metadata/caldera-sp.xml`.
Local file is simplest for one self-controlled SP. The
`FileBackedHTTPMetadataProvider` + `<SignatureValidation>` filter
pattern is reserved for federation aggregates.

### Relying-party override

Plain `SAML2.SSO` (not `SAML2.SSO.MDDriven`) so our overrides win over
metadata hints. Set:

- `signAssertions=true`
- `encryptAssertions=true` (Phase 4 goal — was `false` in IdP-001 lab)
- `encryptNameIDs=false`
- `nameIDFormatPrecedence="urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified"`

---

## 3. Keypair strategy

### IdP keys

`bin/keygen.sh` from IdP 5 produces **separate** signing + encryption
keypairs by default (SWITCH and SWAMID explicitly recommend this so each
can rotate independently):

- `credentials/idp-signing.{key,crt}`
- `credentials/idp-encryption.{key,crt}`
- `credentials/idp-backchannel.{key,crt,p12}` (rarely used; we can omit)
- `credentials/sealer.jks` + `sealer.kver`

Algorithm: **RSA 3072** is the v5 default (bumped from 2048 in older
4.x per InCommon Baseline Expectations). RSA 4096 for stricter shops;
EC P-256 is supported but federation interop is patchy.

**Recommendation: RSA 3072.** Matches v5 default; sufficient for Phase 4.

### Sealer rotation

`sealer.jks` is a JCEKS keystore with versioned AES keys for DataSealer
(cookie/state encryption). Rotation is **in-place** via `bin/seckeygen.sh` —
appends a new key version, retains the old (default `--count 30`). The IdP
watches both files and picks up new versions **live, no restart needed**,
making it cluster-safe.

**Recommendation: weekly cron rotation.** Mount `sealer.jks` + `sealer.kver`
from a Secret that the chart updates via a CronJob (or have tofu rotate
on apply). Phase 4 ships with the bake-time random key; CronJob is
follow-up.

### Storage

All IdP keys live in `tummycrypt/credentials/idp-002-shibboleth-keys.yaml`,
SOPS-encrypted. The chart's `idpCredentials.secretName` points at a
kubernetes Secret rendered by the tofu stack from the SOPS bundle. Path
parallels `caldera-sp-keys.yaml`.

### Bates EMS pattern lessons

The Bates pattern keeps `cert paths` in registry/config (not embedded keys
in the schema). The Dhall typed config exposes 11 fields including
`spCertPublicPath`/`spCertPrivatePath` as paths, not values. The actual
PEM material lives outside the schema.

For us: the Helm chart `values.yaml` already follows this — `idpCredentials.secretName`
is a reference, not embedded keys. **No change needed.** We're aligned
with the Bates institutional pattern by accident.

---

## 4. Algebraic invariants test contract

Bates' `test_saml_algebraic_invariants.py` enforces 8 invariants. Half
transfer directly to caldera/IdP-002:

1. **Identity invariant**: `sp_entity_id == sp_callback_url` base
   (caldera SP entityId = `https://caldera.tinyland.dev`, ACS =
   `https://caldera.tinyland.dev/saml`). Caldera doesn't enforce this
   identity, but the URL composition rule below covers the same risk.
2. **No path leakage**: SP entityId base doesn't contain `/saml` —
   the runtime appends. Caldera's plugin code matches this convention
   (entityId is the host root).
3. **IdP entity composition**: `idp_entity_id =
   https://{idp_host}/idp/shibboleth`. Already encoded in our
   chart's `values.yaml` default.
4. **IdP URL suffix composition**: SSO URL = `{idp_entity_id}/profile/SAML2/Redirect/SSO`.
   Already in `templates/NOTES.txt`.

**Action**: port these 4 invariants to a `tests/integration/test_saml_invariants.py`
in caldera's plugins/saml/ test tree. They're cheap unit checks that catch
config drift before deploy.

---

## 5. Open decisions for the operator

Before Phase 4 implementation starts, decide:

| # | Decision | Recommendation | Why |
|---|----------|----------------|-----|
| 1 | Image build path | Option 1 (CI on tinyland-dind) | Ships fastest; cosign keyless preserves provenance |
| 2 | Attribute name | Custom `username` attribute (B) | Matches IdP-001 contract; no caldera plugin change |
| 3 | Keypair algorithm | RSA 3072 | v5 default; federation-safe |
| 4 | Sealer rotation | Bake-time random initially, CronJob follow-up | Sufficient for lab, not blocking deploy |
| 5 | Federation metadata | Local file (`FilesystemMetadataProvider`) | Simplest for one self-controlled SP |
| 6 | Test invariants | Port 4 of bates' 8 to plugins/saml/tests | Catch config drift early |

---

## 6. Implementation order (post-decisions)

1. **Add `build-shibboleth-image.yml` workflow** mirroring
   `build-tinyland-image.yml`. PR-triggered builds against caldera,
   pushes `ghcr.io/jesssullivan/shibboleth-idp:5.2.1`.
2. **First image build via CI** to validate the Dockerfile + install.sh
   non-interactive flow. Pull image, inspect `/opt/shibboleth-idp/conf/`
   for default templates we'll override.
3. **Author the four XML config files** in
   `tinyland/deploy/helm/shibboleth-idp/templates/idp-config-configmap.yaml`,
   templated from the AAF reference + decisions above.
4. **Generate IdP keypairs** offline (`openssl req` for signing/encryption,
   `keytool -genkeypair` for sealer.jks), SOPS-encrypt to
   `tummycrypt/credentials/idp-002-shibboleth-keys.yaml`.
5. **Stand up `blahaj/tofu/stacks/idp-002-shibboleth/`** mirroring
   idp-001's layout. Render `idp-config-configmap` from atomic vars
   (similar to caldera's `saml_settings_json` rendering pattern).
6. **First deploy** to honey/bumble alongside IdP-001. SP still points
   at IdP-001 — verify IdP-002 metadata + login flow with a temporary
   test SP (or `curl` against `/idp/profile/Metadata/SAML`).
7. **Render second `settings.json` profile** for caldera consuming
   IdP-002 metadata. Bump caldera tofu vars; apply. Smoke-test all four
   red/blue × SP/IdP-init flows.
8. **Tighten SP `wantAssertionsEncrypted=true`.** Phase 4 exit criterion.
9. **Decommission IdP-001** after a 1-week grace period (rollback
   safety).

Estimate: 2-3 focused sessions. Parallelizable: keypair generation (#4)
and tofu stack scaffolding (#5) can happen alongside CI workflow + first
image build (#1, #2).

---

## 7. Honey-hosted YubiKey for no-touch signatures

Operator note: honey hosts the YubiKey via remote-signing (a la
`gpg-agent --extra-socket`). For Phase 4 commits during long sessions,
this avoids the YubiKey-touch-timeout pattern that has bitten this
session twice already. Setup: SSH-forward `gpgconf --list-dirs
agent-extra-socket` from honey to the operator workstation.
