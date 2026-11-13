# Cluster minikube 3 nœuds du projet k8s.
# Toutes les variables sont surchargeables : make up NODES=2 MEMORY=12g
#
#   make            -> aide
#   make up         -> crée/démarre le cluster, DNS hôte, vérifications

SHELL := /usr/bin/env bash

PROFILE        ?= k8s
NODES          ?= 3
CPUS           ?= 4
MEMORY         ?= 8g
DOMAIN         ?= k8s.test
K8S_VERSION    ?= stable
OTHER_PROFILES ?= minikube
LAUNCHER       ?= $(HOME)/Community/bin/start-minikube-podman.sh
ARGS           ?=

export PROFILE NODES CPUS MEMORY DOMAIN K8S_VERSION OTHER_PROFILES LAUNCHER

CLUSTER := ./cluster.sh
KUBECTL := kubectl --context $(PROFILE)

# helmfile — SELECTOR filtre les releases : make apply SELECTOR=name=podinfo
HELMFILE_FILE ?= deploy/k8s/helmfile.yaml.gotmpl
SELECTOR      ?=
HELMFILE      := helmfile -f $(HELMFILE_FILE) $(if $(SELECTOR),--selector $(SELECTOR))
CA_FILE       ?= certs/$(PROFILE)-ca.crt

.DEFAULT_GOAL := help
.PHONY: help up stop delete recreate status nodes pods dns dns-remove verify dry-run dashboard logs \
        helm-tools lint template diff apply sync releases destroy ca certs cert s3-init ui-credentials \
        rw-status rw-psql rw-forward rw-license cdc-seed rw-cdc-setup cdc-status rpk rp-status \
        rp-topics rp-demo-events rw-kafka-setup rw-kafka-status mon-targets mon-alerts \
        qw-status qw-index-create qw-demo-logs qw-search docs docs-serve docs-view docs-new \
        pg-backup pg-backups pg-restore

# --- Sauvegarde / restauration logique PostgreSQL <-> S3 (par schéma) -------------------
DB     ?= app
SCHEMA ?=
FILE   ?= latest
TARGET ?=
PG_SCHEMA_BACKUP := deploy/k8s/scripts/pg-schema-backup.sh

pg-backup: ## Sauvegarde un schéma vers S3 : make pg-backup DB=app SCHEMA=ventes
	@test -n "$(SCHEMA)" || { echo "SCHEMA requis : make pg-backup DB=app SCHEMA=ventes"; exit 1; }
	@KUBE_CONTEXT=$(PROFILE) $(PG_SCHEMA_BACKUP) backup $(DB) $(SCHEMA)

pg-backups: ## Liste les sauvegardes logiques : make pg-backups DB=app [SCHEMA=ventes]
	@KUBE_CONTEXT=$(PROFILE) $(PG_SCHEMA_BACKUP) list $(DB) $(SCHEMA)

pg-restore: ## Restaure un schéma depuis S3 : make pg-restore DB=app SCHEMA=ventes [FILE=…|latest] [TARGET=autre_base]
	@test -n "$(SCHEMA)" || { echo "SCHEMA requis : make pg-restore DB=app SCHEMA=ventes"; exit 1; }
	@KUBE_CONTEXT=$(PROFILE) $(PG_SCHEMA_BACKUP) restore $(DB) $(SCHEMA) $(FILE) $(if $(TARGET),--target-db $(TARGET))

help: ## Affiche cette aide
	@echo "Cluster '$(PROFILE)' : $(NODES) nœuds, $(CPUS) vCPU / $(MEMORY) par nœud, *.$(DOMAIN)"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Options du lanceur : make up ARGS='--yes'"

up: ## Crée/démarre le cluster + DNS hôte + vérifications
	@$(CLUSTER) up $(ARGS)

stop: ## Arrête le cluster
	@$(CLUSTER) stop

delete: ## Supprime le cluster
	@$(CLUSTER) delete $(ARGS)

recreate: ## Supprime puis recrée le cluster
	@$(CLUSTER) up --recreate --yes $(ARGS)

status: ## État minikube + nœuds
	@$(CLUSTER) status

nodes: ## Nœuds avec rôles et IP
	@$(KUBECTL) get nodes -o wide

pods: ## Tous les pods
	@$(KUBECTL) get pods -A -o wide

dns: ## (Re)configure le DNS hôte du domaine (sudo)
	@$(CLUSTER) dns

dns-remove: ## Retire la config DNS du bridge (sudo)
	@$(CLUSTER) dns-remove

verify: ## Vérifie nœuds, DNS, Ingress, ClusterIssuer
	@$(CLUSTER) verify

dry-run: ## Affiche le plan sans rien lancer
	@$(CLUSTER) dry-run $(ARGS)

