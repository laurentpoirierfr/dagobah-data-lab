---
title: "Journal d'installation"
weight: 1
linkTitle: Installation
---

Suivi pas à pas de la mise en place du cluster `k8s` et des composants du
**Dagobah Data Lab**.
Chaque fichier décrit un composant : objectif, commandes, vérification et pièges
rencontrés. Les étapes sont à suivre dans l'ordre.

| # | Composant | Statut | Fichier |
|---|---|---|---|
| 00 | Prérequis (outils) | ✅ 2026-11-11 | [00 — Prérequis](00-prerequis.md) |
| 01 | Podman rootful | ✅ 2026-11-11 | [01 — Podman rootful](01-podman-rootful.md) |
| 02 | Cluster minikube 3 nœuds | ✅ 2026-11-11 | [02 — Cluster minikube 3 nœuds](02-cluster-minikube.md) |
| 03 | DNS local `*.k8s.test` | ✅ 2026-11-11 | [03 — DNS local *.k8s.test](03-dns-local.md) |
| 04 | Helm + helmfile | ✅ 2026-11-11 | [04 — Helm + helmfile](04-helm-helmfile.md) |
| 05 | Stockage persistant (local-path) | ✅ 2026-11-11 | [05 — Stockage persistant (local-path-provisioner)](05-stockage-persistant.md) |
| 06 | podinfo (démo Ingress + TLS) | ✅ 2026-11-11 | [06 — podinfo (démo Ingress + TLS)](06-podinfo.md) |
| 07 | PostgreSQL (CloudNativePG) | ✅ 2026-11-11 | [07 — PostgreSQL (CloudNativePG)](07-postgresql-cloudnativepg.md) |
| 08 | Certificats TLS + import navigateur | ✅ 2026-11-11 | [08 — Certificats TLS et import dans le navigateur](08-certificats-navigateur.md) |
| 09 | Stockage objet S3 (Garage) | ✅ 2026-11-11 | [09 — Stockage objet S3 (Garage)](09-s3-garage.md) |
| 10 | Sauvegardes PostgreSQL (barman-cloud) | ✅ 2026-11-11 | [10 — Sauvegardes PostgreSQL (barman-cloud → Garage)](10-sauvegardes-postgresql.md) |
| 11 | Interfaces web (Headlamp, garage-webui, pgAdmin) | ✅ 2026-11-11 | [11 — Interfaces web (Headlamp, garage-webui, pgAdmin)](11-interfaces-web.md) |
| 12 | RisingWave (streaming, opérateur) | ✅ 2026-11-11 | [12 — RisingWave (base de données de streaming)](12-risingwave.md) |
| 13 | CDC pg-main → RisingWave | ✅ 2026-11-11 | [13 — CDC pg-main → RisingWave](13-cdc-pg-main-risingwave.md) |
| 14 | Redpanda (Kafka) + Console | ✅ 2026-11-11 | [14 — Redpanda (streaming compatible Kafka) + Redpanda Console](14-redpanda.md) |
| 15 | RisingWave ⇄ Redpanda (source et sink Kafka) | ✅ 2026-11-11 | [15 — RisingWave ⇄ Redpanda (source et sink Kafka)](15-risingwave-redpanda.md) |
| 16 | Supervision (Prometheus, Alertmanager, Grafana) | ✅ 2026-11-11 | [16 — Supervision (Prometheus, Alertmanager, Grafana)](16-supervision.md) |
| 17 | Quickwit (recherche logs/traces sur S3), tests | ✅ 2026-11-11 | [17 — Quickwit (recherche logs / traces sur S3) — mode distribué, tests](17-quickwit.md) |

Légende : ✅ installé et vérifié · 🚧 en cours · ⏳ prévu

## Réinstallation complète

```bash
cd ~/Projects/dagobah-data-lab
make up          # 02 + 03 (DNS : mot de passe sudo)
make sync        # 05 à 17 via helmfile (hooks : secrets, init Garage, rôles PG)
make verify
certs/cert.sh ca-restore   # 08 : remet la CA déjà importée dans le navigateur
make ui-credentials        # 11 : identifiants des interfaces web
make cdc-seed rw-cdc-setup # 13 : tables de démo + CDC vers RisingWave
make rp-topics rw-kafka-setup # 15 : topics + source/vues/sink Kafka dans RisingWave
```

> 💾 Après un `make recreate`, `pg-main` repart vide : restaurer depuis Garage
> ([10](10-sauvegardes-postgresql.md#restauration-testée-le-2026-11-11)).

## Accès rapides

| Service | URL / point d'accès |
|---|---|
| Headlamp (Kubernetes) | https://headlamp.k8s.test |
| garage-webui (S3) | https://garage.k8s.test |
| pgAdmin (PostgreSQL) | https://pgadmin.k8s.test |
| API S3 | https://s3.k8s.test (région `garage`, path-style) |
| Grafana | https://grafana.k8s.test |
| Prometheus / Alertmanager | https://prometheus.k8s.test · https://alertmanager.k8s.test (basic auth) |
| Redpanda Console | https://redpanda.k8s.test (basic auth) |
| Quickwit | https://quickwit.k8s.test (basic auth) |
| Kafka (Redpanda) | `redpanda.redpanda.svc.cluster.local:9093` |
| RisingWave (dashboard) | https://risingwave.k8s.test |
| RisingWave (SQL) | `make rw-psql` ou `risingwave-frontend.risingwave:4567` |
| podinfo (démo) | https://podinfo.k8s.test |
| PostgreSQL (cluster) | `pg-main-rw.databases:5432` |

> 🔐 Tests dans le navigateur : importer la CA `certs/k8s-ca.crt` comme autorité
> de certification (`certs/cert.sh trust`, ou à la main). Voir
> [08 — Certificats TLS et import dans le navigateur](08-certificats-navigateur.md).

## Ajouter une étape

Depuis `work/` : `hugo new content docs/installation/NN-composant.md --kind installation`
(archétype `archetypes/installation.md`), puis ajouter une ligne au tableau ci-dessus.
