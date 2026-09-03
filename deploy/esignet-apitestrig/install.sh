#!/bin/bash
# Installs the eSignet api-test rig (Go harness, ../../helm/apitestrig chart).
## Usage: ./install.sh [kubeconfig]
#
# This replaces the old Java-testrig wrapper that installed the published
# `mosip/apitestrig` chart with `modules.esignet.enabled=true`. The Go
# harness (api-test/) is a single image with selectable "surfaces"
# (conformance/api/e2e), not one image per MOSIP module, so this script
# drives ../../helm/apitestrig directly instead.

if [ $# -ge 1 ] ; then
  export KUBECONFIG=$1
fi

set -o errexit
set -o nounset
set -o errtrace
set -o pipefail

NS=esignet
RELEASE_NAME=esignet-apitestrig
CHART_PATH=../../helm/apitestrig

function installing_apitestrig() {
  echo "Create $NS namespace (if it doesn't already exist)"
  kubectl create ns "$NS" 2>/dev/null || true

  echo "Building chart dependencies (bitnami/common) for $CHART_PATH"
  helm dependency build "$CHART_PATH"

  # Best-effort: this deploy wrapper assumes eSignet is already deployed in
  # the same namespace, so try to read its host/keycloak config to offer as
  # defaults. Falls back to a bare prompt if the configmaps aren't there
  # (e.g. eSignet lives in a different cluster/namespace).
  ESIGNET_HOST=$(kubectl -n "$NS" get cm esignet-global -o json 2>/dev/null | jq -r '.data."mosip-esignet-host"' 2>/dev/null || true)
  KEYCLOAK_EXTERNAL_URL=$(kubectl -n "$NS" get cm keycloak-host -o json 2>/dev/null | jq -r '.data."keycloak-external-url"' 2>/dev/null || true)

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

  DEFAULT_TOKEN_URL=""
  if [[ -n "$KEYCLOAK_EXTERNAL_URL" && "$KEYCLOAK_EXTERNAL_URL" != "null" ]]; then
    read -rp "Keycloak realm [mosip]: " REALM_ID
    REALM_ID="${REALM_ID:-mosip}"
    DEFAULT_TOKEN_URL="$KEYCLOAK_EXTERNAL_URL/realms/$REALM_ID/protocol/openid-connect/token"
  fi
  read -rp "Keycloak token URL${DEFAULT_TOKEN_URL:+ [$DEFAULT_TOKEN_URL]}: " KEYCLOAK_TOKEN_URL
  KEYCLOAK_TOKEN_URL="${KEYCLOAK_TOKEN_URL:-$DEFAULT_TOKEN_URL}"
  if [[ -z "$KEYCLOAK_TOKEN_URL" ]]; then
    echo "ERROR: Keycloak token URL is required; EXITING."
    exit 1
  fi

  read -rsp "Keycloak client secret for the test client (input hidden): " KEYCLOAK_CLIENT_SECRET
  echo
  if [[ -z "$KEYCLOAK_CLIENT_SECRET" ]]; then
    echo "ERROR: Keycloak client secret is required; EXITING."
    exit 1
  fi

  ESIGNET_TLS_VERIFY="true"
  API_TLS_VERIFY="true"
  read -rp "Does the eSignet endpoint use a self-signed/internal certificate? (y/N): " insecure_flag
  insecure_flag=$(printf '%s' "$insecure_flag" | tr '[:upper:]' '[:lower:]')
  if [[ "$insecure_flag" == "y" ]]; then
    ESIGNET_TLS_VERIFY="false"
    API_TLS_VERIFY="false"
  fi

  read -rp "Test individual ID (UIN/VID/phone/email of a pre-provisioned test identity): " INDIVIDUAL_ID
  if [[ -z "$INDIVIDUAL_ID" ]]; then
    echo "ERROR: Individual ID is required; EXITING."
    exit 1
  fi

  ID_TYPE=""
  while [[ "$ID_TYPE" != "uin" && "$ID_TYPE" != "vid" && "$ID_TYPE" != "phone" && "$ID_TYPE" != "email" ]]; do
    read -rp "ID type (uin/vid/phone/email): " ID_TYPE
    ID_TYPE=$(printf '%s' "$ID_TYPE" | tr '[:upper:]' '[:lower:]')
  done

  echo ""
  echo "Which surfaces should run?"
  echo "  1) api,e2e             - no OpenID Conformance Suite required"
  echo "  2) conformance,api,e2e - requires the Conformance Suite already running in-cluster"
  read -rp "Enter your choice [1-2]: " SURFACE_CHOICE

  CONFORMANCE_BASE_URL=""
  case "$SURFACE_CHOICE" in
    2)
      SURFACES="conformance,api,e2e"
      read -rp "Conformance suite base URL (e.g. http://openid-conformance-suite.<ns>.svc.cluster.local:8443): " CONFORMANCE_BASE_URL
      if [[ -z "$CONFORMANCE_BASE_URL" ]]; then
        echo "ERROR: Conformance suite base URL is required for this surface selection; EXITING."
        exit 1
      fi
      ;;
    *)
      SURFACES="api,e2e"
      ;;
  esac

  read -rp "Please enter the time (hr) to run the cronjob every day (0-23): " time
  if [[ -z "$time" ]] || ! [[ "$time" =~ ^[0-9]+$ ]] || (( time < 0 || time > 23 )); then
    echo "ERROR: Time must be a number between 0 and 23; EXITING."
    exit 1
  fi

  echo ""
  read -rp "Do you have S3 (or MinIO) details for storing apitestrig reports? (y/N): " s3_ans
  s3_ans=$(printf '%s' "$s3_ans" | tr '[:upper:]' '[:lower:]')

  REPORT_OPTS=()
  if [[ "$s3_ans" == "y" ]]; then
    read -rp "S3 endpoint (e.g. https://s3.amazonaws.com or http://minio.minio:9000): " s3_endpoint
    if [[ -z "$s3_endpoint" ]]; then
      echo "ERROR: S3 endpoint is required; EXITING."
      exit 1
    fi
    read -rp "S3 bucket: " s3_bucket
    if [[ -z "$s3_bucket" ]]; then
      echo "ERROR: S3 bucket is required; EXITING."
      exit 1
    fi
    read -rp "S3 path prefix [apitestrig/esignet]: " s3_prefix
    s3_prefix="${s3_prefix:-apitestrig/esignet}"
    read -rp "S3 access key: " s3_access_key
    if [[ -z "$s3_access_key" ]]; then
      echo "ERROR: S3 access key is required; EXITING."
      exit 1
    fi
    read -rsp "S3 secret key (input hidden): " s3_secret_key
    echo
    if [[ -z "$s3_secret_key" ]]; then
      echo "ERROR: S3 secret key is required; EXITING."
      exit 1
    fi
    read -rp "Does the S3/MinIO endpoint use a self-signed cert or plain http? (y/N): " s3_insecure_flag
    s3_insecure_flag=$(printf '%s' "$s3_insecure_flag" | tr '[:upper:]' '[:lower:]')
    s3_insecure="false"
    [[ "$s3_insecure_flag" == "y" ]] && s3_insecure="true"

    REPORT_OPTS+=(
      --set "reports.s3.enabled=true"
      --set "reports.s3.endpoint=$s3_endpoint"
      --set "reports.s3.bucket=$s3_bucket"
      --set "reports.s3.pathPrefix=$s3_prefix"
      --set "reports.s3.insecure=$s3_insecure"
      --set "reports.s3.accessKey=$s3_access_key"
      --set "reports.s3.secretKey=$s3_secret_key"
    )

    read -rp "Also keep a local PVC copy of each run's reports? (y/N): " keep_pvc
    keep_pvc=$(printf '%s' "$keep_pvc" | tr '[:upper:]' '[:lower:]')
    if [[ "$keep_pvc" != "y" ]]; then
      REPORT_OPTS+=(--set "reports.persistence.enabled=false")
    fi
  else
    echo ""
    echo "Where should reports (the consolidated HTML report) be stored?"
    echo "  1) New PVC, default storage class"
    echo "  2) New PVC on a specific storage class (e.g. nfs-csi)"
    echo "  3) Reuse an existing PVC"
    read -rp "Enter your choice [1-3]: " report_choice

    case "$report_choice" in
      2)
        read -rp "Storage class name: " storage_class
        if [[ -z "$storage_class" ]]; then
          echo "ERROR: Storage class name is required; EXITING."
          exit 1
        fi
        REPORT_OPTS+=(--set "reports.persistence.storageClass=$storage_class")
        ;;
      3)
        read -rp "Existing PVC name: " existing_claim
        if [[ -z "$existing_claim" ]]; then
          echo "ERROR: Existing PVC name is required; EXITING."
          exit 1
        fi
        REPORT_OPTS+=(--set "reports.persistence.existingClaim=$existing_claim")
        ;;
      *)
        : # default storage class, new PVC — no extra flags needed
        ;;
    esac
  fi

  echo ""
  echo "Installing $RELEASE_NAME in namespace $NS from $CHART_PATH ..."
  helm -n "$NS" upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
    -f values.yaml \
    --set triggerKind=cronjob \
    --set crontime="0 $time * * *" \
    --set apitestrig.surfaces="$SURFACES" \
    --set apitestrig.extraEnvVars.MOSIP_ESIGNET_BASE_URL="$MOSIP_ESIGNET_BASE_URL" \
    --set apitestrig.extraEnvVars.KEYCLOAK_TOKEN_URL="$KEYCLOAK_TOKEN_URL" \
    --set apitestrig.extraEnvVars.ESIGNET_TLS_VERIFY="$ESIGNET_TLS_VERIFY" \
    --set apitestrig.extraEnvVars.API_TLS_VERIFY="$API_TLS_VERIFY" \
    --set apitestrig.extraEnvVars.CONFORMANCE_BASE_URL="$CONFORMANCE_BASE_URL" \
    --set apitestrig.extraEnvVars.ID_TYPE="$ID_TYPE" \
    --set apitestrig.extraEnvVarsSecret.KEYCLOAK_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET" \
    --set apitestrig.extraEnvVarsSecret.INDIVIDUAL_ID="$INDIVIDUAL_ID" \
    "${REPORT_OPTS[@]}"

  echo "Installed $RELEASE_NAME."
}

installing_apitestrig
