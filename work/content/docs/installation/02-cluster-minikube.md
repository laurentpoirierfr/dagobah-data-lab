---
title: "02 — Cluster minikube 3 nœuds"
weight: 3
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Cluster Kubernetes local à 3 nœuds (1 control-plane + 2 workers), avec Ingress,
ingress-dns, metrics-server et cert-manager.

## Prérequis

- [01 — Podman rootful](01-podman-rootful.md)

## Installation

```bash
cd ~/Projects/dagobah-data-lab
make dry-run     # plan sans rien lancer
make up          # crée/démarre + DNS (03) + vérifications
```

`cluster.sh` appelle le lanceur `~/Community/bin/start-minikube-podman.sh` avec :

```
--profile k8s --nodes 3 --cpus 4 --memory 8g --domain k8s.test
--mount-string ~/Projects/dagobah-data-lab/data:/mnt/k8s-data     # voir 05
--no-host-dns --no-verify-dns                        # DNS géré par cluster.sh (03)
```

`make up` arrête aussi le profil `minikube` (1 nœud, `dagobah.test`) pour libérer
les ressources.

## Configuration

| Élément | Valeur |
|---|---|
| Profil / contexte | `k8s` |
| Nœuds | `k8s` (control-plane), `k8s-m02`, `k8s-m03` |
| IP | `192.168.58.2` à `.4`, bridge `podman2` |
| Ressources | 4 vCPU / 8 Gio par nœud (24 Gio au total) |
| Kubernetes / runtime / CNI | v1.37.0 / containerd / kindnet |
| Addons | ingress, ingress-dns, metrics-server |
| cert-manager | v1.21.3, ClusterIssuer `dagobah-ca-issuer` |

Variables surchargeables : `make up NODES=2 CPUS=2 MEMORY=6g`.

## Vérification

```bash
make verify
make nodes       # 3 nœuds Ready
```

## Pièges rencontrés

- La configuration DNS demande le mot de passe sudo : `make up` s'arrête à cette
  étape si on le lance sans terminal. Relancer `make dns` (voir 03).
- Changer le montage des données (`DATA_DIR`) impose `make recreate`, parce
  qu'un bind mount ne se pose qu'à la création des nœuds.

## Désinstallation

```bash
make delete
```
