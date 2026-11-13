---
title: "07 — PostgreSQL (CloudNativePG)"
weight: 8
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Instances PostgreSQL gérées par un opérateur : haute disponibilité (bascule
automatique), réplication en streaming, secrets générés, services rw/ro.

## Prérequis

- [05 — Stockage persistant (local-path-provisioner)](05-stockage-persistant.md) (StorageClass `local-data`)

## Installation

Deux releases helmfile (dépôt `cnpg` : https://cloudnative-pg.github.io/charts) :

| Release | Namespace | Chart | Rôle |
|---|---|---|---|
| `cnpg` | `cnpg-system` | `cnpg/cloudnative-pg` 0.29.1 (opérateur 1.30.1) | CRD + contrôleur |
| `pg-main` | `databases` | `cnpg/cluster` 0.9.0 | instance PostgreSQL 17 |

```bash
make apply SELECTOR=tier=infra     # opérateur
make apply SELECTOR=name=pg-main   # instance
```

`pg-main` déclare `needs: [cnpg-system/cnpg]` et `disableValidationOnInstall: true`,
parce que les CRD `postgresql.cnpg.io` n'existent qu'une fois l'opérateur installé.

## Configuration (`values/pg-main.yaml.gotmpl`)

| Paramètre | Valeur |
|---|---|
| Nom | `pg-main` (`fullnameOverride`) |
| Instances | 3 (1 primaire + 2 réplicas), anti-affinité `kubernetes.io/hostname` |
| Stockage | 2 Gi par instance, `local-data` → `data/volumes/databases/pg-main-N/data` |
| Base / propriétaire | `app` / `app` |
| Superutilisateur | activé (`pg-main-superuser`) |
| Rôles gérés | `risingwave` (meta store RisingWave) · `quickwit` (metastore Quickwit) · `rw_cdc` (`REPLICATION` + `pg_read_all_data`, CDC) — secrets `pg-main-role-<rôle>` |
| Publications | `rw_cdc` sur `app` (`FOR ALL TABLES`), release `pg-main-objects`, voir [13](13-cdc-pg-main-risingwave.md) |
| Bases supplémentaires | `risingwave` ([12](12-risingwave.md)), `quickwit` ([17](17-quickwit.md)) — ressources CNPG `Database` |
| Sauvegardes | ✅ barman-cloud → Garage S3, voir [10 — Sauvegardes PostgreSQL (barman-cloud → Garage)](10-sauvegardes-postgresql.md) |

Services et secrets :

| Nom | Rôle |
|---|---|
| `pg-main-rw.databases:5432` | primaire (lecture/écriture) |
| `pg-main-ro.databases:5432` | réplicas (lecture seule) |
| `pg-main-r.databases:5432` | toutes les instances |
| secret `pg-main-app` | `username`, `password`, `uri`, `jdbc-uri`… pour les applis |
| secret `pg-main-superuser` | compte `postgres` |

## Vérification

```bash
kubectl -n databases get cluster          # 3/3 "Cluster in healthy state"
kubectl -n databases get pods -o wide     # un pod par nœud

# écriture sur le primaire, lecture sur les réplicas
kubectl -n databases exec pg-main-1 -c postgres -- psql -U postgres -d app -c "SELECT pg_is_in_recovery();"

# accès local
kubectl -n databases port-forward svc/pg-main-rw 5432:5432
kubectl -n databases get secret pg-main-app -o jsonpath='{.data.password}' | base64 -d
psql "postgresql://app:<mdp>@localhost:5432/app"
```

Tests réalisés le 2026-11-11 :

- `INSERT` sur le primaire, lu sur les 2 réplicas (`pg_is_in_recovery() = t`) ✅
- Bascule : suppression du pod primaire `pg-main-1` → `pg-main-2` promu en ~4 s,
  cluster de nouveau 3/3 sans perte de données ✅

## Pièges rencontrés

- Le chart `cnpg/cluster` nomme l'instance `<release>-cluster` par défaut.
  → `fullnameOverride: pg-main`. Le changement de nom a laissé un PV `Released`
  et un dossier `pg-main-cluster-1` (à cause de `Retain`), supprimés à la main.
- Après un `make recreate`, les dossiers `pg-main-N/data` existent toujours, mais
  CloudNativePG ne sait pas réadopter un PGDATA existant. → Restaurer depuis les
  sauvegardes Garage ([10](10-sauvegardes-postgresql.md)), après avoir vidé
  `data/volumes/databases/`.

## Interface web

pgAdmin (`https://pgadmin.k8s.test`) avec `pg-main` préconfiguré : voir
[11 — Interfaces web (Headlamp, garage-webui, pgAdmin)](11-interfaces-web.md).

## Plugin kubectl (optionnel)

```bash
kubectl krew install cnpg      # ou binaire depuis github.com/cloudnative-pg/cloudnative-pg
kubectl cnpg status pg-main -n databases
```

## Désinstallation

```bash
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l name=pg-main destroy
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l name=cnpg destroy
sudo podman exec k8s rm -rf /mnt/k8s-data/volumes/databases    # données
```
