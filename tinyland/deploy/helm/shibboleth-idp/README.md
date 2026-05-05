# shibboleth-idp Helm chart (Phase 4)

Status: **scaffold only** — Phase 4 is in progress as of 2026-05-05.

This chart will eventually deploy the Shibboleth IdP 5.2 image built from
`tinyland/deploy/docker/shibboleth-idp/`. It deliberately shadows the layout
of `tinyland/deploy/helm/simplesamlphp/` so the operator can reuse muscle
memory between IdP-001 and IdP-002.

## Phase 4 work in flight

The IdP-002 stack is **not yet deployable**. Required follow-up:

1. Pin `IDP_VERSION` + `IDP_SHA256` + `JETTY_VERSION` + `JETTY_SHA256` in the
   Dockerfile's `ARG` lines after a known-good first pull. The current
   placeholder `__pin_after_first_pull__` lets the build succeed on a
   first run but provides no integrity guarantee.
2. Author the chart templates: deployment, service, ingress, configmap with
   `attribute-resolver.xml` / `attribute-filter.xml` / `metadata-providers.xml`
   / `relying-party.xml`, plus a Secret for the IdP's signing+encryption
   keypairs.
3. Stand up `blahaj/tofu/stacks/idp-002-shibboleth/` mirroring the IdP-001
   stack pattern.
4. Wire Caldera SP's `settings.json` to consume IdP-002 metadata (via the
   `tinyland/scripts/fetch-idp-metadata.sh` helper that
   `plan-onprem-saml.md` already calls out).
5. End-to-end test all four flows (red/blue × SP-init/IdP-init) against
   IdP-002 with `wantAssertionsEncrypted: true` flipped on the SP side.

## Why we're rebuilding our own image

`Unicon/shibboleth-idp`, `tier/shib-idp`, and `iay/shibboleth-idp-docker`
all stagnated before IdP 5 shipped. The Shibboleth Consortium does not
publish an official upstream container. DAASI's `shibidpv5-baseimage` is
the closest to "actively maintained" community starting point and is
worth borrowing from, but we own our build for the same public-fork
hygiene reasons that drive the rest of this fork.
