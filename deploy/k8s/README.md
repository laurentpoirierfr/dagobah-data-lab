# Dagobah Data Lab — releases Helm (helmfile)

Déclare les releases Helm du **Dagobah Data Lab** sur le cluster minikube `k8s`
(contexte `k8s`, `*.k8s.test`).

```
deploy/k8s/
├── helmfile.yaml.gotmpl      # environnements, helmDefaults, liste des releases
├── charts/risingwave/        # chart local : ressource RisingWave + Ingress dashboard
├── charts/pg-objects/        # chart local : objets CNPG déclaratifs (Publication)
├── quickwit/indexes/         # configurations d'index Quickwit (make qw-index-create)
├── sql/app/                  # SQL de la base app (make cdc-seed)
├── sql/risingwave/           # SQL RisingWave : 10-cdc (make rw-cdc-setup), 20-kafka (make rw-kafka-setup)
├── scripts/                  # hooks helmfile (secrets, init Garage, rôles PG)
├── environments/k8s.yaml     # valeurs communes : contexte, domaine, ingress, issuer TLS
└── values/<release>.yaml.gotmpl
```

## Outils

| Outil | Version | Installation |
|---|---|---|
| helm | v4.3.1 | `~/.local/bin/helm` |
| helmfile | 1.8.3 | `~/.local/bin/helmfile` |
| helm-diff | v3.15.15 | `helm plugin install https://github.com/databus23/helm-diff --version v3.15.15` |

`make helm-tools` vérifie les trois. `helm-diff` n'est requis que pour `diff` et `apply` ; `sync` fonctionne sans.

## Utilisation (depuis la racine du projet)

```bash
make lint                       # lint des charts
make template                   # rendu des manifests
make diff                       # aperçu
make apply                      # applique les différences
make sync                       # (ré)installe tout, sans diff
make releases                   # état des releases
make apply SELECTOR=name=podinfo   # une seule release
make destroy                    # supprime les releases
make ca                         # exporte la CA locale dans certs/k8s-ca.crt
```

## Valeurs d'environnement

`environments/k8s.yaml` est injecté dans tous les templates `*.gotmpl` :

| Clé | Valeur | Usage |
|---|---|---|
| `kubeContext` | `k8s` | `helmDefaults.kubeContext` : empêche de viser un autre cluster |
| `domain` | `k8s.test` | hôtes Ingress : `<app>.{{ .Values.domain }}` |
| `ingressClass` | `nginx` | `ingress.className` |
| `clusterIssuer` | `dagobah-ca-issuer` | annotation `cert-manager.io/cluster-issuer` |

## Hooks et scripts

| Script | Hook | Rôle |
|---|---|---|
| `scripts/ensure-secret.sh` | `prepare` (garage, garage-webui, pgadmin) | crée une seule fois les secrets générés (RPC, jetons, mots de passe, bcrypt) |
| `scripts/pg-role-secret.sh` | `prepare` (pg-main) | mot de passe d'un rôle CNPG, copié dans le namespace de l'application |
| `scripts/rp-demo-events.sh` | — (`make rp-demo-events`) | producteur d'événements JSON de démo dans Redpanda |
| `scripts/garage-init.sh` | `postsync` (garage) | layout Garage, buckets, clés, secrets `s3-*`, `.s3/credentials` (`make s3-init`) |

Labels pour `SELECTOR` : `tier=infra`, `tier=data`, `tier=monitoring`, `tier=ui`, `tier=demo`.

## Ajouter une release

1. Ajouter l'entrée dans `releases:` de `helmfile.yaml.gotmpl` (chart, **version fixée**,
   namespace). Pour un chart non-OCI, déclarer aussi le dépôt dans `repositories:`.
2. Créer `values/<release>.yaml.gotmpl` en réutilisant `.Values.domain`,
   `.Values.ingressClass` et `.Values.clusterIssuer`.
3. `make diff`, puis `make apply`.

## Release en place

| Release | Namespace | Chart | URL |
|---|---|---|---|
| local-path-provisioner | local-path-storage | `git::…/rancher/local-path-provisioner` v0.0.37 | — (StorageClass par défaut `local-data`) |
| cnpg | cnpg-system | `cnpg/cloudnative-pg` 0.29.1 (opérateur 1.30.1) | — |
| pg-main | databases | `cnpg/cluster` 0.9.0 (PostgreSQL 17, 3 instances) | `pg-main-rw.databases:5432` |
| barman-cloud | cnpg-system | `cnpg/plugin-barman-cloud` 0.9.0 (v0.16.0) | — (sauvegardes pg-main → S3) |
| garage | garage | `git::…/Deuxfleurs/garage` v2.5.0 | https://s3.k8s.test |
| redpanda | redpanda | `redpanda/redpanda` 26.2.5 (Redpanda v26.2.6 + Console 3.9.0) | https://redpanda.k8s.test, Kafka `:9093` |
| quickwit | quickwit | `quickwit/quickwit` 0.8.17 (image v0.9.3) | https://quickwit.k8s.test |
| kube-prometheus-stack | monitoring | `prometheus-community/kube-prometheus-stack` 93.2.2 | https://grafana.k8s.test, https://prometheus.k8s.test |
| headlamp | headlamp | `headlamp/headlamp` 0.46.0 | https://headlamp.k8s.test |
| garage-webui | garage | `bjw-s/app-template` 5.3.0 | https://garage.k8s.test |
| pgadmin | pgadmin | `runix/pgadmin4` 1.71.0 | https://pgadmin.k8s.test |
| pg-main-objects | databases | `./charts/pg-objects` (local) | — (publication `rw_cdc`) |
| risingwave-operator | risingwave-operator-system | `risingwavelabs/risingwave-operator` 0.1.40 | — |
| risingwave | risingwave | `./charts/risingwave` (local, RisingWave v3.1.1) | https://risingwave.k8s.test, SQL `:4567` |
| podinfo | podinfo | `oci://ghcr.io/stefanprodan/charts/podinfo` 6.17.0 | https://podinfo.k8s.test |

2 réplicas répartis sur les workers, certificat TLS émis par `dagobah-ca-issuer` :

```bash
make ca
curl --cacert certs/k8s-ca.crt https://podinfo.k8s.test/
```
