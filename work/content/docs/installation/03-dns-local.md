---
title: "03 — DNS local *.k8s.test"
weight: 4
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Résoudre automatiquement `<app>.k8s.test` vers l'Ingress du cluster, sans
`/etc/hosts` ni `curl --resolve`.

## Fonctionnement

- L'addon **ingress-dns** répond, sur l'IP du control-plane (`192.168.58.2:53`),
  pour chaque hôte déclaré dans un Ingress.
- `cluster.sh dns` route `~k8s.test` vers cette IP **sur le lien du bridge**
  `podman2`, et non dans la section globale de systemd-resolved :

  ```bash
  sudo resolvectl dns podman2 192.168.58.2
  sudo resolvectl domain podman2 '~k8s.test'
  sudo resolvectl default-route podman2 false
  ```

- Cette config ne se mélange pas avec `dagobah.test` (profil `minikube`, drop-in
  global `/etc/systemd/resolved.conf.d/minikube-minikube.conf`).

## Installation

```bash
make dns         # demande le mot de passe sudo
```

À refaire après chaque `make stop`, redémarrage de la machine ou `make recreate`,
car le bridge disparaît (`make up` le fait).

## Vérification

```bash
resolvectl domain podman2               # ~k8s.test
make verify                             # ingress-dns, getent, Ingress HTTP 503
```

## Pièges rencontrés

- `sudo: A terminal is required to authenticate` : la commande a été lancée sans
  terminal. La relancer soi-même (`! make dns` dans Claude Code).
- `.local` est à éviter (mDNS/Avahi) : on utilise `.test` (RFC 2606).

## Désinstallation

```bash
make dns-remove
```
