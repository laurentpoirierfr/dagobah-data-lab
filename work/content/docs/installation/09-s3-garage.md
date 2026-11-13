---
title: "09 — Stockage objet S3 (Garage)"
weight: 10
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Disposer d'un stockage objet compatible S3 dans le cluster, pour les sauvegardes
PostgreSQL ([10](10-sauvegardes-postgresql.md)) et les données du projet.

## Choix de Garage

| Solution | Statut (11/2026) | Décision |
|---|---|---|
| MinIO | dépôt **archivé** (avril 2026, « no longer maintained ») | ❌ écarté |
| **Garage** v2.5.0 (Deuxfleurs, Rust) | actif, très léger, S3 éprouvé avec barman | ✅ retenu |
| RustFS 1.0.5 | remplaçant de MinIO, encore récent | alternative |
| SeaweedFS 4.53 | complet mais plusieurs composants | alternative |

## Prérequis

- [05 — Stockage persistant (local-path-provisioner)](05-stockage-persistant.md) (StorageClass `local-data`)
- [04 — Helm + helmfile](04-helm-helmfile.md)

## Installation

```bash
make apply SELECTOR=name=garage
```

La release `garage` (chart git `script/helm/garage`, ref `v2.5.0`) déclenche
automatiquement :

| Hook helmfile | Script | Action |
|---|---|---|
| `prepare` | `scripts/ensure-secret.sh` | crée `garage-rpc-secret` (RPC entre nœuds) et `garage-admin-token` (API d'administration), une seule fois |
| `postsync` | `scripts/garage-init.sh` | layout, buckets, clés, secrets k8s, `.s3/credentials` (idempotent) |

Relancer l'initialisation à la main : `make s3-init`.

## Configuration (`values/garage.yaml.gotmpl`)

| Paramètre | Valeur |
|---|---|
| Nœuds Garage | 3 (StatefulSet, un pod par nœud k8s, anti-affinité) |
| Réplication | `replication_factor = 3`, `consistency_mode = consistent` |
| Layout | une zone par nœud k8s (`k8s`, `k8s-m02`, `k8s-m03`), 20G chacun |
| Stockage | PVC `local-data` : meta 1Gi + data 20Gi par nœud → `data/volumes/garage/` |
| Métadonnées | LMDB, instantané automatique toutes les 6 h |
| API S3 externe | `https://s3.k8s.test` (TLS cert-manager, path-style, sans limite de taille) |
| API S3 interne | `http://garage.garage.svc:3900` |
| API admin | `http://garage-admin.garage.svc:3903` (jeton `garage-admin-token`) |
| Région | `garage` |

Buckets et clés créés par `garage-init.sh` (variable `BUCKETS`) :

| Bucket | Clé | Secret Kubernetes | Usage |
|---|---|---|---|
| `cnpg-backups` | `cnpg` | `databases/s3-cnpg` | sauvegardes PostgreSQL |
| `projet` | `projet` | `garage/s3-projet` | données du projet |
| `risingwave` | `risingwave` | `risingwave/s3-risingwave` | state store RisingWave ([12](12-risingwave.md)) |
| `quickwit` | `quickwit` | `quickwit/s3-quickwit` | index Quickwit ([17](17-quickwit.md)) |

Chaque secret contient `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `BUCKET`, `ENDPOINT`
et `REGION`. Chaque clé n'a accès qu'à son bucket.

## Utilisation depuis l'hôte

`garage-init.sh` écrit `.s3/credentials` et `.s3/config` (ignorés par git) :

```bash
export AWS_SHARED_CREDENTIALS_FILE=~/Projects/dagobah-data-lab/.s3/credentials
export AWS_CONFIG_FILE=~/Projects/dagobah-data-lab/.s3/config
aws --profile projet s3 ls s3://projet/
aws --profile projet s3 cp fichier.txt s3://projet/
```

Sans aws cli, avec curl (signature SigV4) :

```bash
curl --cacert certs/k8s-ca.crt --aws-sigv4 aws:amz:garage:s3 --user "$KEY_ID:$SECRET" \
     -T fichier.txt https://s3.k8s.test/projet/fichier.txt
```

Interface web : garage-webui, voir [11 — Interfaces web (Headlamp, garage-webui, pgAdmin)](11-interfaces-web.md).

## Vérification

```bash
kubectl -n garage exec garage-0 -c garage -- /garage status       # 3 nœuds, zones et capacités
kubectl -n garage exec garage-0 -c garage -- /garage bucket list
```

Tests réalisés le 2026-11-11 via `https://s3.k8s.test` : PUT 200, GET 200,
LIST 200, DELETE 204, accès de la clé `projet` au bucket `cnpg-backups` → **403**
(isolation correcte).

## Pièges rencontrés

- **MinIO archivé** : ne plus l'utiliser pour un nouveau projet.
- **Faux changement dans `make diff`** : le chart génère son secret RPC avec
  `lookup`, que `helm-diff` ne voit pas. Résultat : un changement apparaît à chaque
  diff. → On crée le secret dans un hook `prepare` (`existingRpcSecret`).
- **Région** : Garage rejette toute signature S3 dont la région n'est pas `garage`.
  Les clients doivent utiliser `region=garage` (voir 10 pour barman).
- **SSE-S3 (`AES256`) non supporté** par Garage : désactiver le chiffrement côté
  serveur dans les clients (barman : `encryption: ""`).
- Les hôtes virtuels (`<bucket>.s3.k8s.test`) ne sont pas résolus par ingress-dns
  (pas de wildcard) : utiliser le **path-style** (`s3.k8s.test/<bucket>`).

## Désinstallation

```bash
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l name=garage destroy
kubectl delete ns garage
sudo podman exec k8s rm -rf /mnt/k8s-data/volumes/garage      # données
```
