# apitestrig (eSignet, Go)

Helm chart to run the Go-based [`api-test`](../../api-test) harness against a
deployed eSignet instance, either on a schedule (`CronJob`) or as a one-off
run (`Job`).

Modeled on
[`mosip-functional-tests/helm/apitestrig`](https://github.com/mosip/mosip-functional-tests/tree/develop/helm/apitestrig),
adapted for this harness's single-image, single-binary, config-file-driven
design (see `api-test/Dockerfile` and `api-test/run-all.sh`) rather than the
Java testrig's one-image-per-module model.

## Prerequisites

- The eSignet deployment this rig targets must already be reachable from the
  cluster (`apitestrig.extraEnvVars.MOSIP_ESIGNET_BASE_URL`).
- If you plan to run the `conformance` surface, the OpenID Conformance Suite
  must already be running in-cluster (or otherwise reachable) — this chart
  does **not** deploy it. Point `apitestrig.extraEnvVars.CONFORMANCE_BASE_URL`
  at it.
- `helm dependency build` (pulls the Bitnami `common` chart used for labels
  and image-name helpers).

## Quick start

```bash
cd helm/apitestrig
helm dependency build

# One-off run against a deployed environment, api+e2e only
helm install apitestrig-smoke . \
  --set triggerKind=job \
  --set apitestrig.surfaces=api\\,e2e \
  --set apitestrig.extraEnvVars.MOSIP_ESIGNET_BASE_URL=https://esignet.example.net/v1/esignet \
  --set apitestrig.extraEnvVars.KEYCLOAK_TOKEN_URL=https://keycloak.example.net/realms/mosip/protocol/openid-connect/token \
  --set apitestrig.extraEnvVarsSecret.KEYCLOAK_CLIENT_SECRET=<secret>
```

```bash
# Nightly regression against the mosip config
helm install apitestrig . \
  --set apitestrig.extraEnvVars.MOSIP_ESIGNET_BASE_URL=https://esignet.example.net/v1/esignet \
  --set apitestrig.extraEnvVarsSecret.KEYCLOAK_CLIENT_SECRET=<secret>
```

## Configuration model

The image already bakes in `data/config/config.{mock,mosip,sunbird}.json` —
`apitestrig.configFile` just selects the in-image path (default:
`config.mosip.json`). Set `apitestrig.configOverride` only if you need a
config that isn't one of the shipped ones; it's rendered into a ConfigMap and
mounted instead.

Layering, matching `run-all.sh`'s own precedence (file → `config.local.json`
overlay → environment):

| Layer | Source | Values key |
|---|---|---|
| Base config | baked into image, or `configOverride` | `apitestrig.configFile` / `apitestrig.configOverride` |
| Credentials overlay | mounted Secret, at `CONFIG_LOCAL` | `apitestrig.configLocal.*` |
| Non-secret overrides | container env | `apitestrig.extraEnvVars` |
| Secret overrides | container env via `secretKeyRef` | `apitestrig.extraEnvVarsSecret` |
| Shared cluster config/secrets | `envFrom` | `apitestrig.extraEnvVarsCM` / `extraEnvVarsSecretRefs` |

`apitestrig.configLocal.existingSecret` lets you supply the overlay via a
Secret you manage outside Helm (sealed-secrets, external-secrets, etc.)
instead of `apitestrig.configLocal.data` in values.

## Reports

`REPORT_DIR` is set to `reports.mountPath` (default `/app/out`). By default
it's backed by a PVC (`reports.persistence`) — set
`reports.persistence.existingClaim` to reuse a PVC across runs.

To also (or instead) push each run's report to S3-compatible storage (AWS S3
or MinIO), set `reports.s3.enabled: true` plus `reports.s3.endpoint`,
`.bucket`, and credentials (`reports.s3.accessKey`/`secretKey`, or
`reports.s3.existingSecret` to supply your own Secret). This adds a second
`report-uploader` container to the pod that waits for the harness to finish
(run-all.sh has no S3 awareness of its own, so completion is signalled via a
marker file on the shared reports volume) and then runs `mc cp` to upload
everything under `reports.s3.pathPrefix/<UTC timestamp>/` in the bucket. Set
`reports.persistence.enabled: false` if you don't want a PVC kept around once
reports are pushed to S3 — the reports volume becomes an `emptyDir` instead.

```bash
helm upgrade --install apitestrig . \
  --set reports.s3.enabled=true \
  --set reports.s3.endpoint=http://minio.minio:9000 \
  --set reports.s3.bucket=apitestrig-reports \
  --set reports.s3.accessKey=<key> \
  --set reports.s3.secretKey=<secret> \
  --set reports.persistence.enabled=false   # optional: skip the PVC entirely
```

## CronJob vs Job

- `triggerKind: cronjob` (default) — scheduled via `crontime`, mirrors the
  reference chart's nightly-run model.
- `triggerKind: job` — a single run per `helm install`/`helm upgrade`, handy
  for CI-triggered smoke tests against a freshly-deployed environment. The Job
  name is suffixed with `.Release.Revision` so repeated `helm upgrade` calls
  don't collide with an already-completed Job.
