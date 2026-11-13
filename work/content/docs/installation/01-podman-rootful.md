---
title: "01 — Podman rootful"
weight: 2
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Faire tourner les nœuds minikube avec **Podman rootful** (`sudo -n podman`) au
lieu de rootless, pour que l'hôte puisse joindre directement l'IP des nœuds
(DNS ingress-dns, Ingress 80/443).

## Pourquoi pas rootless

| Mode | Réseau des nœuds | Accès depuis l'hôte |
|---|---|---|
| rootless | isolé dans le netns utilisateur de Podman | ❌ `dig @192.168.x.2` expire |
| **rootful** | bridge `podmanN` sur l'hôte | ✅ direct |

En rootless, `ip route get 192.168.49.2` passait par la box (`via 192.168.1.254`)
et seuls les ports publiés sur `127.0.0.1` étaient accessibles.

## Installation

Règle sudoers sans mot de passe pour podman (minikube exécute `sudo -n podman`) :

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/podman" | sudo tee /etc/sudoers.d/minikube-podman
sudo chmod 0440 /etc/sudoers.d/minikube-podman
sudo visudo -c
```

> ⚠️ Cela revient à donner l'équivalent d'un accès root sans mot de passe à
> l'utilisateur.

Le lanceur `~/Community/bin/start-minikube-podman.sh` est passé en rootful par
défaut (`--rootless` reste disponible) et aligne `minikube config rootless`.

## Vérification

```bash
sudo -n podman info >/dev/null && echo OK
minikube config get rootless          # attendu : false
sudo podman ps                        # les nœuds sont visibles ici, pas avec 'podman ps'
```

## Pièges rencontrés

- **Limite de processus (pids)** : Podman rootful impose `pids_limit=2048` par
  conteneur. Le systemd du nœud en déduit `DefaultTasksMax=15%`, soit ~307
  processus par pod. ingress-nginx (16 workers) plantait avec
  `pthread_create() failed (11)`.
  → Le lanceur exécute `podman update --pids-limit=-1` sur chaque nœud, puis
  redémarre le cluster une fois (automatique). Vérification :
  `sudo podman inspect k8s --format '{{.HostConfig.PidsLimit}}'` → `-1`.
