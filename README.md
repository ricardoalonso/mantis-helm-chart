# mantis-helm-chart

Helm chart for [MantisBT](https://www.mantisbt.org/) on OpenShift/Kubernetes,
using the image from [mantis-container](https://github.com/ricardoalonso/mantis-container).

- MariaDB or PostgreSQL
- One database pod, an HA cluster through an operator (Galera via
  mariadb-operator, or CloudNativePG), or an external server
- The schema is installed and upgraded by a Job, with no web installer
- Runs under OpenShift's `restricted-v2` SCC

```sh
helm install mantis ./charts/mantis -f examples/postgresql-cnpg.yaml
```

See [charts/mantis/README.md](charts/mantis/README.md) for the documentation
and [examples/](examples/) for a values file per database setup. Backups:
[examples/volsync/](examples/volsync/) for the attachments and
[examples/oadp/](examples/oadp/) for the whole namespace.