dashboard: ## Ouvre le dashboard Kubernetes
	@minikube -p $(PROFILE) dashboard

logs: ## Logs minikube (diagnostic)
	@minikube -p $(PROFILE) logs --length=200

# --- helmfile -----------------------------------------------------------------

helm-tools: ## Vérifie helm, helmfile et le plugin helm-diff
	@helm version --short && helmfile --version
	@helm plugin list 2>/dev/null | grep -q '^diff' \
	  && echo "helm-diff : OK" \
	  || { echo "helm-diff absent : helm plugin install https://github.com/databus23/helm-diff --version v3.15.15"; exit 1; }

lint: ## Lint des charts et values
	@$(HELMFILE) lint

template: ## Rend les manifests sans rien déployer
	@$(HELMFILE) template

diff: ## Aperçu des changements (helm-diff requis)
	@$(HELMFILE) diff

apply: ## Applique uniquement les différences (helm-diff requis)
	@$(HELMFILE) apply

sync: ## Synchronise toutes les releases (sans diff)
	@$(HELMFILE) sync

releases: ## Liste les releases
	@$(HELMFILE) list

destroy: ## Supprime les releases du helmfile
	@$(HELMFILE) destroy

ca: ## Exporte la CA publique (certs/k8s-ca.crt)
	@PROFILE=$(PROFILE) DOMAIN=$(DOMAIN) certs/cert.sh ca-export

certs: ## Écrit les fichiers crt/key de tous les certificats k8s dans certs/issued/
	@PROFILE=$(PROFILE) DOMAIN=$(DOMAIN) certs/cert.sh export-all

cert: ## Fichiers crt/key d'un certificat : make cert HOST=podinfo
	@PROFILE=$(PROFILE) DOMAIN=$(DOMAIN) certs/cert.sh export $(HOST)

# --- S3 (Garage) et interfaces web ---------------------------------------------

s3-init: ## Garage : layout, buckets, clés, secrets k8s, .s3/credentials
	@deploy/k8s/scripts/garage-init.sh $(PROFILE) $(DOMAIN)

ui-credentials: ## Identifiants des interfaces web (Headlamp, garage-webui, pgAdmin, Redpanda, Grafana, Prometheus)
	@echo "Headlamp     https://headlamp.$(DOMAIN)   jeton (valable 24 h) :"
	@$(KUBECTL) -n headlamp create token headlamp --duration=24h
	@echo
	@echo "garage-webui https://garage.$(DOMAIN)     admin / $$($(KUBECTL) -n garage get secret garage-webui-auth -o jsonpath='{.data.password}' | base64 -d)"
	@echo "pgAdmin      https://pgadmin.$(DOMAIN)    admin@example.com / $$($(KUBECTL) -n pgadmin get secret pgadmin-auth -o jsonpath='{.data.password}' | base64 -d)"
	@echo "  serveur pg-main : postgres / $$($(KUBECTL) -n databases get secret pg-main-superuser -o jsonpath='{.data.password}' | base64 -d)"
	@echo "  base app        : app / $$($(KUBECTL) -n databases get secret pg-main-app -o jsonpath='{.data.password}' | base64 -d)"
	@echo "Redpanda     https://redpanda.$(DOMAIN)   admin / $$($(KUBECTL) -n redpanda get secret redpanda-console-auth -o jsonpath='{.data.password}' | base64 -d)"
	@echo "Grafana      https://grafana.$(DOMAIN)    admin / $$($(KUBECTL) -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
	@echo "Quickwit     https://quickwit.$(DOMAIN)   admin / $$($(KUBECTL) -n quickwit get secret quickwit-basic-auth -o jsonpath='{.data.password}' | base64 -d)"
	@echo "Prometheus   https://prometheus.$(DOMAIN) et https://alertmanager.$(DOMAIN)   admin / $$($(KUBECTL) -n monitoring get secret monitoring-basic-auth -o jsonpath='{.data.password}' | base64 -d)"

# --- RisingWave ------------------------------------------------------------------

rw-status: ## État de RisingWave (CR, pods, services)
	@$(KUBECTL) -n risingwave get risingwave,pods,svc

rw-psql: ## Client SQL RisingWave (psql dans le cluster, base dev, utilisateur root)
	@$(KUBECTL) -n risingwave run rw-psql --rm -it --restart=Never --image=postgres:17-alpine -- \
	  psql -h risingwave-frontend.risingwave.svc -p 4567 -U root -d dev

rw-forward: ## Expose le frontend RisingWave sur localhost:4567 (psql -h localhost -p 4567 -U root -d dev)
	@$(KUBECTL) -n risingwave port-forward svc/risingwave-frontend 4567:4567

