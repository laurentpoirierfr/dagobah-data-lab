---
title: "00 — Prérequis"
weight: 1
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Disposer des outils nécessaires sur l'hôte (Ubuntu, 16 vCPU, 60 Gio de RAM).

## Outils

| Outil | Version | Emplacement | Rôle |
|---|---|---|---|
| Podman | 5.7.0 | `/usr/bin/podman` | moteur de conteneurs (driver minikube) |
| minikube | v1.39.0 | paquet | cluster Kubernetes local |
| kubectl | v1.37.2 | paquet | client Kubernetes |
| helm | v4.3.1 | `~/.local/bin/helm` | gestionnaire de charts |
| helmfile | 1.8.3 | `~/.local/bin/helmfile` | déclaration des releases Helm |
| helm-diff | v3.15.15 | plugin helm | `helmfile diff` / `apply` |
| jq, dig | — | paquets | lanceur et vérifications DNS |
| systemd-resolved | — | système | DNS local |

## Installation

```bash
sudo apt install -y podman minikube kubectl jq dnsutils
```

helm et helmfile : voir [04 — Helm + helmfile](04-helm-helmfile.md).

## Vérification

```bash
podman --version && minikube version && kubectl version --client
systemctl is-active systemd-resolved
stat -fc %T /sys/fs/cgroup        # attendu : cgroup2fs
```

## Remarque

`/usr/bin/docker` est le shim `podman-docker` : il n'y a pas de vrai Docker sur
la machine. `--driver=docker` utiliserait donc Podman.
