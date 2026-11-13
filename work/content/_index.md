---
title: Dagobah Data Lab
layout: hextra-home
---

{{< hextra/hero-badge link="docs/installation" >}}
  <span>Journal d'installation · 18 étapes</span>
  {{< icon name="arrow-circle-right" attributes="height=14" >}}
{{< /hextra/hero-badge >}}

<div class="hx:mt-6 hx:mb-6">
{{< hextra/hero-headline >}}
  Dagobah Data Lab
{{< /hextra/hero-headline >}}
</div>

<div class="hx:mb-12">
{{< hextra/hero-subtitle >}}
  Plateforme de données temps réel auto-hébergée sur Kubernetes :&nbsp;<br class="hx:sm:block hx:hidden" />
  ingestion, streaming SQL, stockage, recherche et supervision.
{{< /hextra/hero-subtitle >}}
</div>

<div class="hx:mb-6">
{{< hextra/hero-button text="Découvrir la plateforme" link="docs" >}}
{{< hextra/hero-button text="Installer" link="docs/installation" style="background: transparent; border: 1px solid currentColor; color: inherit;" >}}
</div>

<div class="hx:mt-6"></div>

{{< hextra/feature-grid >}}
  {{< hextra/feature-card
    title="Ingestion"
    subtitle="CDC PostgreSQL (CloudNativePG) et flux Kafka avec Redpanda : chaque modification arrive en moins de 2 s."
    link="docs/installation/13-cdc-pg-main-risingwave"
  >}}
  {{< hextra/feature-card
    title="Streaming SQL"
    subtitle="RisingWave maintient des vues matérialisées incrémentales, avec jointures flux × tables, et republie dans Redpanda."
    link="docs/installation/12-risingwave"
  >}}
  {{< hextra/feature-card
    title="Stockage"
    subtitle="PostgreSQL 17 en 3 instances avec sauvegardes PITR, S3 Garage répliqué ×3, volumes persistants sur l'hôte."
    link="docs/installation/09-s3-garage"
  >}}
  {{< hextra/feature-card
    title="Recherche"
    subtitle="Quickwit indexe logs et traces directement sur S3, avec une API compatible Elasticsearch."
    link="docs/installation/17-quickwit"
  >}}
  {{< hextra/feature-card
    title="Supervision"
    subtitle="Prometheus, Alertmanager et Grafana avec les tableaux de bord de chaque composant."
    link="docs/installation/16-supervision"
  >}}
  {{< hextra/feature-card
    title="Déclaratif"
    subtitle="Tout est décrit dans helmfile : un make sync recrée la plateforme, avec des secrets générés par des hooks."
    link="docs/installation/04-helm-helmfile"
  >}}
{{< /hextra/feature-grid >}}
