# UITESTRIG

## Introduction
uitestrig runs the eSignet **UI** automation suite (`ui-test/`, Cucumber + TestNG + Selenium,
image `uitest-esignet`) on a schedule via CronJob, or on demand via Rancher/CLI. It installs via the
real `mosip/uitestrig` chart (source: [`mosip/mosip-functional-tests`, `helm/uitestrig`](https://github.com/mosip/mosip-functional-tests/tree/develop/helm/uitestrig)).

This is a **separate** installation from [`esignet-apitestrig`](../esignet-apitestrig), which runs the
API suite (`apitest-esignet`) via a different chart (`mosip/apitestrig`, from `mosip-helm`) with a
different values shape - don't copy `--set` flags between the two.

Unlike apitestrig, this module installs into its **own namespace** (`esignet-uitestrig`) rather than
the shared `esignet` namespace. The `uitestrig` chart's `configmaps.yaml`/`secrets.yaml` name
ConfigMaps/Secrets literally (`db`, `s3`, `uitestrig`, ...) rather than scoping them per-release, so a
second release in the same namespace as apitestrig (whose `apitestrig` chart does the same thing)
fails to install with a Helm ownership error on the shared `db` ConfigMap name. `install.sh` mirrors
in the read-only ConfigMaps/Secrets (`esignet-global`, `keycloak-host`, `keycloak-client-secrets`) the
job needs from `esignet` so this stays a one-command install.

Key differences from apitestrig that this module accounts for:

| Concern | apitestrig | uitestrig |
|---|---|---|
| Image | `apitest-esignet` | `uitest-esignet` |
| `modules` value shape | map keyed by module name (`modules.esignet.image...`) | **list** of `{name, enabled, image}` - `$module.name` drives the CronJob/container name, so a missing `name` renders an empty resource name and fails to install |
| Report path | `/home/mosip/testrig/report` | `/home/mosip/test-output` (+ `/home/mosip/screenshots`) |
| Plugin detection | via actuator | eSignet-go has no actuator - `pluginToExecute=mock` set explicitly |
| Browser | n/a | in-cluster Chromium only (`runOnBrowserStack=false`); no `/dev/shm` volume needed - `ui-test`'s `BaseTestUtil` already adds `--disable-dev-shm-usage`/`--no-sandbox` unconditionally |
| DB keys | `db-server`/`db-su-user`/`postgres-password` | `esignetDbHost`/`esignetDbPassword` only |
| Report storage | S3 or NFS PVC | **S3 only** - the `uitestrig` chart has no PVC/NFS template at all; without S3 the report only exists in the pod until it's garbage-collected |

## Install

* Review `values.yaml`. In particular confirm the `uitest-esignet` image repository/tag under
  `modules[0].image`.

* run `./install.sh`.
```
./install.sh
```

* The script will prompt for:
  * the hour to run the CronJob,
  * the relying-party `baseurl`, eSignet `eSignetbaseurl`, and `localeUrl`,
  * the Keycloak external URL,
  * whether the cluster has a public domain + valid SSL (selecting `n` mounts a self-signed
    `cacerts` init-container, same pattern as apitestrig),
  * S3 details for report storage (see the "Report storage" row above - there's no NFS fallback for
    this chart; declining just means you retrieve reports with `kubectl cp` before the pod is
    cleaned up).

## Uninstall
* To uninstall uitestrig, run `delete.sh`:
```sh
./delete.sh
```

## Run uitestrig manually

#### Rancher UI
* Run uitestrig manually via Rancher UI, the same way as apitestrig (see
  [`../esignet-apitestrig/README.md`](../esignet-apitestrig/README.md#run-apitestrig-manually) for
  screenshots), in the `esignet-uitestrig` namespace.
* Supported test levels: `smoke`, `smokeAndRegression` (default). To change it, update the
  `ENV_TESTLEVEL` key on the `uitestrig` ConfigMap and rerun the job.
* To scope a run further, set (and leave unset when not needed - see the "silent trap" note in
  `values.yaml`): `CUCUMBER_FILTER_TAGS`, `RUN_ONLY_SCENARIO`, `FEATURE_FILES_TO_EXECUTE`.

#### CLI
* Download the Kubernetes cluster `kubeconfig` file from the Rancher dashboard.
* Install `kubectl` on your local machine.
* Create a new job from the existing CronJob:
  ```
  kubectl --kubeconfig=<k8s-config-file> -n esignet-uitestrig create job --from=cronjob/<cronjob-name> <job-name>
  ```
  example:
  ```
  kubectl --kubeconfig=/home/xxx/Downloads/qa4.config -n esignet-uitestrig create job --from=cronjob/cronjob-esignet-uitestrig-esignet cronjob-esignet-uitestrig-esignet-manual
  ```

## Known gap

The `uitestrig` chart's `cronjob.yaml` doesn't set container `resources` (CPU/memory limits) at all
currently - there's no lever in this chart to give the Chromium+JVM pod more headroom than whatever
the cluster's namespace defaults provide. If pods get OOMKilled, that needs a chart-side fix in
`mosip-functional-tests`, not something `values.yaml` here can work around.
