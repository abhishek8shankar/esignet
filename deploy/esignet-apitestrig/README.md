# eSignet API Test Rig (Go)

## Introduction
Runs the Go-based [`api-test`](../../api-test) harness against the eSignet
deployment in this cluster, via the [`../../helm/apitestrig`](../../helm/apitestrig)
chart.

This replaces the previous Java-testrig wrapper, which installed the
published `mosip/apitestrig` chart with `modules.esignet.enabled=true`. The
Go harness ships as a single image with selectable **surfaces**
(`conformance`, `api`, `e2e`) rather than one image per MOSIP module, so this
script drives the local chart directly.

## Prerequisites
- `kubectl` and `helm` installed locally.
- eSignet already deployed and reachable (in this namespace, or elsewhere —
  you'll be prompted for its base URL).
- A pre-provisioned test identity (UIN/VID/phone/email) to drive the `e2e`
  and `api` surfaces.
- If you intend to run the `conformance` surface, the OpenID Conformance
  Suite must already be deployed and reachable — this chart does **not**
  deploy it.

## Install
```sh
./install.sh
```
You'll be prompted for:
- the eSignet base URL (defaults from the `esignet-global` configmap's
  `mosip-esignet-host` if eSignet is deployed in the same `esignet`
  namespace),
- the Keycloak token URL and client secret for the test client,
- the test identity (`INDIVIDUAL_ID` / `ID_TYPE`),
- which surfaces to run (`api,e2e`, or `conformance,api,e2e` plus the
  conformance suite's base URL),
- whether eSignet's certificate is self-signed (sets `ESIGNET_TLS_VERIFY` /
  `API_TLS_VERIFY` to `false` instead of importing a certificate — the Go
  harness needs no Java keystore/`cacerts` step),
- the cron schedule,
- where to persist the consolidated HTML report (new PVC, new PVC on a
  named storage class, or an existing PVC).

Review `values.yaml` first if you want to change the baked-in config profile
(`apitestrig.configFile`, default `config.mosip.json`) or default resource
requests/limits.

## Uninstall
```sh
./delete.sh
```

## Run manually

#### Rancher UI
Trigger the CronJob's job manually from the Rancher UI, same as any other
CronJob.

#### CLI
```sh
kubectl --kubeconfig=<k8s-config-file> -n esignet create job \
  --from=cronjob/esignet-apitestrig <job-name>
```

Reports land in the PVC configured above at `/app/out` inside the pod:
```sh
kubectl -n esignet cp <pod-name>:/app/out ./out
```
