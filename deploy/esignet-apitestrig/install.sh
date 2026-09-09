#!/bin/bash
# Installs the eSignet api-test rig (Go harness, ../../helm/esignet-apitestrig
# chart).
## Usage: ./install.sh [kubeconfig]
#
# Only two prompts now -- everything else lives in values.yaml (tracked in
# git, edit it directly) and values.secret.yaml (gitignored, holds
# KEYCLOAK_CLIENT_SECRET / the test identity / S3 keys -- copy
# values.secret.yaml.example to get started). Previous versions of this
# script asked ~15 interactive questions for all of that; if you're used to
# that flow, the same settings now live in those two files instead.
#
# Installs from a locally-built chart package (a .tgz), not the raw chart
# directory -- build/refresh it with:
#   helm dependency build ../../helm/esignet-apitestrig
#   helm package ../../helm/esignet-apitestrig -d ../../helm
# CHART_VERSION below must match helm/esignet-apitestrig/Chart.yaml's
# version -- bump both together.

if [ $# -ge 1 ] ; then
  export KUBECONFIG=$1
fi

set -o errexit
set -o nounset
set -o errtrace
set -o pipefail

NS=esignet
RELEASE_NAME=esignet-apitestrig
CHART_NAME=esignet-apitestrig
CHART_VERSION=0.0.1-develop
CHART_PACKAGE="../../helm/${CHART_NAME}-${CHART_VERSION}.tgz"
VALUES_FILE=values.yaml
SECRET_VALUES_FILE=values.secret.yaml

function installing_apitestrig() {
  if [[ ! -f "$SECRET_VALUES_FILE" ]]; then
    echo "ERROR: $SECRET_VALUES_FILE not found."
    echo "Copy ${SECRET_VALUES_FILE}.example to $SECRET_VALUES_FILE and fill in"
    echo "KEYCLOAK_CLIENT_SECRET, the test identity, and S3 keys; EXITING."
    exit 1
  fi

  if [[ ! -f "$CHART_PACKAGE" ]]; then
    echo "ERROR: $CHART_PACKAGE not found."
    echo "Build it first:"
    echo "  helm dependency build ../../helm/${CHART_NAME}"
    echo "  helm package ../../helm/${CHART_NAME} -d ../../helm"
    echo "EXITING."
    exit 1
  fi

  echo "Create $NS namespace (if it doesn't already exist)"
  kubectl create ns "$NS" 2>/dev/null || true

  # Best-effort default, same as before: read eSignet's own host if it's
  # deployed in this namespace. Falls back to a bare prompt if not found.
  ESIGNET_HOST=$(kubectl -n "$NS" get cm esignet-global -o json 2>/dev/null | jq -r '.data."mosip-esignet-host"' 2>/dev/null || true)
  DEFAULT_BASE_URL=""
  if [[ -n "$ESIGNET_HOST" && "$ESIGNET_HOST" != "null" ]]; then
    DEFAULT_BASE_URL="https://$ESIGNET_HOST/v1/esignet"
  fi
  read -rp "eSignet base URL${DEFAULT_BASE_URL:+ [$DEFAULT_BASE_URL]}: " MOSIP_ESIGNET_BASE_URL
  MOSIP_ESIGNET_BASE_URL="${MOSIP_ESIGNET_BASE_URL:-$DEFAULT_BASE_URL}"
  if [[ -z "$MOSIP_ESIGNET_BASE_URL" ]]; then
    echo "ERROR: eSignet base URL is required; EXITING."
    exit 1
  fi

  read -rp "Have you reviewed/updated $VALUES_FILE for this environment? (Y/n): " values_confirmed
  values_confirmed=$(printf '%s' "$values_confirmed" | tr '[:upper:]' '[:lower:]')
  if [[ "$values_confirmed" != "y" ]]; then
    echo "Update $VALUES_FILE first (Keycloak/OTP/PMS settings, surfaces,"
    echo "report storage, etc.), then re-run this script; EXITING."
    exit 1
  fi

  echo ""
  echo "Installing $RELEASE_NAME in namespace $NS from $CHART_PACKAGE ..."
  helm -n "$NS" upgrade --install "$RELEASE_NAME" "$CHART_PACKAGE" \
    -f "$VALUES_FILE" \
    -f "$SECRET_VALUES_FILE" \
    --set apitestrig.extraEnvVars.MOSIP_ESIGNET_BASE_URL="$MOSIP_ESIGNET_BASE_URL"

  echo "Installed $RELEASE_NAME."
}

installing_apitestrig
