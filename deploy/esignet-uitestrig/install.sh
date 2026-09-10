#!/bin/bash
# Installs uitestrig (uitest-esignet UI automation harness)
## Usage: ./install.sh [kubeconfig]
#
# See mosip/esignet#2544 for the full gap analysis this script and values.yaml
# are based on. This installs a SEPARATE release (esignet-uitestrig) from
# esignet-apitestrig so the two CronJobs never share image/command/resources
# (#2544 §6iii).
#
# uitestrig is installed into its OWN namespace (UITEST_NS below), not the
# shared "esignet" namespace apitestrig lives in. The generic testrig chart
# family hardcodes some ConfigMap names (e.g. "db") rather than scoping them
# per-release, so installing both apitestrig and uitestrig into the same
# namespace fails with a Helm ownership conflict ("ConfigMap \"db\" ... exists
# and cannot be imported ... current value is \"esignet-apitestrig\""). A
# dedicated namespace sidesteps that instead of fighting over ownership of a
# ConfigMap the apitestrig release already owns.

if [ $# -ge 1 ] ; then
  export KUBECONFIG=$1
fi

SOURCE_NS=esignet
UITEST_NS=esignet-uitestrig
CHART_VERSION=0.0.1-develop
COPY_UTIL=../copy_cm_func.sh

# CHANGED: small helper to pull a scalar value out of values.yaml so the
# interactive prompts below can default to whatever's already committed
# there, instead of always forcing a fresh answer that gets --set on top of
# it (which is what silently overrode push-reports-to-s3 before - editing
# the YAML file had no effect because this script's own --set always won).
# Only handles simple "key: value" / "key: \"value\"" lines, which is all
# this file uses - not a general YAML parser.
yaml_val() {
  local key="$1"
  grep -m1 -E "^[[:space:]]*${key}:" values.yaml \
    | sed -E "s/^[^:]+:[[:space:]]*['\"]?([^'\"]*)['\"]?[[:space:]]*\$/\1/"
}

echo Create $UITEST_NS namespace
kubectl create ns $UITEST_NS

function installing_uitestrig() {
  helm repo update

  echo "Mirroring shared ConfigMaps/Secrets from $SOURCE_NS into $UITEST_NS"
  # These are read directly by the job via extraEnvVarsCM/extraEnvVarsSecret
  # in values.yaml, so they must exist in the same namespace as the job -
  # they are NOT copied into apitestrig's namespace, so there's no ownership
  # clash with the apitestrig release.
  $COPY_UTIL configmap esignet-global $SOURCE_NS $UITEST_NS
  kubectl -n $SOURCE_NS get configmap keycloak-host >/dev/null 2>&1 && \
    $COPY_UTIL configmap keycloak-host $SOURCE_NS $UITEST_NS
  kubectl -n $SOURCE_NS get secret keycloak-client-secrets >/dev/null 2>&1 && \
    $COPY_UTIL secret keycloak-client-secrets $SOURCE_NS $UITEST_NS

  echo "Delete uitestrig-owned s3/uitestrig configmaps in $UITEST_NS if they exist from a previous run"
  kubectl -n $UITEST_NS delete --ignore-not-found=true configmap s3
  kubectl -n $UITEST_NS delete --ignore-not-found=true configmap uitestrig

  API_INTERNAL_HOST=$( kubectl -n $SOURCE_NS get cm esignet-global -o json | jq -r '.data."mosip-api-internal-host"' )
  ENV_USER=$( kubectl -n $SOURCE_NS get cm esignet-global -o json | jq -r '.data."mosip-api-internal-host"' | awk -F '.' '/api-internal/{print $1"."$2}')

  read -p "Please enter the time(hr) to run the cronjob every day (time: 0-23) : " time
  if [ -z "$time" ]; then
     echo "ERROR: Time cannot be empty; EXITING;";
     exit 1;
  fi
  if ! [ $time -eq $time ] 2>/dev/null; then
     echo "ERROR: Time $time is not a number; EXITING;";
     exit 1;
  fi
  if [ $time -gt 23 ] || [ $time -lt 0 ] ; then
     echo "ERROR: Time should be in range ( 0-23 ); EXITING;";
     exit 1;
  fi

  read -p "Please provide the relying-party base URL (baseurl), e.g. https://healthservices-go.<env>.mosip.net/ : " baseurl
  if [ -z "$baseurl" ]; then
    echo "baseurl not provided; EXITING;"
    exit 1;
  fi

  read -p "Please provide the eSignet base URL (eSignetbaseurl), e.g. https://esignet-go.<env>.mosip.net : " esignetbaseurl
  if [ -z "$esignetbaseurl" ]; then
    echo "eSignetbaseurl not provided; EXITING;"
    exit 1;
  fi

  read -p "Please provide the locale/i18n URL (localeUrl) [default: same as eSignetbaseurl] : " localeurl
  if [ -z "$localeurl" ]; then
    localeurl=$esignetbaseurl
  fi

  read -p "Please provide the Keycloak external URL (keycloak-external-url), e.g. https://iam.<env>.mosip.net : " keycloakUrl
  if [ -z "$keycloakUrl" ]; then
    echo "keycloak-external-url not provided; EXITING;"
    exit 1;
  fi

  echo "Do you have public domain & valid SSL? (Y/n) "
  echo "Y: if you have public domain & valid ssl certificate"
  echo "n: If you don't have a public domain and a valid SSL certificate. Note: It is recommended to use this option only in development environments."
  read -p "" flag

  if [ -z "$flag" ]; then
    echo "'flag' was not provided; EXITING;"
    exit 1;
  fi
  ENABLE_INSECURE=''
  if [ "$flag" = "n" ]; then
    ENABLE_INSECURE='--set enable_insecure=true';
  fi

  # In-cluster Chromium always (no BrowserStack path). runOnBrowserStack must
  # be explicitly false since the JAR default is true. No /dev/shm volume is
  # needed: ui-test's BaseTestUtil already adds --disable-dev-shm-usage
  # unconditionally, and the chart's cronjob.yaml doesn't support mounting
  # one anyway (checked against the real chart source - see values.yaml).
  BROWSER_OPTION="--set uitestrig.configmaps.uitestrig.runOnBrowserStack=false"

  # Report storage: the uitestrig chart (mosip/mosip-functional-tests,
  # helm/uitestrig) has no PVC/NFS volume support at all - S3 is the only
  # storage path it can actually plumb through (ui-test's own in-process
  # BaseTest.pushReportsToS3). If you skip S3, the Extent report only exists
  # inside the pod's /home/mosip/test-output and is lost once the CronJob's
  # completed pod is garbage-collected, unless you kubectl cp it out first.
  #
  # CHANGED: default this prompt off whatever's already in values.yaml
  # instead of always resetting it. Previously this script hardcoded
  # push_reports_to_s3 from a *fresh* y/n answer every run and passed it via
  # --set, which unconditionally beats -f values.yaml - so editing
  # push-reports-to-s3 in values.yaml directly did nothing on the next
  # install.sh run. Now: values.yaml is the source of truth for the default,
  # and this prompt only lets you override it for this run if you want to.
  S3_OPTION=''
  default_push_reports_to_s3="$(yaml_val push-reports-to-s3)"
  default_s3_host="$(yaml_val s3-host)"
  default_s3_region="$(yaml_val s3-region)"

  case "$default_push_reports_to_s3" in
    [Yy]es) default_ans="Y" ;;
    *)      default_ans="n" ;;
  esac

  read -p "Do you have S3 details for storing uitestrig reports? (Y/n) [values.yaml currently: ${default_push_reports_to_s3:-unset}, default: $default_ans] : " ans
  if [ -z "$ans" ]; then
    ans="$default_ans"
  fi

  if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
    read -p "Please provide S3 host${default_s3_host:+ [default: $default_s3_host]}: " s3_host
    if [ -z "$s3_host" ]; then
      s3_host="$default_s3_host"
    fi
    if [[ -z $s3_host ]]; then
      echo "S3 host not provided; EXITING;"
      exit 1;
    fi
    read -p "Please provide S3 region${default_s3_region:+ [default: $default_s3_region]}: " s3_region
    if [ -z "$s3_region" ]; then
      s3_region="$default_s3_region"
    fi
    if [[ $s3_region == *[' !@#$%^&*()+']* ]]; then
      echo "S3 region should not contain spaces or special characters; EXITING;"
      exit 1;
    fi
    read -p "Please provide S3 access key: " s3_user_key
    if [[ -z $s3_user_key ]]; then
      echo "S3 access key not provided; EXITING;"
      exit 1;
    fi
    read -p "Please provide S3 secret key: " s3_user_secret
    if [[ -z $s3_user_secret ]]; then
      echo "S3 secret key not provided; EXITING;"
      exit 1;
    fi
    S3_OPTION="--set uitestrig.configmaps.s3.s3-host=$s3_host --set uitestrig.secrets.uitestrig.s3-user-key=$s3_user_key --set uitestrig.secrets.uitestrig.s3-user-secret=$s3_user_secret --set uitestrig.configmaps.s3.s3-region=$s3_region"
    push_reports_to_s3="yes"
  else
    push_reports_to_s3="no"
    echo "Proceeding without S3. Reports will only be retrievable via 'kubectl cp' from the pod before it's garbage-collected."
  fi

  read -p "Is values.yaml for uitestrig reviewed and set correctly as part of pre-requisites? (Y/n) : " yn;
  if [[ $yn = "Y" ]] || [[ $yn = "y" ]] ; then
    echo Installing esignet uitestrig
    helm -n $UITEST_NS install esignet-uitestrig mosip/uitestrig \
    --set crontime="0 $time * * *" \
    -f values.yaml \
    --version $CHART_VERSION \
    $S3_OPTION \
    $BROWSER_OPTION \
    --set uitestrig.configmaps.uitestrig.push-reports-to-s3=$push_reports_to_s3 \
    --set uitestrig.configmaps.uitestrig.ENV_USER="$ENV_USER" \
    --set uitestrig.configmaps.uitestrig.ENV_ENDPOINT="https://$API_INTERNAL_HOST" \
    --set uitestrig.configmaps.uitestrig.MODULES="esignet" \
    --set uitestrig.configmaps.uitestrig.ENV_TESTLEVEL="smokeAndRegression" \
    --set uitestrig.configmaps.uitestrig.baseurl="$baseurl" \
    --set uitestrig.configmaps.uitestrig.eSignetbaseurl="$esignetbaseurl" \
    --set uitestrig.configmaps.uitestrig.localeUrl="$localeurl" \
    --set uitestrig.configmaps.uitestrig.keycloak-external-url="$keycloakUrl" \
    --set uitestrig.configmaps.uitestrig.NS="$UITEST_NS" \
    $ENABLE_INSECURE

    echo Installed esignet uitestrig.
    return 0
  fi
}

# set commands for error handling.
set -e
set -o errexit   ## set -e : exit the script if any statement returns a non-true return value
set -o nounset   ## set -u : exit the script if you try to use an uninitialised variable
set -o errtrace  # trace ERR through 'time command' and other functions
set -o pipefail  # trace ERR through pipes
installing_uitestrig   # calling function