# --- CDC pg-main -> RisingWave ------------------------------------------------------

cdc-seed: ## Crée les tables de démo dans pg-main/app (customers, orders)
	@$(KUBECTL) -n databases run cdc-seed --rm -i --restart=Never --image=postgres:17-alpine --quiet \
	  --env="PGPASSWORD=$$($(KUBECTL) -n databases get secret pg-main-app -o jsonpath='{.data.password}' | base64 -d)" -- \
	  psql -h pg-main-rw -U app -d app -v ON_ERROR_STOP=1 < deploy/k8s/sql/app/10-cdc-demo.sql

rw-cdc-setup: ## Source CDC + tables + vue dans RisingWave (deploy/k8s/sql/risingwave)
	@$(KUBECTL) -n risingwave run rw-cdc-setup --rm -i --restart=Never --image=postgres:17-alpine --quiet -- \
	  psql -h risingwave-frontend -p 4567 -U root -d dev -v ON_ERROR_STOP=1 \
	  -v cdc_password="$$($(KUBECTL) -n risingwave get secret pg-rw-cdc -o jsonpath='{.data.password}' | base64 -d)" \
	  < deploy/k8s/sql/risingwave/10-cdc-pg-main.sql

cdc-status: ## Slot de réplication côté pg-main + état des tables CDC côté RisingWave
	@$(KUBECTL) -n databases exec $$($(KUBECTL) -n databases get cluster pg-main -o jsonpath='{.status.currentPrimary}') -c postgres -- \
	  psql -U postgres -d app -c "SELECT slot_name, plugin, active, confirmed_flush_lsn, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS retard FROM pg_replication_slots WHERE slot_type = 'logical';"
	@$(KUBECTL) -n risingwave run rw-cdc-status --rm -i --restart=Never --image=postgres:17-alpine --quiet -- \
	  psql -h risingwave-frontend -p 4567 -U root -d dev -c "SELECT * FROM app_revenue_by_city ORDER BY city;"

rw-license: ## Licence RisingWave : clé active, fonctions premium, CPU/mémoire comptés (limite 4 cœurs / 16 Gio)
	@$(KUBECTL) -n risingwave run rw-license --rm -i --restart=Never --image=postgres:17-alpine --quiet -- \
	  psql -h risingwave-frontend -p 4567 -U root -d dev -P pager=off \
	  -c "SELECT rw_license();" \
	  -c "SELECT sum(system_total_cpu_cores) AS cpu_comptes, round(sum(system_total_memory_bytes)/1073741824.0,1) AS memoire_gib FROM rw_worker_nodes;" \
	  -c "SELECT name, available FROM rw_features ORDER BY name;"

# --- Redpanda ----------------------------------------------------------------------

rpk: ## rpk dans le broker redpanda-0 : make rpk ARGS="topic list"
	@$(KUBECTL) -n redpanda exec -i redpanda-0 -c redpanda -- rpk $(ARGS)

rp-status: ## Santé du cluster Redpanda, brokers, topics, licence
	@$(KUBECTL) -n redpanda exec redpanda-0 -c redpanda -- rpk cluster health
	@$(KUBECTL) -n redpanda exec redpanda-0 -c redpanda -- rpk topic list
	@$(KUBECTL) -n redpanda exec redpanda-0 -c redpanda -- rpk cluster license info

# --- Redpanda -> RisingWave (source Kafka) ------------------------------------------

RP_TOPICS ?= shop-events shop-activity-by-city
N         ?= 50

rp-topics: ## Crée les topics du projet (3 partitions, réplication 3), idempotent
	@for t in $(RP_TOPICS); do \
	  $(KUBECTL) -n redpanda exec redpanda-0 -c redpanda -- rpk topic create $$t -p 3 -r 3 2>&1 | tail -n +2 || true; \
	done

rp-demo-events: ## Produit N événements JSON dans shop-events : make rp-demo-events N=100
	@deploy/k8s/scripts/rp-demo-events.sh $(PROFILE) $(N) shop-events

rw-kafka-setup: ## Source Kafka + vues + sink Kafka dans RisingWave (sql/risingwave/20-*)
	@$(KUBECTL) -n risingwave run rw-kafka-setup --rm -i --restart=Never --image=postgres:17-alpine --quiet -- \
	  psql -h risingwave-frontend -p 4567 -U root -d dev -v ON_ERROR_STOP=1 < deploy/k8s/sql/risingwave/20-kafka-redpanda.sql

