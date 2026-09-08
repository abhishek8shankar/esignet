# UITESTRIG

## Introduction
uitestrig runs the eSignet **UI** automation suite (`ui-test/`, Cucumber + TestNG + Selenium,
image `uitest-esignet`) on a schedule via CronJob, or on demand via Rancher/CLI.

This is a **separate** installation from [`esignet-apitestrig`](../esignet-apitestrig), which runs the
API suite (`apitest-esignet`). The two use different container contracts (see
[mosip/esignet#2544](https://github.com/mosip/esignet/issues/2544) for the full gap analysis) and are
kept as separate releases/CronJobs so neither shares image, command, or resources with the other.

Key differences from apitestrig that this module accounts for:

| Concern | apitestrig | uitestrig |
|---|---|---|
| Image | `apitest-esignet` | `uitest-esignet` |
| Resources | ~300m CPU / 500Mi | 500m–2 CPU / 2–4Gi memory (headless Chromium + JVM) |
| `/dev/shm` | not needed | required, `emptyDir` memory volume, 2Gi |
| Report path | `/home/mosip/testrig/report` | `/home/mosip/test-output` (+ `/home/mosip/screenshots`) |
| Plugin detection | via actuator | eSignet-go has no actuator - `pluginToExecute=mock` set explicitly |
| Browser | n/a | in-cluster Chromium only (`runOnBrowserStack=false`) |
| DB keys | `db-server`/`db-su-user`/`postgres-password` | `esignetDbHost`/`esignetDbPassword` only |

## Install

There are two ways to store reports:

S3 Storage – Run the install script directly and provide the required S3 configuration values.

NFS Storage – Create the necessary directory on the NFS server and then proceed with the installation.

* Create a directory for uitestrig on the NFS server at `/srv/nfs/mosip/<sandbox>/uitestrig/`:
```
mkdir -p /srv/nfs/mosip/<sandbox>/uitestrig/
```
* Ensure the directory has 777 permissions:
```
chmod 777 /srv/nfs/mosip/<sandbox>/uitestrig
```
* Add the following entry to the /etc/exports file:
```
/srv/nfs/mosip/<sandbox>/uitestrig *(rw,sync,no_root_squash,no_all_squash,insecure,subtree_check)
```
* Apply export command
```
sudo exportfs -rav
```
* Restart the nfs-server
```
sudo systemctl restart nfs-kernel-server
```
* Once the nfs-kernel-server is up, log out from the NFS server and continue the deployment from your local machine.

* Review `values.yaml`. In particular confirm the `uitest-esignet` image repository/tag, and that
  the `modules.esignet`/`uitestrig` keys below line up with whatever the `mosip/uitestrig` chart
  currently exposes (see **Known gap** below).

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
  * Chrome runs in-cluster only (`runOnBrowserStack=false`, `/dev/shm` mounted) - no BrowserStack
    prompt or credentials needed,
  * S3 or NFS for report storage.

* If the report is stored in NFS, use `scp` to copy the reports (`/home/mosip/test-output/*.html`,
  `/home/mosip/screenshots/`) to your local machine.

## Uninstall
* To uninstall uitestrig, run `delete.sh`:
```sh
./delete.sh
```

## Run uitestrig manually

#### Rancher UI
* Run uitestrig manually via Rancher UI, the same way as apitestrig (see
  [`../esignet-apitestrig/README.md`](../esignet-apitestrig/README.md#run-apitestrig-manually) for
  screenshots).
* Supported test levels: `smoke`, `smokeAndRegression` (default). To change it, update the
  `ENV_TESTLEVEL` key on the `uitestrig` ConfigMap and rerun the job.
* To scope a run further, set (and leave unset when not needed - see the "silent trap" note in
  `values.yaml`): `CUCUMBER_FILTER_TAGS`, `RUN_ONLY_SCENARIO`, `FEATURE_FILES_TO_EXECUTE`.

#### CLI
* Download the Kubernetes cluster `kubeconfig` file from the Rancher dashboard.
* Install `kubectl` on your local machine.
* Create a new job from the existing CronJob:
  ```
  kubectl --kubeconfig=<k8s-config-file> -n esignet create job --from=cronjob/<cronjob-name> <job-name>
  ```
  example:
  ```
  kubectl --kubeconfig=/home/xxx/Downloads/qa4.config -n esignet create job --from=cronjob/cronjob-uitestrig-esignet cronjob-uitestrig-esignet-manual
  ```

## Known gap

This module installs via a dedicated `mosip/uitestrig` chart rather than reusing `mosip/apitestrig`
(from [`mosip/mosip-functional-tests`](https://github.com/mosip/mosip-functional-tests)), per the
decision in [mosip/esignet#2544](https://github.com/mosip/esignet/issues/2544) §6(iii): API and UI
runs get their own chart/release so neither shares image, command, or resources with the other.

`values.yaml`/`install.sh` here set the keys the UI harness needs (own image, Chromium resources,
`/dev/shm`, `/home/mosip/test-output` mount) using names that mirror `apitestrig`'s existing
conventions, on the assumption `uitestrig` is built as a sibling chart of the same shape. Confirm the
actual key names against the published `mosip/uitestrig` chart once it exists, and that it actually
honours the `/dev/shm` mount and the `/home/mosip/test-output` report `mountDir` - the chart-side work
itself (in `mosip-functional-tests`) is tracked by #2544 and is not part of this repo.
