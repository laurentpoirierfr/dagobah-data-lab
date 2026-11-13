---
title: "05 — Stockage persistant (local-path-provisioner)"
weight: 6
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Stocker les volumes (PVC) sur l'hôte, dans `~/Projects/dagobah-data-lab/data`, pour qu'ils
survivent à `make recreate` et restent accessibles depuis n'importe quel nœud.

## Prérequis

- [02 — Cluster minikube 3 nœuds](02-cluster-minikube.md) (montage `--mount-string`)
- [04 — Helm + helmfile](04-helm-helmfile.md)

## Fonctionnement

```
hôte : ~/Projects/dagobah-data-lab/data/volumes/<ns>/<pvc>/data/
         │  bind mount (création du cluster)
nœuds : /mnt/k8s-data/volumes/<ns>/<pvc>/data/      (identique sur les 3 nœuds)
```

Release helmfile `local-path-provisioner` (v0.0.37, chart git) → StorageClass
**par défaut** `local-data` :

| Paramètre | Valeur | Effet |
|---|---|---|
| `sharedFileSystemPath` | `/mnt/k8s-data/volumes` | dossier partagé, pas d'affinité de nœud |
| `volumeBindingMode` | `Immediate` | PVC liés tout de suite |
| `reclaimPolicy` | `Retain` | supprimer un PVC ne supprime pas ses fichiers |
| `pathPattern` | `<ns>/<pvc>/data` | un PVC recréé (même nom) retrouve ses données |

`make up` désactive les addons minikube `storage-provisioner` et
`default-storageclass` (provisioner hostpath mono-nœud `standard`).

## Installation

```bash
make up                                        # montage (création du cluster)
make apply SELECTOR=name=local-path-provisioner
```

## Vérification

```bash
kubectl get sc                                 # local-data (default)
make verify                                    # "Données : … monté (tous les nœuds)"
```

Test réalisé : écriture depuis un pod sur `k8s-m02`, relecture sur `k8s-m03`,
fichier visible sur l'hôte, puis PVC + PV supprimés et recréés → données retrouvées.

## Pièges rencontrés

- **`/data` est réservé par minikube** : il y monte déjà `/var/data` du nœud,
  par-dessus notre bind. Les fichiers restaient dans le nœud et l'hôte voyait un
  dossier vide. → Montage sur `/mnt/k8s-data`.
- **`pathPattern must start with {{ .PVC.Namespace }}/{{ .PVC.Name }}/`** : le
  provisioner impose un sous-dossier. → `<ns>/<pvc>/data`.
- **`parameters: field is immutable`** : on ne peut pas modifier les paramètres
  d'une StorageClass. → `kubectl delete sc local-data` puis `make sync` (sans
  impact sur les PV existants).
- Les fichiers appartiennent à `root` sur l'hôte (conteneurs rootful) : il faut
  `sudo rm` pour les supprimer, ou
  `sudo podman exec k8s rm -rf /mnt/k8s-data/volumes/<ns>/<pvc>`.
- Pour réutiliser les données d'un PVC supprimé : son PV est `Released`. Lancer
  `kubectl delete pv <pv>`, puis recréer le PVC avec le même nom.
