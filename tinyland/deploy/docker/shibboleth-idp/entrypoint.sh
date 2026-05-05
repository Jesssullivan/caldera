#!/bin/sh
# Shibboleth IdP 5.2 entrypoint.
#
# IdP 5.x decoupled the servlet container from the install — there's no
# pre-baked jetty-base in /opt/shibboleth-idp anymore. We build jetty-base
# at every run from /opt/jetty-home's start.jar (cheap — ~5s), then drop
# the idp.war Configure context into webapps/. This keeps the entrypoint
# simple + idempotent + restart-safe.
#
# Jetty 12 module list: deploy + ee10-deploy is the pair you need for
# auto-scanning webapps/ for ee10 web applications. Naked `deploy` alone
# gives you the DeploymentManager bean but no per-environment scanner.
set -eu

JETTY_BASE_DIR="${JETTY_BASE:-/opt/jetty-base}"
IDP_HOME="${IDP_HOME:-/opt/shibboleth-idp}"
JETTY_HOME_DIR="${JETTY_HOME:-/opt/jetty-home}"

echo "[entrypoint] (re)bootstrapping ${JETTY_BASE_DIR}"
mkdir -p "${JETTY_BASE_DIR}"
cd "${JETTY_BASE_DIR}"

# Re-running --add-modules is idempotent — Jetty notices the modules are
# already enabled and only updates resources/templates that changed. Safe
# to run on every container start.
java -jar "${JETTY_HOME_DIR}/start.jar" \
    --approve-all-licenses \
    --add-modules=server,http,deploy,ee10-deploy,ee10-webapp,ee10-annotations,ee10-plus,ee10-jsp

# Wire idp.war into Jetty's webapps. Context path /idp matches the
# default IdP entityID URL ($scope/idp/shibboleth). Always overwrite —
# changes to IDP_HOME or webapp config get picked up on restart.
mkdir -p webapps
cat > webapps/idp.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Configure PUBLIC "-//Jetty//Configure//EN"
    "https://eclipse.dev/jetty/configure_10_0.dtd">
<Configure class="org.eclipse.jetty.ee10.webapp.WebAppContext">
  <Set name="contextPath">/idp</Set>
  <Set name="war">${IDP_HOME}/war/idp.war</Set>
  <Set name="extractWAR">false</Set>
  <Set name="copyWebInf">true</Set>
</Configure>
EOF

echo "[entrypoint] launching Jetty"
exec java ${JAVA_OPTS:-} \
    "-Didp.home=${IDP_HOME}" \
    -jar "${JETTY_HOME_DIR}/start.jar" \
    "jetty.home=${JETTY_HOME_DIR}" \
    "jetty.base=${JETTY_BASE_DIR}"
