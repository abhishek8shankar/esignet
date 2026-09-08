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
  kubectl -n $UITEST_NS delete --ignore-not-found=true configmap s3-esignet-uitestrig
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

  # In-cluster Chromium always (no BrowserStack path) - #2544 §6(ii).
  # runOnBrowserStack must be explicitly false since the JAR default is true.
  BROWSER_OPTION="--set uitestrig.configmaps.uitestrig.runOnBrowserStack=false --set dshm.enabled=true"

  # Report storage - #2544 §6(i). The UI harness pushes to S3 in-process
  # (BaseTest.pushReportsToS3), unlike the Go api-test harness.
  NFS_OPTION=''
  S3_OPTION=''
  config_complete=false
  while [ "$config_complete" = false ]; do
    read -p "Do you have S3 details for storing uitestrig reports? (Y/n) : " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
      read -p "Please provide S3 host: " s3_host
      if [[ -z $s3_host ]]; then
        echo "S3 host not provided; EXITING;"
        exit 1;
      fi
      read -p "Please provide S3 region: " s3_region
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
      S3_OPTION="--set uitestrig.configmaps.s3.s3-host=$s3_host --set uitestrig.secrets.s3.s3-user-key=$s3_user_key --set uitestrig.secrets.s3.s3-user-secret=$s3_user_secret --set uitestrig.configmaps.s3.s3-region=$s3_region"
      push_reports_to_s3="yes"
      config_complete=true
    elif [[ "$ans" == "n" || "$ans" == "N" ]]; then
      push_reports_to_s3="no"
      read -p "Since S3 details are not available, do you want to use NFS directory mount for storing reports? (y/n) : " answer
      if [[ $answer == "Y" ]] || [[ $answer == "y" ]]; then
        echo "Please select the storage class for NFS:"
        echo "1. nfs-client"
        echo "2. nfs-csi"
        read -p "Enter your choice (1 or 2): " storage_choice
        if [[ "$storage_choice" == "1" ]]; then
          storage_class="nfs-client"
        elif [[ "$storage_choice" == "2" ]]; then
          storage_class="nfs-csi"
        else
          echo "Invalid choice. Exiting"
          exit 1;
        fi
        read -p "Please provide NFS Server IP: " nfs_server
        if [[ -z $nfs_server ]]; then
          echo "NFS server not provided; EXITING."
          exit 1;
        fi
        # NOTE: mount is /home/mosip/test-output, NOT /home/mosip/testrig/report
        # like the API rig (#2544 §3.4, §5b).
        read -p "Please provide NFS directory to store reports from NFS server (e.g. /srv/nfs/mosip/<sandbox>/uitestrig/), make sure permission is 777 for the folder: " nfs_path
        if [[ -z $nfs_path ]]; then
          echo "NFS Path not provided; EXITING."
          exit 1;
        fi
        NFS_OPTION="--set uitestrig.volumes.reports.storageClass=$storage_class --set uitestrig.volumes.reports.nfs.server=$nfs_server --set uitestrig.volumes.reports.nfs.path=$nfs_path"
        config_complete=true
      else
        echo "Please rerun the script with either S3 or NFS server details."
        exit 1;
      fi
    else
      echo "Invalid input. Please respond with Y (yes) or N (no)."
    fi
  done

  read -p "Is values.yaml for uitestrig reviewed and set correctly as part of pre-requisites? (Y/n) : " yn;
  if [[ $yn = "Y" ]] || [[ $yn = "y" ]] ; then
    echo Installing esignet uitestrig
    helm -n $UITEST_NS install esignet-uitestrig mosip/uitestrig \
    --set crontime="0 $time * * *" \
    -f values.yaml \
    --version $CHART_VERSION \
    $NFS_OPTION \
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
