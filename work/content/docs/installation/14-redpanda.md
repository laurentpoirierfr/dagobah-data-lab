---
title: "14 — Redpanda (streaming compatible Kafka) + Redpanda Console"
weight: 15
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

[Redpanda](https://www.redpanda.com/) : plateforme de streaming **compatible avec
l'API Kafka** (clients, outils et connecteurs Kafka fonctionnent tels quels),
écrite en C++, sans ZooKeeper ni JVM. Elle intègre un Schema Registry et un proxy
HTTP. **Redpanda Console** fournit l'interface web (topics, messages, groupes de
consommateurs, schémas).

## Prérequis

- [05 — Stockage persistant (local-path-provisioner)](05-stockage-persistant.md) (StorageClass `local-data`)
- [04 — Helm + helmfile](04-helm-helmfile.md)
- `fs.aio-max-nr` de l'hôte : 65536 suffit pour 3 brokers à 1 cœur (vérifié)

## Installation

```bash
make apply SELECTOR=name=redpanda
```

| Release | Namespace | Chart | Contenu |
|---|---|---|---|
| `redpanda` | `redpanda` | `redpanda/redpanda` 26.2.5 (Redpanda v26.2.6) | StatefulSet 3 brokers + sous-chart `console` 3.9.0 |

Hook `prepare` : `scripts/ensure-secret.sh` crée `redpanda/redpanda-console-auth`
(`username`, `password`, `auth` au format htpasswd bcrypt) pour l'authentification
basique de la console.

## Configuration (`values/redpanda.yaml.gotmpl`)

| Paramètre | Valeur |
|---|---|
| Brokers | 3 (un par nœud, anti-affinité stricte du chart) |
| Ressources | 1 cœur (`--smp=1`, `overprovisioned`) et 2,5 Gi par broker |
| Stockage | PVC `local-data` 10 Gi par broker → `data/volumes/redpanda/datadir-redpanda-N/` |
| Réseau | interne au cluster, **sans TLS ni SASL** (labo), pas de NodePort (`external.enabled: false`) |
| Topics | création automatique activée, réplication par défaut 3 |
| Tuning AIO | désactivé (demanderait un conteneur privilégié) |
| Édition | **Community** : fonctions Enterprise désactivées (voir Licence) |

Points d'accès :

| Service | Adresse |
|---|---|
| Kafka | `redpanda.redpanda.svc.cluster.local:9093` (PLAINTEXT) |
| Schema Registry | `http://redpanda.redpanda.svc.cluster.local:8081` |
| HTTP Proxy (PandaProxy) | `http://redpanda.redpanda.svc.cluster.local:8082` |
| Admin API | `http://redpanda.redpanda.svc.cluster.local:9644` |
| **Console** | **https://redpanda.k8s.test** (admin / `make ui-credentials`) |

## Utilisation

```bash
make rp-status                              # santé, topics, licence
make rpk ARGS="topic list"
make rpk ARGS="topic create mon-topic -p 3 -r 3"
echo '{"id":1}' | make rpk ARGS="topic produce mon-topic"
make rpk ARGS="topic consume mon-topic -n 1"
```

Depuis un pod du cluster, n'importe quel client Kafka avec
`bootstrap.servers=redpanda.redpanda.svc.cluster.local:9093`.

## Vérification (testée le 2026-11-11)

- `rpk cluster health` : `Healthy: true`, nœuds `[0 1 2]`, 0 partition sans
  leader ni sous-répliquée ✅
- Topic `demo-events` (3 partitions, réplication 3) : 3 messages produits depuis
  `redpanda-0`, consommés depuis `redpanda-1` ✅
- Console : `https://redpanda.k8s.test` → **401** sans identifiants, **200** avec
  `admin`. L'API `/api/topics` liste `demo-events` ✅
- `rpk cluster license info` : `License violation: false`, aucune fonction
  Enterprise active ✅
- `make diff` : aucun écart ✅

## Licence : Community (BSL) et fonctions Enterprise

