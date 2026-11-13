---
title: "10 — Sauvegardes PostgreSQL (barman-cloud → Garage)"
weight: 11
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Sauvegarder `pg-main` dans le S3 Garage : **archivage continu des WAL** et
**sauvegardes de base** quotidiennes, pour pouvoir restaurer à un instant donné
(PITR), y compris après un `make recreate`.

## Prérequis

- [07 — PostgreSQL (CloudNativePG)](07-postgresql-cloudnativepg.md)
- [09 — Stockage objet S3 (Garage)](09-s3-garage.md) (bucket `cnpg-backups`, secret `databases/s3-cnpg`)

## Installation

| Release | Namespace | Chart | Rôle |
|---|---|---|---|
| `barman-cloud` | `cnpg-system` | `cnpg/plugin-barman-cloud` 0.9.0 (v0.16.0) | plugin CNPG-I de sauvegarde |
| `pg-main` | `databases` | `cnpg/cluster` 0.9.0 | configuration des sauvegardes |

```bash
make apply SELECTOR=name=barman-cloud
make apply SELECTOR=name=pg-main      # needs : cnpg, barman-cloud, garage
```

Les pods `pg-main-N` redémarrent un par un pour recevoir le sidecar
`plugin-barman-cloud` (2/2 conteneurs).

## Configuration (`values/pg-main.yaml.gotmpl`)

| Paramètre | Valeur |
|---|---|
| Méthode | `plugin` (barman-cloud.cloudnative-pg.io), archiveur de WAL |
| ObjectStore | `pg-main-backups` → `s3://cnpg-backups/pg-main` via `http://garage.garage.svc:3900` |
| Identifiants | secret `s3-cnpg` (`ACCESS_KEY_ID` / `ACCESS_SECRET_KEY`) |
| Compression | gzip (WAL et données), chiffrement SSE désactivé |
| Planification | `pg-main-daily` : tous les jours à 02:00 (cron à 6 champs) |
| Cible | `prefer-standby` (sauvegarde prise sur un réplica) |
| Rétention | 14 jours |
| Région | `AWS_DEFAULT_REGION=garage` dans le sidecar |

## Vérification

```bash
kubectl -n databases get cluster pg-main -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
#   ContinuousArchiving=True
kubectl -n databases get backup,scheduledbackup,objectstore
```

Sauvegarde manuelle :

```bash
kubectl -n databases apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: pg-main-manual-1
spec:
  cluster: {name: pg-main}
  method: plugin
  pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}
EOF
kubectl -n databases get backup pg-main-manual-1     # PHASE completed
```

## Restauration (testée le 2026-11-11)

Nouveau cluster à partir des sauvegardes de `pg-main` (sauvegarde de base + WAL) :

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-restore-test
  namespace: databases
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17   # même version majeure que la sauvegarde !
  storage: {size: 2Gi, storageClass: local-data}
  bootstrap:
    recovery:
      source: origin
      # recoveryTarget: {targetTime: "2026-11-11 20:00:00+00"}   # PITR optionnel
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-main-backups
          serverName: pg-main
```

Résultat du test : la ligne `hello cnpg` (dans la sauvegarde de base) **et** la
ligne `apres backup` (insérée après, récupérée par rejeu des WAL) sont présentes
→ la chaîne sauvegarde + archivage WAL + restauration fonctionne.

Après un `make recreate`, cette procédure permet de recréer `pg-main` depuis
Garage (à condition que `data/volumes/garage/` ait été conservé).

> [!TIP]
> Mode opératoire complet, avec schémas, y compris la sauvegarde et la restauration
> **par schéma** (logique) : [Guides — Sauvegarde et restauration PostgreSQL ⇄ S3](../guides/sauvegarde-restauration-postgresql.md).

## Pièges rencontrés

- **`requested plugin is not available`** sur la première sauvegarde planifiée :
  elle s'est lancée avant que le plugin soit prêt. Sans conséquence, les
  suivantes passent. Supprimer le `Backup` en échec.
- **`not compatible with this version 18`** à la restauration : sans `imageName`,
  l'opérateur démarre PostgreSQL 18, alors que la sauvegarde est en 17.
  → Toujours fixer `imageName` à la même version majeure.
- **Instance restaurée bloquée (`Unknown plugin`)** : déclarer le plugin dans
  `spec.plugins` sans `barmanObjectName` empêche l'injection du sidecar. Pour
  une restauration, déclarer le plugin **uniquement** dans `externalClusters`.
- **Région S3** : l'ObjectStore généré par le chart ne transmet pas la région.
  Garage la vérifie. → `AWS_DEFAULT_REGION=garage` via
  `backups.instanceSidecarConfiguration.env`.
- **`AES256`** (valeur par défaut du chart) refusé par Garage → `encryption: ""`.

## Désinstallation

Mettre `backups.enabled: false` et retirer `cluster.plugins` dans
`values/pg-main.yaml.gotmpl`, puis `make apply`. Les sauvegardes restent dans
`s3://cnpg-backups/pg-main`.
