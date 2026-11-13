---
title: "11 — Interfaces web (Headlamp, garage-webui, pgAdmin)"
weight: 12
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Piloter le cluster, le S3 et PostgreSQL depuis le navigateur.

| Interface | URL | Pour |
|---|---|---|
| **Headlamp** 0.46.0 | https://headlamp.k8s.test | tout Kubernetes : pods, logs, shell, YAML, Helm, CRD (CNPG, cert-manager…) |
| **garage-webui** 1.1.0 | https://garage.k8s.test | Garage : buckets, clés, navigateur de fichiers, état du cluster |
| **pgAdmin** 9.19 | https://pgadmin.k8s.test | PostgreSQL : requêtes, schémas, tables |
| **Grafana** 13.3.1 | https://grafana.k8s.test | supervision : tableaux de bord et alertes (voir [16](16-supervision.md)) |
| **Prometheus / Alertmanager** | https://prometheus.k8s.test · https://alertmanager.k8s.test | requêtes PromQL, cibles, alertes (basic auth, voir [16](16-supervision.md)) |
| **Quickwit UI** 0.9.3 | https://quickwit.k8s.test | recherche dans les index de logs/traces (basic auth, voir [17](17-quickwit.md)) |
| **Redpanda Console** 3.9.0 | https://redpanda.k8s.test | Kafka/Redpanda : topics, messages, consommateurs, schémas (installée avec Redpanda, voir [14](14-redpanda.md)) |

> ⚠️ Pour ouvrir ces URL sans alerte, la CA locale doit être importée dans le
> navigateur : [08 — Certificats TLS et import dans le navigateur](08-certificats-navigateur.md).

## Prérequis

- [03 — DNS local *.k8s.test](03-dns-local.md), [08 — Certificats TLS et import dans le navigateur](08-certificats-navigateur.md)
- [07](07-postgresql-cloudnativepg.md) et [09](09-s3-garage.md) pour pgAdmin et garage-webui

## Installation

```bash
make apply SELECTOR=tier=ui
```

| Release | Namespace | Chart | Values |
|---|---|---|---|
| `headlamp` | `headlamp` | `headlamp/headlamp` 0.46.0 | `values/headlamp.yaml.gotmpl` |
| `garage-webui` | `garage` | `bjw-s/app-template` 5.3.0 (chart générique) | `values/garage-webui.yaml.gotmpl` |
| `pgadmin` | `pgadmin` | `runix/pgadmin4` 1.71.0 | `values/pgadmin.yaml.gotmpl` |

Les mots de passe sont générés une seule fois par des hooks `prepare`
(`scripts/ensure-secret.sh`) et stockés dans des secrets Kubernetes :

| Secret | Contenu |
|---|---|
| `garage/garage-webui-auth` | `username`, `password`, `AUTH_USER_PASS` (hash bcrypt) |
| `garage/garage-admin-token` | jeton de l'API admin Garage (utilisé par garage-webui) |
| `pgadmin/pgadmin-auth` | mot de passe du compte pgAdmin |

## Connexion

```bash
make ui-credentials
```

Cette commande affiche :

- **Headlamp** : un jeton du service account `headlamp`, valable 24 h, à coller
  dans l'écran de connexion. ⚠️ Ce compte est **cluster-admin**.
- **garage-webui** : `admin` / mot de passe.
- **Redpanda Console** : `admin` / mot de passe. Il s'agit d'une authentification basique
  nginx, car la console Community n'a pas d'authentification propre.
- **pgAdmin** : `admin@example.com` / mot de passe. Les serveurs
  `pg-main (primaire, rw)` et `pg-main (réplicas, ro)` sont préconfigurés
  (groupe `k8s`). Le mot de passe `postgres` est affiché par la même commande.

## Vérification

```bash
kubectl get pods -n headlamp; kubectl get pods -n garage; kubectl get pods -n pgadmin
for h in headlamp garage pgadmin; do
  curl -s -o /dev/null --cacert certs/k8s-ca.crt -w "$h %{http_code}\n" https://$h.k8s.test/
done
```

Tests réalisés le 2026-11-11 :

- HTTPS 200 sur les 3 URL, certificats émis par `dagobah-ca` ✅
- garage-webui : connexion `admin` OK, l'API liste les buckets `cnpg-backups`
  et `projet` ✅
- Headlamp : appel de l'API Kubernetes avec le jeton du service account → 200 ✅
- pgAdmin : « Added 1 Server Group(s) and 2 Server(s) » au démarrage ✅

## Pièges rencontrés

- **garage-webui** n'a pas de chart Helm officiel. Il est déployé avec le chart
  générique `bjw-s/app-template`. Il a besoin du jeton d'API admin de Garage :
  `GARAGE_ADMIN_TOKEN` a été ajouté au StatefulSet Garage (depuis le secret
  `garage-admin-token`) et le service `garage-admin` (port 3903) a été activé.
- **pgAdmin refuse les e-mails en `.test`** (domaine à usage spécial) : on
  utilise `admin@example.com`.
- Le jeton Headlamp expire après 24 h : relancer `make ui-credentials`.

## Désinstallation

```bash
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l tier=ui destroy
```
