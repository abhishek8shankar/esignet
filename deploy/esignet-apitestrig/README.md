# eSignet API Test Rig (Go)

## Introduction
Runs the Go-based [`api-test`](../../api-test) harness against the eSignet
deployment in this cluster, via the [`../../helm/apitestrig`](../../helm/apitestrig)
chart.

This replaces the previous Java-testrig wrapper, which installed the
published `mosip/apitestrig` chart with `modules.esignet.enabled=true`. The
Go harness ships as a single image rather than one image per MOSIP module,
so this script drives the local chart directly.

`install.sh` prompts for the test identity and which surfaces to run (see
below) and passes them straight through as `--set` overrides — you don't
need to hand-edit `apitestrig.configFile`'s own `run.surfaces` for a normal
install.

If you pick the `conformance,api,e2e` surface set, note that `conformance`
also needs a private plan config this chart doesn't mount by default (see
`apitestrig.conformancePlanConfig` in the chart's README) on top of a
reachable `CONFORMANCE_BASE_URL` — without both it fails with a
`config_file ... not readable` error (see
[mosip/esignet#2434](https://github.com/mosip/esignet/issues/2434)).

## Prerequisites
- `kubectl` and `helm` installed locally.
- eSignet already deployed and reachable (in this namespace, or elsewhere —
  you'll be prompted for its base URL).
- If the selected config runs the `conformance` surface, the OpenID
  Conformance Suite must already be deployed and reachable — this chart does
  **not** deploy it.

## Install
```sh
./install.sh
```
You'll be prompted for:
- the eSignet base URL (defaults from the `esignet-global` configmap's
  `mosip-esignet-host` if eSignet is deployed in the same `esignet`
  namespace),
- the Keycloak token URL and client secret for the test client, plus an
  optional client ID override if the config default (`mosip-pms-client`)
  isn't the right admin client for this environment,
- whether eSignet's certificate is self-signed (sets `ESIGNET_TLS_VERIFY` /
  `API_TLS_VERIFY` to `false` instead of importing a certificate — the Go
  harness needs no Java keystore/`cacerts` step),
- the test identity (`INDIVIDUAL_ID`, kept out of ConfigMaps as a Secret
  value since it's PII, and `ID_TYPE`),
- OTP and PMS settings the mosipid plugin needs and `config.mosip.json`
  ships blank (`OTP_WS_URL`, `OTP_RECIPIENT_EMAIL`, `PMS_BASE_URL`,
  `AUTH_PARTNER_ID`, `AUTH_POLICY_ID` — see the config file's own `_comment`
  block and [mosip/esignet#2434](https://github.com/mosip/esignet/issues/2434)
  §4),
- which surfaces to run (`api,e2e`, or `conformance,api,e2e` plus the
  conformance suite's base URL),
- the cron schedule,
- where to persist the consolidated HTML report: S3/MinIO (endpoint, bucket,
  path prefix, credentials — uploaded after each run via a second container
  that waits for the harness to finish), or if you skip that, a PVC (new,
  new on a named storage class, or an existing one).

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
