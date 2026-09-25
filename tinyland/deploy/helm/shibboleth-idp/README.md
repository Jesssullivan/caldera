# shibboleth-idp Helm chart (Phase 4)

Status: **adopted-live IdP-002 chart**. Caldera still selects IdP-001; a
Shibboleth chart release is not an SP cutover or authenticated SAML proof.

This chart deploys the Shibboleth IdP 5.2 image built from
`tinyland/deploy/docker/shibboleth-idp/`. It deliberately shadows the layout
of `tinyland/deploy/helm/simplesamlphp/` so the operator can reuse muscle
memory between IdP-001 and IdP-002.

## Public metadata file

Shibboleth serves `/idp/shibboleth` from an install-time static
`metadata/idp-metadata.xml`; the endpoint does not dynamically reflect the
runtime issuer or mounted certificates. When `idpConfig.configMapName` is set,
the chart mounts its reviewed `idp-metadata.xml` key as one read-only subPath
file alongside the four existing XML overrides. Never mount a partial
`idp.properties.override` over the full installed properties file, or mount
the whole metadata directory over the image. The owner-provided
`podAnnotations` metadata checksum changes the pod template when the file
changes, because a running subPath mount does not refresh. Chart version
0.1.1 carries this mount so the existing Helm release can detect the chart
change. XML entityID, endpoints, certificate parity and runtime issuer are
separate owner acceptance checks.

## Historical Phase 4 bring-up plan

The list below records the old bring-up plan, not current installation
status or approval to execute a cutover:

1. Pin `IDP_VERSION` + `IDP_SHA256` + `JETTY_VERSION` + `JETTY_SHA256` in the
   Dockerfile's `ARG` lines after a known-good first pull. This was completed
   for the shipped image; it is not an open prerequisite.
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
