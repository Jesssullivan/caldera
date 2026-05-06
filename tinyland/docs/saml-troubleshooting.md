# SAML Troubleshooting — Tinyland Caldera

Living document. Add a row each time we hit a new failure mode while
exercising the Caldera SP path against an IdP. Pair with browser
SAML-tracer captures (Firefox add-on) when the symptom involves a
specific assertion or redirect.

## Decision tree

```
Open https://caldera.tinyland.dev
   │
   ├─ ❶ Not redirected to IdP
   │      → see "Stuck on /login" below
   │
   ├─ ❷ Redirected to IdP, IdP shows error
   │      → see "IdP-side errors"
   │
   ├─ ❸ Redirected back to /saml, lands on /login
   │      → see "ACS POST falls through"
   │
   └─ ✓ Logged in as red/blue
          → smoke test passed
```

## Stuck on `/login` (no SAML redirect)

| Symptom | Likely cause | Fix |
|---|---|---|
| Loops between `/` and `/login` | `auth.login.handler.module` not set in `conf/local.yml` | Set `auth.login.handler.module: plugins.saml.app.saml_login_handler` and restart the pod. |
| `Requester provided login credentials. Using default login handler instead.` in logs | Caldera v5 form posts empty `username`/`password` fields. The pre-`v5-compat` plugin treats this as a credential submission. | Make sure the plugin submodule points at `tinyland-inc/caldera-saml@v5-compat` (the patched truthy-check). Verify `pip show python3-saml` shows the plugin loaded. |
| `SAML configuration file not found: /usr/src/app/plugins/saml/conf/settings.json` | Config Secret missing the `settings.json` key, or the volumeMount path is wrong | Inspect: `kubectl exec -n caldera deploy/caldera -- ls -la /usr/src/app/plugins/saml/conf/`. If empty, recheck `var.enable_saml` and `var.saml_settings_json` in the tofu stack. |

## IdP-side errors

| Symptom | Likely cause | Fix |
|---|---|---|
| IdP rejects the SP's metadata | SP signing cert mismatch or the IdP's metadata-providers.xml doesn't trust our SP | For Shibboleth: regenerate SP metadata, copy to IdP's `metadata/sp-tinyland-caldera.xml`, ensure the `<SignatureValidation>` filter trust anchor matches. For SimpleSAMLphp lab: nothing to do. |
| `Requester` SAML status code | SP's AuthnRequest is malformed or signed with a key the IdP doesn't trust | Verify `sp.entityId` exactly matches what the IdP expects. Check `requestedAuthnContext: false` in security block (Shibboleth doesn't always advertise PasswordProtectedTransport). |
| `Responder` SAML status code | IdP-side problem (attribute resolver chain, assertion encryption key) | Check IdP logs (`/opt/shibboleth-idp/logs/idp-process.log` for Shibboleth). |

## ACS POST falls through to `/login`

| Symptom | Likely cause | Fix |
|---|---|---|
| `Invalid timestamp on the SAML response` | Clock skew between SP and IdP > 3 min | Run NTP on both pods. python3-saml is strict on `NotBefore`/`NotOnOrAfter`. |
| `Signature validation failed` | Cert mismatch — IdP rotated its signing cert, our pinned `idp.x509cert` is stale | Rotate the cert in the SOPS-encrypted `saml_settings_json`, re-apply the tofu stack. (Phase 0's stretch helper `tinyland/scripts/fetch-idp-metadata.sh` handles this automatically once written.) |
| `No Signature found` | IdP returned an unsigned response | Check IdP config — Shibboleth's `relyingparty.xml` must sign assertions for our SP. |
| `Application username "X" not configured for login` | The `username` AttributeStatement value doesn't match any account in `users:` | Either add the user to `conf/local.yml` or change the IdP attribute-resolver to release the existing red/blue account name. |
| `No NameID or username attribute provided` | IdP not releasing a `username` attribute | Shibboleth: edit `attribute-filter.xml` to release `username` to our SP's entityId. SimpleSAMLphp: set `authproc.idp` rule to add `username` from `uid`. |
| `SameSite cookie blocked` (browser console) | API_SESSION cookie didn't survive the cross-site POST from IdP to /saml | Caldera's session cookie should be `SameSite=None; Secure`. If the browser strips it, ensure the SP runs over HTTPS end-to-end (no mixed http/https proxy chain). |

## Useful evidence to capture

- **Browser**: SAML-tracer add-on records the AuthnRequest, the IdP's response, and the SP's POST handling. Save to JSON for paste-into-issues.
- **Caldera pod**: `kubectl logs -n caldera deploy/caldera --since=5m | grep -iE 'saml|signature|attribute'`
- **SP entityId stability**: `kubectl get -n caldera secret caldera-config -o jsonpath='{.data.local\.yml}' | base64 -d | grep -A2 'sp:'`
- **IdP pod logs**: depends on IdP — see Phase-specific docs.

## Known not-yet-fixed gotchas

- **Single Logout (SLO)** is not supported by `mitre/saml`. Logout doesn't propagate back to the IdP. Closing the browser tab is the only "logout."
- **Multi-replica session loss**: in-process session storage means an even number of pods + ingress round-robin breaks the AuthnRequest → ACS round trip. Keep replicaCount=1 (the chart enforces this).
- **xmlsec build pain in slim images**: the SAML plugin pins `xmlsec==1.3.9` which can fail to build on `python:slim`. Our Dockerfile installs `libxmlsec1-dev libxml2-dev pkg-config xmlsec1` to avoid this.

---

*References: `tinyland/docs/plan-onprem-saml.md` § Phase 3, [mitre/saml#9](https://github.com/mitre/saml/issues/9), Shibboleth IdP 5.2 docs.*
