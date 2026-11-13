---
title: "16 — Supervision (Prometheus, Alertmanager, Grafana)"
weight: 17
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Collecter les métriques du cluster et de tous les composants du projet,
déclencher des alertes et les visualiser dans Grafana.

| Composant | URL | Accès |
|---|---|---|
| **Grafana** 13.3.1 | https://grafana.k8s.test | `admin` / `make ui-credentials` |
| **Prometheus** | https://prometheus.k8s.test | basic auth nginx `admin` |
| **Alertmanager** | https://alertmanager.k8s.test | basic auth nginx `admin` |

## Prérequis

- [05 — Stockage persistant (local-path-provisioner)](05-stockage-persistant.md) (PVC `local-data`)
- [08 — Certificats TLS et import dans le navigateur](08-certificats-navigateur.md) pour ouvrir les URL sans alerte

## Installation

```bash
make apply SELECTOR=name=kube-prometheus-stack     # la stack
make apply                                          # active la collecte dans les autres releases
```

| Release | Namespace | Chart |
|---|---|---|
| `kube-prometheus-stack` | `monitoring` | `prometheus-community/kube-prometheus-stack` 93.2.2 (Prometheus Operator v0.95.2) |

Contenu : Prometheus Operator, Prometheus, Alertmanager, Grafana,
kube-state-metrics, node-exporter (un par nœud), règles d'alerte et tableaux de
bord Kubernetes par défaut.

Secrets (hooks `prepare`, `scripts/ensure-secret.sh`) :

| Secret | Contenu |
|---|---|
| `monitoring/grafana-admin` | `admin-user`, `admin-password` (compte admin Grafana) |
| `monitoring/monitoring-basic-auth` | `auth` (htpasswd bcrypt) pour Prometheus et Alertmanager |

## Configuration (`values/kube-prometheus-stack.yaml.gotmpl`)

