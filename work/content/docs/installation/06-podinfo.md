---
title: "06 — podinfo (démo Ingress + TLS)"
weight: 7
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Valider la chaîne complète : DNS `*.k8s.test` → Ingress nginx → Service → pods,
avec un certificat TLS émis par cert-manager.

## Installation

```bash
make apply SELECTOR=name=podinfo
```

Release `podinfo` : chart `oci://ghcr.io/stefanprodan/charts/podinfo` 6.17.0,
values `deploy/k8s/values/podinfo.yaml.gotmpl` (2 réplicas répartis sur les
workers, Ingress `podinfo.k8s.test`, annotation `cert-manager.io/cluster-issuer`).

## Vérification

```bash
make ca                                                     # exporte certs/k8s-ca.crt
curl --cacert certs/k8s-ca.crt https://podinfo.k8s.test/    # HTTP 200, TLS vérifié
kubectl -n podinfo get certificate                          # podinfo-tls  True
```

> ⚠️ **Navigateur** : pour ouvrir `https://podinfo.k8s.test` sans alerte, la CA
> `certs/k8s-ca.crt` doit être importée comme autorité de certification. Voir
> [08 — Certificats TLS et import dans le navigateur](08-certificats-navigateur.md).

## Désinstallation

```bash
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l name=podinfo destroy
```