> Source : [Redpanda Licensing Overview](https://docs.redpanda.com/current/get-started/licensing/overview/)
> (consultée le 2026-11-11, Redpanda v26.2). À revérifier à chaque montée de version.

### Éditions

| | **Community Edition** | **Enterprise Edition** |
|---|---|---|
| Licence | **Business Source License (BSL 1.1)** : gratuite et source-available, **pas open source au sens OSI** | commerciale (clé de licence) |
| Restriction BSL | interdit de **proposer Redpanda comme service** de streaming ou de file de messages commercial à des tiers. Usage interne, labo et produit : autorisés | — |
| Conversion | chaque contribution passe en **Apache 2.0 quatre ans** après son intégration | — |
| Binaire | **le même** pour Redpanda, Console et Connect : les fonctions Enterprise sont activées par une clé | |

### Essai intégré de 30 jours (notre cas)

Tout nouveau cluster (≥ 24.3) reçoit automatiquement une licence d'essai :

| Élément | Valeur constatée |
|---|---|
| Type | `free_trial`, « Redpanda Built-In Evaluation Period » |
| Expiration | **11 décembre 2026** (30 jours après l'installation) |
| Prolongation | +30 jours une fois : `rpk generate license --apply` (nom, société, e-mail professionnel ; un essai par e-mail/domaine) |

**À l'expiration** : le cluster continue de fonctionner sans perte de données.
Mais :

- les fonctions Enterprise **inactives** sont désactivées et ne peuvent plus être activées ;
- les fonctions Enterprise **actives** passent en mode **restreint**, et Redpanda
  **bloque les montées de version** tant qu'elles restent actives sans licence ;
- la console redirige les pages Enterprise vers une page « licence expirée ».

> ✅ **Décision pour ce projet : rester en Community.** Par défaut, l'essai active
> deux fonctions Enterprise : `partition_autobalancing_mode: continuous` et
> `core_balancing_continuous: true`. Elles ont été **désactivées dans les values**
> (`node_add` et `false`), pour que l'expiration de l'essai n'ait aucun effet.
> Contrôle : `make rp-status` → `License violation: false`, sans ligne
> « Enterprise features in use ».

### Fonctions Enterprise (sous licence)

| Domaine | Fonctions | Sans licence |
|---|---|---|
| Équilibrage | Continuous Data Balancing (`partition_autobalancing_mode: continuous`), Continuous Intra-Broker Partition Balancing (`core_balancing_continuous`), Leader Pinning | retour à `node_add` / désactivé |
| Stockage | **Tiered Storage** (archivage des segments vers S3), Remote Read Replicas, Topic Recovery, Whole Cluster Restore, Cloud Topics | non activables sur de nouveaux topics |
| Lakehouse | **Iceberg Topics** (`redpanda.iceberg.mode`) | non activables |
| Sécurité | RBAC (rôles), Group-Based Access Control, **OIDC / OAUTHBEARER**, Kerberos, FIPS, Audit Logging | création ou modification refusées |
| Schémas | Schema Registry Authorization, validation des ID de schéma côté serveur | non activables |
| Exploitation | Shadowing (réplication entre clusters), Topic Deletion Control, Deferred Upgrade Finalization, Fetch Read Coalescing | désactivé |
| **Console** | **Authentification (OIDC / OAuth 2.0 SSO)**, **RBAC**, génération de *debug bundle*, réassignation de partitions | redirection vers la page « licence expirée » |
| Redpanda Connect | connecteurs Enterprise | bloqués |

### Ce qui reste libre (Community)

- Le broker complet : API Kafka, transactions, idempotence, compaction,
  réplication Raft, quotas, ACL **SASL/SCRAM** et **TLS/mTLS** ;
- le **Schema Registry** et le **HTTP Proxy** ;
- **Redpanda Console** : navigation dans les topics et les messages, production de
  messages, groupes de consommateurs et décalages, schémas, configuration. Sans
  **authentification** : c'est pourquoi on l'a protégée par une
  **authentification basique sur l'Ingress** ;
- `rpk` (CLI) et le chart Helm.

Conséquences pour ce projet :

- Pas de **Tiered Storage** vers Garage : les données restent sur les PVC des
  brokers (10 Gi chacun). Régler la rétention des topics en conséquence
  (`retention.ms`, `retention.bytes`).
- Pas d'**Iceberg Topics** : pour du lakehouse, passer par RisingWave (sink
  Iceberg) ou Redpanda Connect.

### Appliquer une licence (si besoin)

- Kubernetes : `enterprise.license` ou `enterprise.licenseSecretRef` dans les values
  du chart `redpanda` ;
- ou `rpk cluster license set --path <fichier>`, ou import dans la console.

## Pièges rencontrés

- **Fonctions Enterprise actives par défaut** pendant l'essai (rééquilibrage
  continu). Sans action, elles auraient bloqué les montées de version après le
  11/12/2026. → Désactivées dans `config.cluster`.
- **Console sans authentification** en Community. → Basic auth nginx
  (`auth-type: basic`, secret `redpanda-console-auth` dont la clé `auth` est un
  hash bcrypt).
- La console redémarre une fois au premier déploiement : elle démarre avant que
  les brokers soient prêts. Sans conséquence.
- `fs.aio-max-nr` : si on augmente le nombre de cœurs par broker, Redpanda peut
  échouer au démarrage (`Could not setup Async I/O`). Il faut alors augmenter la
  valeur sur l'hôte : `sudo sysctl -w fs.aio-max-nr=1048576` (et la rendre
  persistante dans `/etc/sysctl.d/`).

## Pour aller plus loin

- **Source Kafka dans RisingWave** : ✅ mise en place, voir
  [15 — RisingWave ⇄ Redpanda (source et sink Kafka)](15-risingwave-redpanda.md).
- Activer SASL/SCRAM et TLS (gratuits) pour un usage hors labo.

## Désinstallation

```bash
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l name=redpanda destroy
kubectl -n redpanda delete pvc --all
sudo podman exec k8s rm -rf /mnt/k8s-data/volumes/redpanda     # données
```
