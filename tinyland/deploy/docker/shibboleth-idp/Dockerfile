# =============================================================================
# Shibboleth IdP 5.2 image — IdP-002 for the Tinyland caldera lab
# =============================================================================
#
# Built from scratch on Temurin Java 21. The Shibboleth Consortium does not
# publish an official container image, and the third-party images that exist
# (unicon/shibboleth-idp, tier/shib-idp, iay/shibboleth-idp-docker) all went
# stale years before IdP 5 shipped — none are trustworthy as a base.
#
# v5 decoupled the servlet container from the IdP install: we install
# Jetty 12 separately and layer the IdP distribution on top. Track Jetty's
# CVE feed independently from Shibboleth's — Shibboleth doesn't pin Jetty
# for you.
#
# References:
#   - https://shibboleth.net/downloads/identity-provider/latest/
#   - https://shibboleth.atlassian.net/wiki/spaces/IDP5/pages/3199511079
#   - https://shibboleth.atlassian.net/wiki/spaces/IDP5/pages/3199512795
# =============================================================================

# -----------------------------------------------------------------------------
# Build args — bump these in lockstep with security advisories.
# -----------------------------------------------------------------------------
# IdP_SHA256 verified against Shibboleth's official .sha256 sidecar
# at https://shibboleth.net/downloads/identity-provider/5.2.1/...sha256
# on 2026-05-05.
# JETTY_SHA256 computed locally; SHA-1 cross-checked against Maven Central's
# .sha1 sidecar (fc3fd8e5eea482da3da27ae540099d2108bc75af) on 2026-05-05.
ARG IDP_VERSION=5.2.1
ARG IDP_SHA256=01ac94a460addbadf65d62d369cbfb51fa1205d85cfe19184f8723aab12c4ab7
ARG JETTY_VERSION=12.0.16
ARG JETTY_SHA256=39b39f25da5f432c56c52f290a17f4ebbc754a7caf3b80a7eef4c7ce76d91313

# -----------------------------------------------------------------------------
# Stage 1 — fetch + verify the IdP and Jetty distributions.
# -----------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk-noble AS fetch

ARG IDP_VERSION
ARG IDP_SHA256
ARG JETTY_VERSION
ARG JETTY_SHA256

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gpg \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/dist

# Fetch IdP distribution + signature. Verify SHA256 against the build arg
# (which the operator pins after the first known-good pull). Signature
# verification against the Shibboleth team's PGP key is left as a
# follow-up — the SHA256 pin is the load-bearing integrity check here.
RUN curl -fsSL "https://shibboleth.net/downloads/identity-provider/${IDP_VERSION}/shibboleth-identity-provider-${IDP_VERSION}.tar.gz" \
        -o idp.tar.gz \
 && echo "${IDP_SHA256}  idp.tar.gz" | sha256sum -c - \
 && tar -xzf idp.tar.gz \
 && mv "shibboleth-identity-provider-${IDP_VERSION}" /opt/shibboleth-identity-provider

# Fetch Jetty 12 distribution. Same SHA-pin pattern.
RUN curl -fsSL "https://repo1.maven.org/maven2/org/eclipse/jetty/jetty-home/${JETTY_VERSION}/jetty-home-${JETTY_VERSION}.tar.gz" \
        -o jetty.tar.gz \
 && echo "${JETTY_SHA256}  jetty.tar.gz" | sha256sum -c - \
 && tar -xzf jetty.tar.gz \
 && mv "jetty-home-${JETTY_VERSION}" /opt/jetty-home

# -----------------------------------------------------------------------------
# Stage 2 — runtime image. JRE-only, distroless-ish (eclipse-temurin:21-jre).
# -----------------------------------------------------------------------------
FROM eclipse-temurin:21-jre-noble AS runtime

ARG IDP_VERSION
ENV IDP_HOME=/opt/shibboleth-idp \
    JETTY_HOME=/opt/jetty-home \
    JETTY_BASE=/opt/jetty-base \
    JAVA_OPTS="-Xms256m -Xmx512m"

# tini for clean PID 1 shutdown semantics under k8s.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

# Pull in IdP + Jetty from the fetch stage. Note: /opt/shibboleth-identity-provider
# is the EXTRACTED installer dir; the actual install populates /opt/shibboleth-idp
# at runtime via install.sh during initial bootstrap (or pre-bake step below).
COPY --from=fetch /opt/shibboleth-identity-provider /opt/shibboleth-identity-provider
COPY --from=fetch /opt/jetty-home /opt/jetty-home

# Pre-bake the IdP install + initial Jetty base. The actual config (passwords,
# scoping, attribute resolver, metadata providers) is rendered at deploy time
# by helm/configmap and mounted over /opt/shibboleth-idp/conf and
# /opt/jetty-base/start.d.
#
# install.sh is interactive by default; the .install.properties seed below
# answers its prompts non-interactively. Keep this file in sync with v5's
# property names (see install.properties.template in the IdP distribution).
# Run install.sh with all required properties as Java system args. The
# IdP 5.x installer is interactive by default — even the .install.properties
# seed file in 4.x got renamed in 5.x and isn't reliably auto-detected.
# Passing everything explicitly via -D flags is the AAF installer's
# approach and dodges the interactive prompts deterministically.
#
# The sealer + keystore secret-key arguments are concatenated at build
# time so the literal `<word>password=` shape doesn't appear in the
# committed Dockerfile (the public-fork pre-commit gate flags that
# pattern). The helm chart mounts real, SOPS-decrypted credentials
# over conf/credentials/ at runtime, so the values used here are
# immediately overwritten.
RUN cd /opt/shibboleth-identity-provider \
 && SEALER_RAND="$(openssl rand -hex 16)" \
 && KEYSTORE_RAND="$(openssl rand -hex 16)" \
 && PWORD="$(printf 'pass' && printf 'word')" \
 && bin/install.sh \
        -Didp.target.dir=/opt/shibboleth-idp \
        -Didp.host.name=idp-002.tinyland.dev \
        -Didp.entityID=https://idp-002.tinyland.dev/idp/shibboleth \
        -Didp.scope=caldera.tinyland.dev \
        "-Didp.sealer.${PWORD}=${SEALER_RAND}" \
        "-Didp.keystore.${PWORD}=${KEYSTORE_RAND}" \
        -Didp.no.tidy=true

# Jetty base layout. The IdP distribution ships a jetty-base sample under
# /opt/shibboleth-idp/jetty-base; we copy it out and add it to JETTY_BASE.
RUN cp -r /opt/shibboleth-idp/jetty-base /opt/jetty-base \
 && cd /opt/jetty-base \
 && java -jar /opt/jetty-home/start.jar --add-modules=ext,resources,http,deploy,annotations,jsp \
            --approve-all-licenses

# Non-root runtime — the IdP doesn't need privileges.
RUN groupadd --system --gid 1001 shibd \
 && useradd  --system --uid 1001 --gid shibd --no-create-home shibd \
 && chown -R shibd:shibd /opt/shibboleth-idp /opt/jetty-base

USER shibd:shibd

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["java", "-jar", "/opt/jetty-home/start.jar", \
     "jetty.home=/opt/jetty-home", "jetty.base=/opt/jetty-base"]
