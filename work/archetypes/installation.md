---
{{ $num := index (split .File.ContentBaseName "-") 0 -}}
{{ $n := strings.TrimLeft "0" $num | default "0" -}}
title: "{{ $num }} — {{ replaceRE `^[0-9]+-` `` .File.ContentBaseName | humanize }}"
weight: {{ add (int $n) 1 }}
---

> [!NOTE]
> Statut : ⏳ prévu · Date : {{ now.Format "2006-01-02" }}

## Objectif

Ce que le composant apporte et pourquoi.

## Prérequis

- étapes précédentes nécessaires

## Installation

```bash
# commandes
```

## Configuration

| Fichier | Rôle |
|---|---|

## Vérification

```bash
# commandes de contrôle + résultat attendu
```

## Pièges rencontrés

- symptôme → cause → correctif

## Désinstallation

```bash
```