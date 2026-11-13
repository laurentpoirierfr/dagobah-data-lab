---
title: "04 — Helm + helmfile"
weight: 5
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Déclarer toutes les releases Helm du cluster dans `deploy/k8s/helmfile.yaml.gotmpl`
et les appliquer avec `make diff` / `make apply`.

## Installation

Binaires officiels (SHA256 vérifiés) dans `~/.local/bin` :

```bash
curl -fsSLO https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz
curl -fsSLO https://github.com/helmfile/helmfile/releases/download/v1.8.3/helmfile_1.8.3_linux_amd64.tar.gz
# + vérification sha256, extraction, install -m 0755 vers ~/.local/bin
```

Plugin helm-diff :

```bash
helm plugin install https://github.com/databus23/helm-diff --version v3.15.15 --verify=false
```

## Configuration

```
deploy/k8s/
├── helmfile.yaml.gotmpl          # dépôts, helmDefaults (kubeContext: k8s), releases
├── environments/k8s.yaml         # kubeContext, domain, ingressClass, clusterIssuer, storageClass
└── values/<release>.yaml[.gotmpl]
```

## Vérification

```bash
make helm-tools     # helm, helmfile, helm-diff : OK
make lint
make diff           # aucune différence attendue
```

## Pièges rencontrés

- Helm 4 : `Error: plugin source does not support verification`. Il faut ajouter
  `--verify=false` pour les plugins installés depuis git.
- Un fichier de values contenant des `{{ }}` destinés au chart (par exemple
  `pathPattern`) doit rester en `.yaml` et non `.yaml.gotmpl`, sinon helmfile les
  interprète.
- `Skipping refresh for chart … shared cache` : sans conséquence
  (`helmfile cache cleanup` pour forcer le rafraîchissement).
