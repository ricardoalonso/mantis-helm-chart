# mantis

A Helm chart for [MantisBT](https://www.mantisbt.org/) on OpenShift and Kubernetes,
using the image built by
[mantis-container](https://github.com/ricardoalonso/mantis-container)
(Apache 2.4 + PHP-FPM on Rocky Linux 9, with local patches).

It installs MantisBT with either **MariaDB** or **PostgreSQL**, in one of three
modes:

| `database.mode` | MariaDB | PostgreSQL |
|---|---|---|
| `standalone` | one pod, `quay.io/sclorg/mariadb-1011-c9s` | one pod, `quay.io/sclorg/postgresql-16-c9s` |
| `operator` | 3-node **Galera** cluster via [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator) | 1 primary + 2 replicas via [CloudNativePG](https://cloudnative-pg.io) |
| `external` | a server you run | a server you run |

The schema is installed on first install and upgraded on every `helm upgrade`
by a Job. You don't need the web installer, and the admin pages stay disabled.

## Quick start

```sh
# MariaDB in a single pod
helm install mantis ./charts/mantis -f examples/mariadb-standalone.yaml

# PostgreSQL, highly available (CloudNativePG must be installed)
helm install mantis ./charts/mantis -f examples/postgresql-cnpg.yaml
```

The schema Job runs for a few minutes: longer with an operator, since it waits
for the cluster to come up. Then:

```sh
oc get route mantis -o jsonpath='https://{.spec.host}/mantis/{"\n"}'
oc get secret mantis-app -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Log in as `administrator` with that password, then change it. The chart sets
it once, on the install that creates the account, and never again.

The `examples/` directory has a values file for each combination. They set
`storageClass: ocs-storagecluster-cephfs` for attachments; change it to any
ReadWriteMany class on your cluster.

## Operators

The chart **does not install operators**. It only creates the `MariaDB` or
`Cluster` resource. If the operator's CRDs are missing, rendering fails with
a message saying so. You can't install an operator from inside a namespace;
a cluster administrator has to do it.

### PostgreSQL: CloudNativePG

Install it from OperatorHub ("CloudNativePG", community) in all namespaces.
It has been tested with CloudNativePG 1.30.

### MariaDB: mariadb-operator

Of the MariaDB operators in OperatorHub, this chart targets the community
**mariadb-operator** (`k8s.mariadb.com/v1alpha1`), which is free and has
first-class Galera support. The alternatives are the MariaDB Enterprise
operator, which needs an Enterprise subscription, and Percona XtraDB Cluster,
which is MySQL rather than MariaDB.

The OperatorHub package is a Helm-based wrapper, so installing it takes two
steps: the Subscription, then a `MariadbOperator` resource that deploys the
operator itself.

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mariadb-operator
  namespace: openshift-operators
spec:
  channel: alpha
  name: mariadb-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
---
# Once the Subscription's CSV has succeeded. Without this resource only the
# Helm wrapper runs, and MariaDB resources are never reconciled.
apiVersion: helm.mariadb.mmontes.io/v1alpha1
kind: MariadbOperator
metadata:
  name: mariadb-operator
  namespace: openshift-operators
spec:
  ha:
    enabled: true
  webhook:
    cert:
      certManager:
        enabled: true   # cert-manager is optional; drop this block without it
```

Upstream also publishes plain Helm charts (`mariadb-operator-crds` and
`mariadb-operator`) as an alternative to OLM.

Tested with mariadb-operator 26.10.1 on OKD 4.22. The Galera pods run under
the default `restricted-v2` SCC with no extra settings. The chart pins
MariaDB **11.8 LTS** (`mariadb.operator.image`) instead of the operator's
default, which is the newest rolling release and changes with operator
upgrades.

MantisBT connects to the `<name>-primary` Service. Galera accepts writes on
every node, but sending them all to one avoids certification conflicts.

## High availability

With `replicaCount > 1` (the default is 2):

- **Attachments** must be on ReadWriteMany storage (CephFS, NFS, ...). The
  chart refuses to render otherwise. With ReadWriteOnce and one replica, it
  switches the Deployment to `Recreate`, because a rolling update would hang
  on the volume.
- **Sessions** are per pod. MantisBT's login is cookie-based and works on any
  pod, but its form tokens live in the PHP session. The OpenShift Route pins
  each browser to one pod with a cookie. If that pod goes away, a form that
  was open at the time fails once with "Invalid form security token". For an
  Ingress, enable cookie affinity on your controller.
- A **PodDisruptionBudget** keeps at least one pod up during node drains, and
  pods prefer different nodes.

Tested on OKD 4.22 by deleting the database primary pod. MantisBT served
errors for about 2 seconds with CloudNativePG and about 5 seconds with
Galera, then recovered without a restart.

With Galera, IDs go up in steps of the cluster size (`auto_increment_increment`),
so a new install's first project or issue is not necessarily #1. This is
normal and harmless.

## Configuration

`config_inc.php` is generated from values and mounted read-only at
`/mantis/config`. It doesn't contain credentials: those are read at runtime
from Secrets mounted under `/mantis/secrets`.

For anything the chart doesn't expose, use `mantis.extraConfig`. It's PHP
appended after everything the chart sets, so it can override any of it:

```yaml
mantis:
  extraConfig: |
    $g_window_title = 'ACME Bugs';
    $g_allow_signup = OFF;
```

`mantis.extraConfigFiles` adds more files to the config folder, such as
`custom_strings_inc.php`.

A custom logo and favicon go in `mantis.customImages`, served under
`<contextPath>/images/custom/` (the config folder is not served over HTTP), so
no image rebuild is needed. The simplest way is a ConfigMap you create:

```sh
oc create configmap mantis-images --from-file=logo.jpg --from-file=favicon.ico
```

```yaml
mantis:
  customImages:
    existingConfigMap: mantis-images
  extraConfig: |
    $g_logo_image = 'images/custom/logo.jpg';
    $g_favicon_image = 'images/custom/favicon.ico';
```

Or keep them in the release, base64-encoded in `mantis.customImages.files`:

```sh
helm upgrade mantis charts/mantis -f values.yaml \
  --set-file 'mantis.customImages.files.logo\.jpg'=<(base64 -w0 logo.jpg) \
  --set-file 'mantis.customImages.files.favicon\.ico'=<(base64 -w0 favicon.ico)
```

Pods roll automatically when the generated config changes.

### URL

MantisBT is served at `mantis.contextPath`, `/mantis` by default, which keeps
the URLs of chart 0.1.x. Set it to `/` to serve MantisBT at the root of the
host. With anything else, `/` redirects to it. `mantis.url` and the readiness
probe follow it.

### TLS certificate

By default the Route serves the router's wildcard certificate. For a
certificate of your own host, choose one of these:

**cert-manager** issues and renews it. Any issuer that can validate the host
works; DNS-01 doesn't need the host to be reachable from outside.

```yaml
route:
  host: mantis.example.com
certManager:
  enabled: true
  issuerRef:
    name: letsencrypt-prod      # oc get clusterissuers
```

The chart creates a `Certificate` for the host (plus
`certManager.extraDnsNames`). With a Route, it serves the resulting Secret
through `spec.tls.externalCertificate`. With an Ingress, it uses it as the
Ingress's TLS Secret. Renewals reach the router within seconds, without
touching the Route.

OpenShift refuses a Route whose `externalCertificate` Secret doesn't exist,
and cert-manager only writes it once the certificate is issued. So with a
Route the chart first creates that Secret with a self-signed certificate for
the host, and cert-manager overwrites it. The first install therefore
serves a self-signed certificate for a minute or two, until
`oc get certificate` shows `Ready`. Upgrades read the Secret back and leave
the issued certificate alone, and it is kept on uninstall, as cert-manager
does. See [Credentials and GitOps](#credentials-and-gitops) for Argo CD.

**Your own certificate in a Secret:**

```sh
oc create secret tls mantis-tls --cert=fullchain.pem --key=privkey.pem
```

```yaml
route:
  host: mantis.example.com
  tlsSecret: mantis-tls
```

Replacing the Secret's contents later is enough to roll the certificate.
For an Ingress, name the Secret in `ingress.tls` instead.

**Inline**, in `route.tls.certificate`, `key` and `caCertificate` as PEM.
This puts the key in the Helm release, so prefer one of the above.

With a Secret (cert-manager or `route.tlsSecret`), the router reads it
directly. The chart creates a Role and RoleBinding that let the router's
service account (`openshift-ingress/router`) read that one Secret, as
OpenShift requires for `externalCertificate` (4.16 and later). The Secret
must be in the release's namespace, and termination must be `edge` or
`reencrypt`.

### LDAP / Active Directory

```yaml
mantis:
  ldap:
    enabled: true
    server: ldap://dc.example.local
    rootDn: DC=example,DC=local
    bindDn: mantis@EXAMPLE
    bindPassword: ...        # or `ldap-bind-password` in mantis.existingSecret
    uidField: sAMAccountName
    useStarttls: false
    useRealname: true
```

### Single sign-on (OpenID Connect)

The image speaks OpenID Connect through Apache's mod_auth_openidc and its own
`OidcAuth` plugin. Users are sent to the identity provider on login. Accounts
are matched by `usernameClaim` and created on first login. The accounts in
`localUsers` keep the password form at `<url>/login_page.php?local=1`, for when
the identity provider is down.

```yaml
mantis:
  oidc:
    enabled: true
    issuer: https://sso.example.com/realms/mantis
    clientId: mantis
    existingSecret: mantis-oidc      # key: client-secret
```

At the identity provider, register a confidential client with the redirect
URI `<public URL>/oidc/callback` and the post-logout redirect URI
`<public URL>/login_page.php`. The install notes print both. The redirect URI
is built from `X-Forwarded-Proto` and `X-Forwarded-Host`, which the image
trusts from `mantis.httpd.trustedProxies`.

The cookies mod_auth_openidc uses during login are encrypted with a passphrase
that must be the same on every replica. The chart generates one and keeps it
in its Secret (`oidc-crypto-passphrase`), so a login can finish on any pod.
With `mantis.existingSecret`, add that key yourself (32 characters or more,
without `"`, `\` or `$`).

Details and identity-provider walkthroughs: `README-authentication.md` in the
image (`podman run --rm quay.io/ricardoalonsos/mantis:2.28.4 cat
/usr/share/doc/mantis-container/README-authentication.md`).

### Plugins

The image's plugins (MantisBT's own and `OidcAuth`) are always there. Add
others as archives pinned by SHA-256. Each pod downloads them into its own
`emptyDir` when it starts, so pods never change files under each other:

```yaml
mantis:
  plugins:
    archives:
      - url: https://github.com/mantisbt-plugins/Snippets/archive/refs/tags/v2.6.0.zip
        sha256: 661b11003d82715bfc9a7948f2e6bf06249007038d36315f95833c705f362d77
```

- Get a checksum with `curl -sL <url> | sha256sum`. A mismatch stops the pod.
- Every pod start needs the URLs to be reachable. For a cluster without
  internet access, mount the archives (`extraVolumes`) and use `file://` URLs.
- URLs that carry a token go in a Secret instead: `mantis.plugins.existingSecret`,
  one `<url>#sha256=<checksum>` per line.
- Enable a plugin in **Manage → Manage Plugins**. To remove one, uninstall it
  there first, then take it out of the list.

### PHP, PHP-FPM and Apache

`mantis.php`, `mantis.phpFpm` and `mantis.httpd` map to the image's
`PHP_*`, `PHP_FPM_*` and `HTTPD_*` variables. An empty value keeps the image's
default. Any other `php.ini` or pool setting goes under `mantis.php.ini` or
`mantis.phpFpm.pool`, by its real name:

```yaml
mantis:
  php:
    uploadMaxFilesize: 16M
    ini:
      session.gc_maxlifetime: 7200
  phpFpm:
    maxChildren: 10
```

Size PHP-FPM against the pod's memory limit: the worst case is
`phpFpm.maxChildren × php.memoryLimit`, and the image logs a warning at start
when that exceeds `resources.limits.memory`.

For anything else, `mantis.confd.{php,phpFpm,httpd}` adds configuration
drop-ins (file name → content) that the image applies last, and
`mantis.hooks` adds bash scripts that run at startup before the
configuration check. A failing hook stops the pod.

### Main values

| Value | Default | |
|---|---|---|
| `database.type` | `mariadb` | `mariadb` or `postgresql` |
| `database.mode` | `standalone` | `standalone`, `operator` or `external` |
| `database.auth.existingSecret` | | use your own credentials Secret |
| `replicaCount` | `2` | |
| `mantis.contextPath` | `/mantis` | URL path; `/` for the root |
| `mantis.url` | | public URL, derived from `route.host` or `ingress.host` if set |
| `mantis.timezone` | `UTC` | |
| `mantis.administration.enabled` | `false` | exposes `<contextPath>/admin/` |
| `mantis.email.*` | off | SMTP settings |
| `mantis.ldap.*` | off | LDAP / Active Directory login |
| `mantis.oidc.*` | off | single sign-on through OpenID Connect |
| `mantis.plugins.archives` | `[]` | plugins downloaded at start, pinned by SHA-256 |
| `mantis.php.*` / `mantis.phpFpm.*` / `mantis.httpd.*` | | PHP, PHP-FPM and Apache tuning |
| `mantis.confd.*` / `mantis.hooks` | `{}` | configuration drop-ins and startup hooks |
| `mantis.attachments.subdirectoryDepth` / `Width` | `1` / `2` | patched attachment layout |
| `persistence.attachments.*` | 10Gi RWX | |
| `mariadb.operator.replicas` | `3` | odd, at least 3 |
| `mariadb.operator.image` | `mariadb:11.8.9` | LTS; minor updates within 11.8 are safe |
| `postgresql.operator.instances` | `3` | |
| `mariadb.operator.extraSpec` / `postgresql.operator.extraSpec` | `{}` | merged into the CR spec: backups, monitoring, TLS |
| `backup.volsync.enabled` | `false` | VolSync backups of the attachments; see [Backup](#backup) |
| `route.enabled` / `ingress.enabled` | `true` / `false` | |
| `certManager.enabled` | `false` | certificate for the host, issued and renewed by cert-manager |
| `networkPolicy.enabled` | `false` | application open on http only; database only from its namespace and the operator |
| `networkPolicy.database.operatorNamespace` | | where the database operator runs, if not the upstream default |
| `route.tlsSecret` | | serve your own `kubernetes.io/tls` Secret on the Route |

See [values.yaml](values.yaml) for everything, with comments.

## Credentials and GitOps

Unless you supply your own Secrets, the chart generates the database
passwords, the administrator password and `crypto_master_salt`. It keeps them
across upgrades by reading them back from the cluster with `lookup`.

Anything that renders without cluster access (`helm template`, Argo CD)
cannot do that and would generate new values on every render. In that case,
create the Secrets yourself and point the chart at them:

```sh
oc create secret generic mantis-db \
  --from-literal=username=mantis \
  --from-literal=password="$(openssl rand -base64 24)" \
  --from-literal=root-password="$(openssl rand -base64 24)" \
  --type=kubernetes.io/basic-auth
oc create secret generic mantis-app \
  --from-literal=admin-password="$(openssl rand -base64 18)" \
  --from-literal=crypto-master-salt="$(openssl rand -base64 48)" \
  --from-literal=oidc-crypto-passphrase="$(openssl rand -hex 32)"   # with mantis.oidc
```

Add `smtp-password` and `ldap-bind-password` if you use them. The OIDC client
secret can go in it as `oidc-client-secret`, or in a Secret of its own
(`mantis.oidc.existingSecret`).

```yaml
database:
  auth:
    existingSecret: mantis-db
mantis:
  existingSecret: mantis-app
```

With the External Secrets Operator, generate the same two Secrets from your
vault instead.

The same goes for the certificate Secret with `certManager.enabled` and a
Route: without `lookup`, every render would replace the issued certificate
with the self-signed placeholder. Set `certManager.placeholderSecret: false`
there. The Route is then refused until cert-manager has written the Secret,
and Argo CD's sync retry gets past that once it has.

The schema Job is a Helm post-install/post-upgrade hook, which Argo CD runs
as a PostSync hook. Don't pass `--wait` to the first `helm install`: Helm
then waits for the pods to be ready before running the hook, and the pods
only become ready once the hook has installed the schema.

## Backup

Three things need backing up: the database, the attachments volume, and the
Secrets. Losing `crypto-master-salt` invalidates every session and token.

- **Database:** with an operator, use its own backups, configured through
  `mariadb.operator.extraSpec` / `postgresql.operator.extraSpec` or the
  operator's `Backup`/`ScheduledBackup` resources. Those restore consistently,
  which a volume snapshot of a running cluster does not.
- **Attachments:** VolSync (below), OADP, or both.
- **Everything in the namespace:** OADP. See [examples/oadp/](../../examples/oadp/)
  for non-admin backups, a nightly schedule, and a restore.

Back up the database first and the attachments after. That way every
attachment the database references is in the attachments backup; an extra
file with no database row does no harm.

Whichever tool you use, send the backups to object storage **outside** the
cluster's own storage. A NooBaa/RGW bucket on the same ODF is lost together
with it.

### Attachments with VolSync

With `backup.volsync.enabled`, the chart creates a VolSync `ReplicationSource`
that snapshots the attachments PVC on a schedule and pushes it to a restic
repository, with retention and pruning. VolSync is an operator
(OperatorHub: *VolSync*, from Red Hat) that a cluster administrator installs
once. Everything after that happens in your namespace.

```sh
oc apply -f examples/volsync/restic-secret.yaml   # after filling it in
helm upgrade --install mantis ./charts/mantis -f <db values> \
  -f examples/volsync/values.yaml
oc get replicationsource mantis-attachments -o jsonpath='{.status.lastSyncTime}'
```

- The chart doesn't create the repository Secret: it holds `RESTIC_PASSWORD`,
  without which the backups can't be read, so it has to exist somewhere
  other than the cluster too.
- MantisBT writes attachments with mode 0400, so the mover has to run as the
  application's UID. On OpenShift this is automatic. Elsewhere, set
  `backup.volsync.moverSecurityContext`.
- On CephFS, set `accessModes: [ReadOnlyMany]`. VolSync then mounts a shallow
  volume backed by the snapshot, instead of copying the whole volume on every
  run.

To restore the whole volume, see [examples/volsync/restore.yaml](../../examples/volsync/restore.yaml).
It's a restic repository, so single files can also be restored with the
restic CLI.

## Uninstalling

`helm uninstall` deliberately **leaves the data behind**:

- the attachments PVC, the standalone database PVC, and the credentials
  Secrets;
- the `MariaDB` or CloudNativePG `Cluster` resource, so uninstalling never
  takes the database down. Deleting a CloudNativePG `Cluster` also deletes
  its volumes; deleting a `MariaDB` leaves them behind.

Installing again with the same release name picks all of it back up. To
remove everything (release `mantis`):

```sh
helm uninstall mantis
# PostgreSQL via CloudNativePG (its PVCs go with it):
oc delete cluster.postgresql.cnpg.io/mantis-postgresql
# MariaDB via mariadb-operator (its PVCs stay, labelled with the resource name):
oc delete mariadb/mantis-mariadb
oc delete pvc -l app.kubernetes.io/instance=mantis-mariadb
# Attachments and the standalone database:
oc delete pvc -l app.kubernetes.io/instance=mantis
oc delete secret mantis-db mantis-app
```

## OpenShift notes

The image runs under the default `restricted-v2` SCC with an arbitrary UID.
The chart handles the places where that matters:

- `/var/lib/php/session` and `wsdlcache` are `root:apache 0770` in the image,
  which an arbitrary UID can't write. Without a writable session directory,
  every form submission fails its security-token check. The chart mounts
  emptyDirs there.
- TLS ends at the Route, so Apache sees plain HTTP. MantisBT reads
  `X-Forwarded-Proto` itself and builds `https://` links. Apache takes the
  client address from `X-Forwarded-For` sent by `mantis.httpd.trustedProxies`.
- `/server-status` and `/php-status` list in-flight URLs and client
  addresses. The image allows them from `127.0.0.1` only, but it checks the
  address taken from `X-Forwarded-For`, so a pod inside a trusted range could
  claim to be `127.0.0.1`. With `mantis.httpd.statusAllow: local` (the
  default), a chart drop-in checks the TCP peer instead.
- Probes: liveness and startup use `/healthz.php`, which checks Apache and
  PHP-FPM without the database. Readiness uses `<contextPath>/login_page.php`,
  so a database outage takes the pods out of the Service but doesn't restart
  them.

## Development

```sh
helm lint charts/mantis
for t in mariadb postgresql; do for m in standalone operator external; do
  helm template t charts/mantis --set database.type=$t,database.mode=$m \
    --set database.external.host=db --set database.skipOperatorCheck=true >/dev/null \
    && echo "ok $t/$m"
done; done
```

`files/schema.php` is the schema installer/upgrader the Job runs. It follows
MantisBT's own `admin/install.php` and `admin/upgrade_unattended.php`.
