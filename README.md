# Dagobah Data Lab — plateforme de données temps réel sur Kubernetes

Laboratoire local et auto-hébergé : ingestion (CDC PostgreSQL, Redpanda/Kafka),
traitement en streaming (RisingWave), stockage (PostgreSQL CloudNativePG, S3 Garage),
recherche (Quickwit) et supervision (Prometheus, Grafana), sur un cluster minikube
3 nœuds déclaré avec helmfile.

```
 pg-main (PostgreSQL) ──CDC──┐
                             ├──▶ RisingWave (SQL streaming) ──▶ vues matérialisées ──▶ Redpanda (sink)
 Redpanda (Kafka) ───────────┘            │ meta store : pg-main · state store : Garage S3
 Quickwit (logs/traces) ──▶ Garage S3 · metastore pg-main
 Prometheus + Grafana : métriques de tous les composants
```

> Documentation (Hugo, thème Hextra) : source dans [`work/`](work/), site généré dans
> [`docs/`](docs/) — `make docs-serve` puis http://localhost:1313. Journal d'installation :
> [`work/content/docs/installation/`](work/content/docs/installation/_index.md).

## Infrastructure

Cluster local **minikube** à 3 nœuds (1 control-plane + 2 workers), driver
**Podman rootful**, Ingress nginx, DNS local `*.k8s.test` et TLS via cert-manager.

## Démarrage

```bash
make up        # crée/démarre le cluster, configure le DNS hôte, vérifie
make verify    # nœuds Ready, ingress-dns, résolution hôte, Ingress HTTP, ClusterIssuer
make help      # toutes les cibles
```

| Élément | Valeur |
|---|---|
| Profil / contexte kubectl | `k8s` |
| Nœuds | 3 × 4 vCPU / 8 Gio |
| Runtime / CNI | containerd / kindnet |
| Addons | ingress, ingress-dns, metrics-server |
| Domaine | `*.k8s.test` |
| ClusterIssuer TLS | `dagobah-ca-issuer` |

Personnalisation : `make up NODES=2 CPUS=2 MEMORY=6g`, `make up DOMAIN=lab.test`.
Options du lanceur : `make up ARGS='--yes'`, `make recreate`.

## Déploiements (helmfile)

Les releases Helm sont déclarées dans [`deploy/k8s/`](deploy/k8s/README.md) :

```bash
make sync      # déploie toutes les releases (podinfo -> https://podinfo.k8s.test)
make diff      # aperçu (plugin helm-diff)
make apply     # applique les différences
make ca        # exporte la CA locale (à importer dans le navigateur, voir plus bas)
```

## Données persistantes

```
~/Projects/dagobah-data-lab/data/                 (hôte, ignoré par git)
└── volumes/<namespace>/<pvc>/data/  ← contenu de chaque PVC
```

- `data/` est monté (bind) sur `/mnt/k8s-data` dans **les 3 nœuds** à la création
  du cluster (`--mount-string`). Si tu changes `DATA_DIR`, il faut `make recreate`.
  `/data` n'est pas utilisable : minikube y monte déjà son propre `/var/data`.
- La release helmfile `local-path-provisioner` (v0.0.37) fournit la StorageClass
  **par défaut** `local-data` :
  - `sharedFileSystemPath` : le dossier est partagé par tous les nœuds, donc pas
    d'affinité de nœud et un pod peut changer de nœud en gardant ses données ;
  - `reclaimPolicy: Retain` : supprimer un PVC ne supprime pas ses fichiers ;
  - `pathPattern: <ns>/<pvc>/data` : un PVC recréé avec le même namespace et le
    même nom retrouve ses données, y compris après `make recreate`.
- Le provisioner hostpath de minikube (`standard`) est désactivé par `make up`.
- Les conteneurs tournent en root (Podman rootful) : les fichiers créés sont
  souvent à `root` sur l'hôte. Pour les supprimer : `sudo rm -rf data/volumes/<ns>/<pvc>`.