rw-kafka-status: ## Vues alimentées par Redpanda + derniers messages du sink
	@$(KUBECTL) -n risingwave run rw-kafka-status --rm -i --restart=Never --image=postgres:17-alpine --quiet -- \
	  psql -h risingwave-frontend -p 4567 -U root -d dev -P pager=off \
	  -c "SELECT * FROM shop_activity_by_city ORDER BY city;" \
	  -c "SELECT * FROM shop_events_per_minute ORDER BY window_start DESC, event_type LIMIT 9;"
	@echo "--- topic shop-activity-by-city (sink upsert, dernières valeurs par ville)"
	@$(KUBECTL) -n redpanda exec redpanda-0 -c redpanda -- rpk topic consume shop-activity-by-city -o :end -f '%k => %v\n' | tail -n 6

# --- Supervision ---------------------------------------------------------------------

mon-targets: ## Cibles Prometheus par job (up / down)
	@$(KUBECTL) -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
	  promtool query instant http://localhost:9090 'count by (job, namespace) (up == 1)' 2>/dev/null
	@echo "--- cibles DOWN :"
	@$(KUBECTL) -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
	  promtool query instant http://localhost:9090 'up == 0' 2>/dev/null || true

mon-alerts: ## Alertes actives (hors Watchdog)
	@$(KUBECTL) -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
	  promtool query instant http://localhost:9090 'ALERTS{alertstate="firing", alertname!="Watchdog"}' 2>/dev/null

# --- Quickwit ------------------------------------------------------------------------

QW_URL   := https://quickwit.$(DOMAIN)
QW_CURL   = curl -s --cacert $(CA_FILE) -u "admin:$$($(KUBECTL) -n quickwit get secret quickwit-basic-auth -o jsonpath='{.data.password}' | base64 -d)"
INDEX    ?= demo-logs
Q        ?= *

qw-status: ## Version, nœuds prêts et index Quickwit
	@$(QW_CURL) $(QW_URL)/api/v1/version | jq -r '"Quickwit " + .build.version'
	@$(QW_CURL) $(QW_URL)/api/v1/cluster | jq -r '.ready_nodes[].node_id' | sed 's/^/  prêt : /'
	@$(QW_CURL) $(QW_URL)/api/v1/indexes | jq -r '.[] | "  index : " + .index_config.index_id + "  (" + .index_config.index_uri + ")"'

qw-index-create: ## Crée un index depuis deploy/k8s/quickwit/indexes/$(INDEX).yaml
	@$(QW_CURL) -X POST -H 'Content-Type: application/yaml' --data-binary @deploy/k8s/quickwit/indexes/$(INDEX).yaml \
	  $(QW_URL)/api/v1/indexes | jq -c '{index: .index_config.index_id, uri: .index_uri, message}'

qw-demo-logs: ## Ingère N logs de démo dans demo-logs : make qw-demo-logs N=2000
	@deploy/k8s/scripts/qw-demo-logs.py $(N) | $(QW_CURL) -X POST --data-binary @- \
	  "$(QW_URL)/api/v1/demo-logs/ingest?commit=wait_for" | jq -c .

qw-search: export Q := $(Q)
qw-search: ## Recherche : make qw-search Q='message:"connection refused" AND level:ERROR'
	@$(QW_CURL) -G --data-urlencode "query=$$Q" --data-urlencode "max_hits=5" \
	  $(QW_URL)/api/v1/$(INDEX)/search | jq '{num_hits, elapsed_time_micros, hits: [.hits[] | {timestamp, level, service, message}]}'

# --- Documentation (Hugo + Hextra) ---------------------------------------------------
# Source : work/ (content/docs/installation/*.md) · Site généré : docs/

DOCS_SRC ?= work

docs: ## Génère la documentation statique dans docs/ (Hugo, thème Hextra), consultable aussi en file://
	@cd $(DOCS_SRC) && hugo --gc --minify
	@python3 $(DOCS_SRC)/scripts/file-links.py docs

docs-view: docs ## Sert docs/ tel que généré (serveur statique) : http://localhost:8000
	@echo "http://localhost:8000  (Ctrl+C pour arrêter)"
	@python3 -m http.server 8000 --bind 127.0.0.1 --directory docs

docs-serve: ## Prévisualisation avec rechargement à chaud : http://localhost:1313
	@# --renderToMemory : ne rien écrire dans docs/ (sinon conflit avec « make docs »)
	@cd $(DOCS_SRC) && hugo server --renderToMemory --buildDrafts --disableFastRender --bind 127.0.0.1 --port $(or $(PORT),1313)

docs-new: ## Nouvelle étape d'installation : make docs-new STEP=18-loki
	@test -n "$(STEP)" || { echo "STEP requis, ex. make docs-new STEP=18-loki"; exit 1; }
	@cd $(DOCS_SRC) && hugo new content docs/installation/$(STEP).md --kind installation