| Paramètre | Valeur |
|---|---|
| Sélection des cibles | **tous** les `ServiceMonitor` / `PodMonitor` / `PrometheusRule` / `Probe` du cluster (`*SelectorNilUsesHelmValues: false`) |
| Intervalle de collecte | 30 s |
| Rétention Prometheus | 7 jours, 8 Go maximum, PVC `local-data` 10 Gi |
| Alertmanager | PVC 1 Gi, aucune notification configurée (alertes visibles dans l'UI et dans Grafana) |
| Grafana | PVC 1 Gi, datasources `Prometheus` (uid `prometheus`), `Alertmanager`, alias `Prometheus (RisingWave)` (uid `risedev-prometheus`) |
| Composants minikube désactivés | etcd, kube-controller-manager, kube-scheduler, kube-proxy (et leurs règles) |

### Collecte activée dans les composants

| Composant | Activation (values) | Objet créé | Cibles |
|---|---|---|---|
| PostgreSQL `pg-main` | `cluster.monitoring.enabled` (+ `prometheusRule`) | PodMonitor `pg-main-cluster-podmonitor` + règles CNPG | 3 (port 9187) |
| Opérateur CNPG | `monitoring.podMonitorEnabled` (`cnpg-operator.yaml`) | PodMonitor | 1 |
| Garage | `monitoring.metrics.enabled` + `serviceMonitor` | ServiceMonitor `garage` (`/metrics` de l'API admin) | 3 |
| Redpanda | `monitoring.enabled` | ServiceMonitor `redpanda` (`/public_metrics`) | 3 |
| RisingWave | `monitoring: true` → `enableDefaultServiceMonitor` dans la ressource `RisingWave` | ServiceMonitor `risingwave-risingwave` | 4 (meta, frontend, compute, compactor) |
| Kubernetes | chart | kubelet, cAdvisor, apiserver, CoreDNS, kube-state-metrics, node-exporter | 3 nœuds |

Ces releases déclarent `needs: [monitoring/kube-prometheus-stack]`, parce que les
CRD `ServiceMonitor` / `PodMonitor` doivent exister avant elles.

### Tableaux de bord du projet (dossier **k8s** dans Grafana)

| Tableau de bord | Source |
|---|---|
| CloudNativePG | grafana.com n° 20417 (révision 4) |
| Redpanda Ops Dashboard | `redpanda-data/observability` (GitHub) |
| Garage | dépôt Garage, tag v2.5.0 (`script/telemetry/`) |
| RisingWave (`risingwave_dashboard`) | dépôt RisingWave, tag v3.1.1 (`grafana/risingwave-user-dashboard.json`) |

Ils s'ajoutent aux 25 tableaux de bord Kubernetes de la stack (nœuds, pods,
namespaces, réseau, Prometheus, Alertmanager…), soit 29 au total.

## Utilisation

```bash
make ui-credentials     # mots de passe Grafana et Prometheus/Alertmanager
make mon-targets        # cibles actives par job, et cibles DOWN
make mon-alerts         # alertes actives (hors Watchdog)
```

## Vérification (testée le 2026-11-11)

- 8 pods `monitoring` Running (Prometheus 2/2, Alertmanager 2/2, Grafana 3/3,
  operator, kube-state-metrics, 3 × node-exporter) ✅
- `make mon-targets` : 17 jobs, **aucune cible DOWN** ✅
  (kubelet 9, node-exporter 3, pg-main 3, garage 3, redpanda 3, RisingWave 4…)
- Requêtes via Grafana : `cnpg_collector_up` = 3, `cnpg_pg_replication_streaming_replicas`
  OK, `redpanda_application_uptime_seconds_total` sur 3 brokers, `up` Garage 3/3,
  RisingWave 4/4 ✅
- Alertes actives : uniquement `Watchdog` (signal de vie permanent, normal) ✅
- Prometheus et Alertmanager : **401** sans identifiants, **200** avec ✅
- `make diff` : aucun écart ✅

## Pièges rencontrés

- **`no matches for kind "Alertmanager"`** au premier `diff` : les CRD
  `monitoring.coreos.com` sont installées par le chart lui-même.
  → `disableValidationOnInstall: true` sur la release.
- **Cibles minikube toujours DOWN** (etcd, controller-manager, scheduler,
  kube-proxy écoutent sur 127.0.0.1 dans le nœud) → désactivées avec leurs règles,
  pour éviter des alertes permanentes.
- **Nouveau moniteur sans cible pendant 1 à 2 minutes** : le temps que l'opérateur
  régénère la configuration et que `config-reloader` recharge Prometheus.
  Sans gravité.
- **Tableau de bord RisingWave** : il référence la datasource uid
  `risedev-prometheus` (environnement de développement de RisingWave). → Datasource
  supplémentaire avec cet uid, qui pointe vers le même Prometheus.
- **Tableaux de bord téléchargés depuis Internet** au démarrage de Grafana (init
  container). Sans accès réseau, ils ne sont pas importés.
- **Limites CPU de RisingWave** (≤ 4 cœurs, licence, voir [12](12-risingwave.md)) :
  sous charge, l'alerte `CPUThrottlingHigh` peut se déclencher sur les pods
  RisingWave. Elle est attendue, elle ne signale pas une panne.
- Prometheus et Alertmanager n'ont pas d'authentification native → basic auth nginx
  sur l'Ingress (comme pour la console Redpanda).

## Pour aller plus loin

- Notifications Alertmanager (e-mail, Slack, webhook) : `alertmanager.config`.
- Métriques d'ingress-nginx (addon minikube) et de cert-manager.
- Logs : Loki + Promtail/Alloy, branchés sur le même Grafana.

## Désinstallation

```bash
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l name=kube-prometheus-stack destroy
kubectl delete crd -l app.kubernetes.io/part-of=kube-prometheus-stack   # CRD (optionnel)
```

Désactiver d'abord la collecte (`monitoring`) dans pg-main, cnpg, garage, redpanda
et risingwave : sinon leurs `ServiceMonitor` / `PodMonitor` échouent sans CRD.