- Après suppression d'un PVC, le PV passe à `Released`. Pour réutiliser les
  données : `kubectl delete pv <pv>`, puis recréer le PVC avec le même nom.

## Certificats TLS et navigateur

Les Ingress utilisent des certificats signés par la CA locale `dagobah-ca`
(cert-manager).

> ⚠️ **Pour tester dans le navigateur, il faut importer la CA locale**
> `certs/k8s-ca.crt` comme **autorité de certification**, et non le certificat du
> site. Sinon : « La connexion n'est pas sécurisée ».
>
> ```bash
> make ca                  # exporte certs/k8s-ca.crt
> certs/cert.sh trust      # système + Firefox/Chrome (sudo, libnss3-tools)
> ```
>
> Import manuel dans Firefox ou Chrome :
> [08 — Certificats et navigateur](work/content/docs/installation/08-certificats-navigateur.md).

Fichiers crt/key depuis k8s : `make cert HOST=podinfo` ou `make certs`, dans
`certs/issued/<fqdn>/` (`tls.crt`, `tls.key`, `ca.crt`, `fullchain.crt`).

## Services

| Service | Accès |
|---|---|
| Grafana (supervision) | https://grafana.k8s.test (+ Prometheus, Alertmanager) |
| Headlamp (Kubernetes) | https://headlamp.k8s.test |
| garage-webui (S3) | https://garage.k8s.test |
| pgAdmin (PostgreSQL) | https://pgadmin.k8s.test |
| API S3 Garage | https://s3.k8s.test, région `garage`, path-style, `.s3/credentials` |
| PostgreSQL `pg-main` | `pg-main-rw.databases:5432` (3 instances, sauvegardes → S3) |
| RisingWave | https://risingwave.k8s.test, SQL : `make rw-psql` (port 4567) |
| Quickwit (recherche logs) | https://quickwit.k8s.test, `make qw-search Q='…'` |
| Redpanda (Kafka) | `redpanda.redpanda.svc.cluster.local:9093`, console https://redpanda.k8s.test |
| CDC pg-main → RisingWave | base `app` → vue `app_revenue_by_city` : `make cdc-status` |
| Redpanda ⇄ RisingWave | `shop-events` → vues → `shop-activity-by-city` : `make rw-kafka-status` |

Identifiants : `make ui-credentials`. Détails : [journal d'installation](work/content/docs/installation/_index.md),
étapes 09 à 17.

## Fonctionnement

- `cluster.sh` délègue la création au lanceur
  `~/Community/bin/start-minikube-podman.sh` (variable `LAUNCHER`). Celui-ci
  gère Podman rootful, la levée de la limite pids, les addons et cert-manager
  (voir son `README_MINIKUBE.md`).
- `make up` arrête d'abord les autres profils listés dans `OTHER_PROFILES`
  (défaut : `minikube`) pour libérer CPU/RAM.
- **DNS hôte par lien** : le domaine `~k8s.test` est attaché au bridge podman du
  cluster (`podmanN`) via `resolvectl dns/domain`, pas dans la section globale de
  systemd-resolved. Il ne se mélange donc pas avec `dagobah.test` (profil
  `minikube`). Cette config n'est pas persistante : elle disparaît avec le bridge
  (`make stop`, reboot) et `make up` / `make dns` la refont.

## Exemple d'Ingress TLS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monapp
  annotations:
    cert-manager.io/cluster-issuer: dagobah-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts: [monapp.k8s.test]
      secretName: monapp-tls
  rules:
    - host: monapp.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: monapp
                port:
                  number: 80
```

## Dépannage

| Symptôme | Action |
|---|---|
| `make dns` demande un mot de passe | normal : `resolvectl` exige `sudo` |
| `getent hosts x.k8s.test` vide après reboot | `make dns` |
| `… joint via 'enpXs0' et non via un bridge podman` | cluster rootless : `make recreate` |
| Nœuds non Ready | `make pods`, `make logs` |
