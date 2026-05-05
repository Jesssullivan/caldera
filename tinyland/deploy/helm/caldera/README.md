# caldera Helm chart

On-prem deployment chart for the [Tinyland fork of MITRE Caldera](https://github.com/Jesssullivan/caldera). Pairs with the OpenTofu stack in [blahaj](https://github.com/Jesssullivan/blahaj/tree/main/tofu/stacks/caldera) for the actual deploy, but is usable standalone.

Designed for the constraints in `tinyland/docs/plan-onprem-saml.md` (single-replica, RWO PVC, in-process state, CVE-2025-27364 image floor) and the Tailscale-operator + cert-manager substrate from blahaj.

## Quickstart

```bash
helm upgrade --install caldera ./tinyland/deploy/helm/caldera \
  --namespace caldera --create-namespace \
  --set image.tag="slim-<commit-sha>" \
  --set persistence.storageClass="openebs-bumble-caldera-retain" \
  --set service.tailscale.enabled=true \
  --set service.tailscale.hostname="caldera" \
  --set service.tailscale.proxyClass="honey-sting-tailnet" \
  --set ingress.enabled=true \
  --set ingress.host="caldera.tinyland.dev" \
  --set ingress.certManager.clusterIssuer="letsencrypt-prod"
```

You will also need a `caldera-config` Secret containing `local.yml` (and `settings.json` if SAML is enabled). Provision via SOPS — never plaintext in Git.

## Values reference

See [`values.yaml`](values.yaml) — every key is documented inline.

### Critical values to override

| Key | Why |
|---|---|
| `image.repository` / `image.tag` | Default tracks the Tinyland fork; pin a digest in production. |
| `persistence.storageClass` | Must match a real StorageClass in your cluster. The blahaj deployment uses a per-app `openebs-bumble-caldera-retain` SC with ZFS recordsize=128k. |
| `service.tailscale.proxyClass` | Must match a real ProxyClass; ours is `honey-sting-tailnet`. |
| `ingress.host` | The public URL; used as Caldera's SP entityId in SAML configs. |
| `config.secretName` | The Secret containing `local.yml` (and `settings.json` for SAML). |

### Phase-3 SAML wiring

Once you've enabled the `saml` plugin in your image build, set:

```yaml
plugins:
  - saml          # add at top of list so it loads early
  - access
  - atomic
  # ... rest unchanged
authLoginHandlerModule: plugins.saml.app.saml_login_handler
```

The chart then mounts `settings.json` from the same config Secret at `/usr/src/app/plugins/saml/conf/settings.json`.

See `tinyland/docs/plan-onprem-saml.md` § Phase 3 for the full IdP wiring.

## Deliberate non-features

- **No HPA / multi-replica** — Caldera writes in-process state. Don't.
- **No StatefulSet** — single-pod with a PVC is simpler and the upgrade story is just `Recreate`. StatefulSet adds no value here.
- **No webhook / mTLS** — TLS is terminated at the ingress (cert-manager) or the Tailscale proxy. Caldera serves HTTP internally.
- **No service-mesh sidecar** — Caldera's contact channels (TCP/UDP/WS) don't play well with most meshes' L7 parsing. NetworkPolicy is the substitute.

## Bumping image versions

Image bumps go via the build pipeline (`.github/workflows/build-tinyland-image.yml`); update `image.tag` to the new `slim-<sha>` and re-`helm upgrade`. The pod rolls under `Recreate` strategy — expect ~30s of downtime per upgrade.
