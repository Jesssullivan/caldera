#!/bin/sh
# Shibboleth IdP 5.2 entrypoint.
#
# IdP 5.x decoupled the servlet container from the install — there's no
# pre-baked jetty-base in /opt/shibboleth-idp anymore (that was a 4.x
# convention). We build jetty-base at first run from /opt/jetty-home's
# start.jar and deploy the idp.war that install.sh produced.
#
# Idempotent: a second run skips the jetty-base bootstrap if the marker
# file is present. This lets the container survive restarts on the same
# emptyDir / persistent volume without re-running the bootstrap.
set -eu

JETTY_BASE_DIR="${JETTY_BASE:-/opt/jetty-base}"
IDP_HOME="${IDP_HOME:-/opt/shibboleth-idp}"
JETTY_HOME_DIR="${JETTY_HOME:-/opt/jetty-home}"

if [ ! -f "${JETTY_BASE_DIR}/.bootstrapped" ]; then
    echo "[entrypoint] bootstrapping ${JETTY_BASE_DIR}"
    mkdir -p "${JETTY_BASE_DIR}"
    cd "${JETTY_BASE_DIR}"
    java -jar "${JETTY_HOME_DIR}/start.jar" \
        --approve-all-licenses \
        --add-modules=server,http,deploy,annotations,jsp,ee10-webapp,plus,ee10-plus,ee10-jsp

    # Wire idp.war into Jetty's webapps. Context path /idp matches the
    # default IdP entityID URL ($scope/idp/shibboleth).
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

    touch "${JETTY_BASE_DIR}/.bootstrapped"
fi

echo "[entrypoint] launching Jetty"
exec java ${JAVA_OPTS:-} \
    "-Didp.home=${IDP_HOME}" \
    -jar "${JETTY_HOME_DIR}/start.jar" \
    "jetty.home=${JETTY_HOME_DIR}" \
    "jetty.base=${JETTY_BASE_DIR}"
