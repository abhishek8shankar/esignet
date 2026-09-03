# eSignet API Test Rig (Go)

## Introduction
Runs the Go-based [`api-test`](../../api-test) harness against the eSignet
deployment in this cluster, via the [`../../helm/apitestrig`](../../helm/apitestrig)
chart.

This replaces the previous Java-testrig wrapper, which installed the
published `mosip/apitestrig` chart with `modules.esignet.enabled=true`. The
Go harness ships as a single image rather than one image per MOSIP module,
so this script drives the local chart directly.

Which test surfaces run (`conformance`/`api`/`e2e`) and the test identity
used are controlled by the selected `apitestrig.configFile` (see
`values.yaml`) rather than by this script — edit that config, or set
`apitestrig.surfaces`/the relevant `apitestrig.extraEnvVars` yourself via an
extra `--set` if you need to override it for a specific install.

`values.yaml` here pins `apitestrig.surfaces: "api,e2e"` by default:
`config.mosip.json`'s own default includes `conformance`, which needs a
private plan config this chart doesn't mount unless you set up
`apitestrig.conformancePlanConfig` (see the chart's README) and a reachable
`CONFORMANCE_BASE_URL` — without both, running with `conformance` in the
surface list fails with a `config_file ... not readable` error (see
[mosip/esignet#2434](https://github.com/mosip/esignet/issues/2434)). Set
`apitestrig.surfaces: ""` in `values.yaml` once that's wired up, to fall back
to the config file's own surface list.

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
- the Keycloak token URL and client secret for the test client,
- whether eSignet's certificate is self-signed (sets `ESIGNET_TLS_VERIFY` /
  `API_TLS_VERIFY` to `false` instead of importing a certificate — the Go
  harness needs no Java keystore/`cacerts` step),
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
