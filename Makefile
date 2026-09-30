# Bash everywhere: macOS, Linux and WSL all ship /bin/bash, and the recipes
# (plus scripts/lib.sh) rely on it rather than on whatever /bin/sh happens to be.
SHELL := /bin/bash

# Per-machine overrides go in local.mk (git-ignored). See local.mk.example.
-include local.mk

# Variables
NAMESPACE ?= gitea
VALUES_FILE := YAML/gitea-values.yaml
REPO_NAME := network-observability-config
SYNC_REPO := infrahub-sync
GITEA_USER ?= admin
GITEA_PASS ?= password123

# Local source dirs that get pushed into the Gitea repos during setup.
FLUX_SRC := repo/network-observability-config
SYNC_SRC := repo/infrahub-sync

# Relay source
RELAY_APP := relay/app.py
RELAY_MANIFESTS := relay/relay-manifests.yaml
RELAY_NS := infrahub-relay

# In-cluster addresses. These are stored in Infrahub/Flux and used from inside
# the cluster only; everything run from your machine goes through port-forwards.
INFRAHUB_ADDR := http://infrahub-infrahub-server.infrahub.svc.cluster.local:8000
GITEA_INCLUSTER := http://gitea-http.gitea.svc.cluster.local:3000
RELAY_URL := http://infrahub-relay.infrahub-relay.svc.cluster.local/webhook

# Local ports for the port-forwards opened by the targets below and by `make ui`.
# Gitea and Prometheus stay off 3000/9090 because the containerlab Grafana and
# Prometheus publish those on the host.
INFRAHUB_LOCAL_PORT ?= 8000
GITEA_LOCAL_PORT ?= 3030
GRAFANA_LOCAL_PORT ?= 3001
PROMETHEUS_LOCAL_PORT ?= 9091

# Python tooling: prefer the project venv created by `make venv`.
ifneq ($(wildcard .venv/bin/python),)
PYTHON ?= .venv/bin/python
INFRAHUBCTL ?= .venv/bin/infrahubctl
endif
PYTHON ?= python3
INFRAHUBCTL ?= infrahubctl

KUBE_CONTEXT := $(shell kubectl config current-context 2>/dev/null)

# How gNMIc (in the cluster) reaches the SR Linux nodes:
#   mgmt - dial each node's containerlab mgmt IP on 57400. Needs the cluster
#          nodes on the clab mgmt network (`make lab-connect` does that for kind).
#   host - dial GNMI_HOST_IP on each node's published host port.
# OrbStack defaults to host mode with the IP its pods use to reach the Docker host.
ifeq ($(KUBE_CONTEXT),orbstack)
GNMI_MODE ?= host
GNMI_HOST_IP ?= 192.168.139.126
endif
GNMI_MODE ?= mgmt
GNMI_HOST_IP ?=

# Containerlab
CLAB_TOPO ?= YAML/st.clab.yml
CLAB_MGMT_NET ?= st
KIND_CLUSTER ?= netobs
# Use a local containerlab install if there is one, otherwise run it from its
# container image (the documented way on macOS and Windows/WSL).
ifneq ($(shell command -v containerlab 2>/dev/null),)
CLAB ?= sudo containerlab
else
CLAB ?= docker run --rm --privileged --network host --pid host \
	-v /var/run/docker.sock:/var/run/docker.sock -v /run/netns:/run/netns \
	-v "$(CURDIR)":"$(CURDIR)" -w "$(CURDIR)" ghcr.io/srl-labs/clab containerlab
endif

export NAMESPACE GITEA_USER GITEA_PASS PYTHON INFRAHUBCTL KUBE_CONTEXT \
	GNMI_MODE GNMI_HOST_IP CLAB_MGMT_NET \
	GITEA_LOCAL_PORT INFRAHUB_LOCAL_PORT GRAFANA_LOCAL_PORT PROMETHEUS_LOCAL_PORT

# --- TARGETS ---

.PHONY: all help venv doctor up down kind-up kind-down lab-up lab-down lab-connect \
	deploy deploy-gitea bootstrap-repo deploy-runner deploy-telemetry-infra \
	deploy-infrahub configure-infrahub sync-topology bootstrap-workflow deploy-relay \
	configure-webhook deploy-flux test-sync check-gnmi ui teardown clean status

all: deploy

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# 0. Local tooling and preflight checks
venv: ## Create .venv with infrahub-sdk, infrahubctl and pyyaml
	python3 -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -r requirements.txt
	@echo "✅ .venv ready — the Makefile picks it up automatically."

doctor: ## Check tools, cluster access and gNMI reachability prerequisites
	@printf '\n🩺 Preflight checks (context: %s)\n' "$(KUBE_CONTEXT)"
	@source scripts/lib.sh; doctor

# 0b. Optional: a kind cluster + the containerlab fabric, wired together.
#     Works anywhere Docker runs (Linux, macOS, Windows via WSL2).
up: lab-up kind-up lab-connect ## Lab + kind cluster + full deploy, from scratch
	$(MAKE) deploy GNMI_MODE=mgmt

down: kind-down lab-down ## Delete the kind cluster and destroy the lab

kind-up: ## Create the kind cluster
	@if kind get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)"; then \
		echo "   ℹ️ kind cluster '$(KIND_CLUSTER)' already exists."; \
	else \
		kind create cluster --name $(KIND_CLUSTER); \
	fi

kind-down: ## Delete the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

lab-up: ## Deploy the containerlab fabric
	$(CLAB) deploy -t $(CLAB_TOPO)

lab-down: ## Destroy the containerlab fabric
	$(CLAB) destroy -t $(CLAB_TOPO) --cleanup

lab-connect: ## Attach the kind nodes to the containerlab mgmt network
	@printf '\n🔗 Attaching kind nodes to the containerlab mgmt network "%s"...\n' "$(CLAB_MGMT_NET)"
	@NODES=$$(kind get nodes --name $(KIND_CLUSTER) 2>/dev/null); \
	if [ -z "$$NODES" ]; then echo "   ❌ No nodes found for kind cluster '$(KIND_CLUSTER)'."; exit 1; fi; \
	for node in $$NODES; do \
		if docker inspect -f '{{json .NetworkSettings.Networks}}' $$node | grep -q '"$(CLAB_MGMT_NET)"'; then \
			echo "   ℹ️ $$node already attached."; \
		else \
			docker network connect $(CLAB_MGMT_NET) $$node && echo "   ✅ $$node attached."; \
		fi; \
	done

# The master build command
DEPLOY_STEPS := doctor deploy-gitea bootstrap-repo deploy-runner deploy-telemetry-infra deploy-infrahub \
	configure-infrahub sync-topology bootstrap-workflow deploy-flux deploy-relay configure-webhook
deploy: $(DEPLOY_STEPS) ## Deploy the whole platform into the current cluster
	@printf '\n🚀 Lab deployment completely fully automated!\n'
	@echo "   Next: 'make check-gnmi' to confirm the collector can reach every device, 'make ui' to open the UIs."

# 1. Setup Namespace, Secrets, and Helm
deploy-gitea:
	@printf '\n📦 Creating namespace and admin secret...\n'
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic gitea-admin-secret \
		--from-literal=username=$(GITEA_USER) \
		--from-literal=password=$(GITEA_PASS) \
		-n $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@echo "⛵ Deploying Gitea via Helm..."
	helm repo add gitea-charts https://dl.gitea.com/charts/ --force-update
	helm repo update
	helm upgrade --install gitea gitea-charts/gitea -f $(VALUES_FILE) -n $(NAMESPACE) \
		--set gitea.config.server.ROOT_URL=http://localhost:$(GITEA_LOCAL_PORT)/

# 2. Wait for Pod and Create Repositories via API
bootstrap-repo:
	@printf '\n⏳ Giving Kubernetes a moment to schedule the pod...\n'
	@sleep 5
	@echo "⏳ Waiting for Gitea pods to become ready..."
	kubectl wait --for=condition=ready pod -l app=gitea -n $(NAMESPACE) --timeout=300s
	@echo "🛠️ Creating repositories in Gitea..."
	@set -e; source scripts/lib.sh; use_gitea; \
	echo "   Creating $(REPO_NAME)..."; \
	gitea_create_repo $(REPO_NAME) "GitOps repo for gnmic-operator"; \
	echo "   Creating $(SYNC_REPO)..."; \
	gitea_create_repo $(SYNC_REPO) "Infrahub Schema and Generators"
	@echo "✅ Repositories created!"

# 3. Extract Token and Deploy CI/CD Runner
deploy-runner:
	@printf '\n🔑 Generating Act Runner Token and deploying runner...\n'
	@set -e; \
	GITEA_POD=$$(kubectl get pods -n $(NAMESPACE) -l app=gitea -o jsonpath="{.items[0].metadata.name}"); \
	RUNNER_TOKEN=$$(kubectl exec -n $(NAMESPACE) $$GITEA_POD -- gitea --config /data/gitea/conf/app.ini actions generate-runner-token | tr -d "\r"); \
	sed -e "s/TOKEN_PLACEHOLDER/$$RUNNER_TOKEN/g" -e "s/NAMESPACE_PLACEHOLDER/$(NAMESPACE)/g" YAML/gitea-runner.yaml | kubectl apply -f -
	@echo "🏃 Runner deployed!"

# 4. Install Telemetry Infrastructure (Cert-Manager, gNMIC, Prometheus)
deploy-telemetry-infra:
	@printf '\n📡 Installing Cert-Manager...\n'
	helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.19.4 --namespace cert-manager --create-namespace --set crds.enabled=true
	@echo "🛠️ Installing gNMIC Operator..."
	helm upgrade --install gnmic-operator oci://ghcr.io/gnmic/operator/charts/gnmic-operator --version 0.2.0 --namespace gnmic-operator --create-namespace
	@echo "📊 Installing Prometheus Stack..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace

# 5. Install Infrahub (Source of Truth)
deploy-infrahub:
	@printf '\n🏗️ Installing Infrahub...\n'
	helm upgrade --install infrahub oci://registry.opsmill.io/opsmill/chart/infrahub --namespace infrahub --create-namespace

# 6. Load Schema into Infrahub
configure-infrahub:
	@printf '\n⏳ Giving Kubernetes a moment to schedule the Infrahub pods...\n'
	@sleep 10
	@echo "⏳ Waiting for Infrahub APIs to initialize (Neo4j takes a few minutes)..."
	@echo "   Waiting for infrahub-server pod to become ready..."
	@kubectl wait --for=condition=ready pod -l infrahub/service=server -n infrahub --timeout=600s
	@echo "   Extracting Admin Token and Injecting Topology Models..."
	@set -e; source scripts/lib.sh; use_infrahub; \
	"$(INFRAHUBCTL)" schema load YAML/schema.yml
	@echo "✅ Infrahub schema loaded!"

# 7. Sync Containerlab Topology to Infrahub
sync-topology:
	@printf '\n🐍 Syncing Containerlab Topology into Infrahub (GNMI_MODE=%s)...\n' "$(GNMI_MODE)"
	@set -e; source scripts/lib.sh; use_infrahub; \
	CLAB_FILE="$(CLAB_TOPO)" GNMI_MODE="$(GNMI_MODE)" GNMI_HOST_IP="$(GNMI_HOST_IP)" \
		"$(PYTHON)" sync_topology.py
	@echo "✅ Topology fully synced to the Source of Truth!"

# 7b. Push render script + workflow into infrahub-sync, and the manifests into
#     the Flux repo. 02-targets.yaml is rendered from Infrahub here, so Flux's
#     first reconcile already has the right device addresses for this machine.
bootstrap-workflow:
	@printf '\n📤 Pushing automation into Gitea repositories...\n'
	@if [ ! -d "$(SYNC_SRC)" ]; then echo "❌ ERROR: $(SYNC_SRC) not found."; exit 1; fi
	@if [ ! -d "$(FLUX_SRC)" ]; then echo "❌ ERROR: $(FLUX_SRC) not found."; exit 1; fi
	@set -e; source scripts/lib.sh; use_gitea; use_infrahub; \
	WORK=$$(mktemp -d); \
	echo "   Populating $(SYNC_REPO)..."; \
	git clone -q "$$(gitea_git_url $(SYNC_REPO))" "$$WORK/sync"; \
	cp -r $(SYNC_SRC)/. "$$WORK/sync/"; \
	git -C "$$WORK/sync" add -A; \
	git -C "$$WORK/sync" -c user.email=bot@lab.local -c user.name=setup commit -q -m "Add render script and sync workflow" || echo "   (nothing new in $(SYNC_REPO))"; \
	git -C "$$WORK/sync" push -q origin main; \
	echo "   Populating $(REPO_NAME) (rendering 02-targets.yaml from Infrahub)..."; \
	git clone -q "$$(gitea_git_url $(REPO_NAME))" "$$WORK/flux"; \
	cp -r $(FLUX_SRC)/. "$$WORK/flux/"; \
	OUTPUT_FILE="$$WORK/flux/02-targets.yaml" "$(PYTHON)" $(SYNC_SRC)/render_targets.py; \
	git -C "$$WORK/flux" add -A; \
	git -C "$$WORK/flux" -c user.email=bot@lab.local -c user.name=setup commit -q -m "Add initial telemetry manifests" || echo "   (nothing new in $(REPO_NAME))"; \
	git -C "$$WORK/flux" push -q origin main || echo "   (push to $(REPO_NAME) skipped/failed)"; \
	rm -rf "$$WORK"; \
	echo "   Minting a push token and setting Gitea Actions secrets on $(SYNC_REPO)..."; \
	PUSH_TOKEN=$$(gitea_mint_token push); \
	echo "     PUSH_PASSWORD (token) -> HTTP $$(gitea_set_secret $(SYNC_REPO) PUSH_PASSWORD "$$PUSH_TOKEN")"; \
	echo "     INFRAHUB_API_TOKEN -> HTTP $$(gitea_set_secret $(SYNC_REPO) INFRAHUB_API_TOKEN "$$INFRAHUB_API_TOKEN")"
	@echo "✅ Automation pushed and Actions secrets set!"

# 8. Install and Configure Flux GitOps
deploy-flux:
	@if ! command -v flux >/dev/null 2>&1; then \
		echo "❌ ERROR: flux is not installed. See https://fluxcd.io/flux/installation/#install-the-flux-cli" ; \
		exit 1 ; \
	fi
	@printf '\n🌀 Installing Flux controllers...\n'
	flux install
	@echo "🔗 Connecting Flux to local Gitea repository..."
	@sed "s/REPO_NAME_PLACEHOLDER/$(REPO_NAME)/g" YAML/flux-system.yaml | kubectl apply -f -
	@echo "✅ Flux connected!"

# 8b. Deploy the Infrahub->Gitea relay service.
#     The app code is shipped as a ConfigMap built from relay/app.py, so there
#     is no image to build or push — a stock python image runs it.
deploy-relay:
	@printf '\n🔀 Deploying Infrahub->Gitea relay...\n'
	@if [ ! -f "$(RELAY_APP)" ]; then echo "❌ ERROR: $(RELAY_APP) not found."; exit 1; fi
	kubectl apply -f $(RELAY_MANIFESTS)
	@echo "   Building relay-code ConfigMap from $(RELAY_APP)..."
	kubectl create configmap relay-code \
		--from-file=app.py=$(RELAY_APP) \
		-n $(RELAY_NS) --dry-run=client -o yaml | kubectl apply -f -
	@echo "   Restarting relay to pick up code..."
	kubectl rollout restart deployment/infrahub-relay -n $(RELAY_NS)
	@echo "✅ Relay deployed!"

# 8c. Mint Gitea token, inject into relay Secret, point Infrahub webhook at relay.
configure-webhook:
	@printf '\n🪝 Wiring Infrahub events -> relay -> Gitea...\n'
	@set -e; source scripts/lib.sh; use_gitea; use_infrahub; \
	echo "   Minting a Gitea API token..."; \
	GITEA_TOKEN=$$(gitea_mint_token relay-dispatch); \
	echo "   Injecting token into relay Secret..."; \
	kubectl create secret generic relay-secrets \
		--from-literal=GITEA_TOKEN="$$GITEA_TOKEN" \
		--from-literal=SHARED_KEY="" \
		-n $(RELAY_NS) --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl rollout restart deployment/infrahub-relay -n $(RELAY_NS); \
	echo "   Waiting for relay to be ready..."; \
	kubectl rollout status deployment/infrahub-relay -n $(RELAY_NS) --timeout=120s; \
	echo "   Creating the Infrahub webhook -> relay..."; \
	"$(PYTHON)" configure_webhook.py "$(RELAY_URL)" ""
	@echo "✅ Loop wired! Infrahub change -> relay -> Gitea workflow -> Flux."

# 8d. Manually fire the workflow to validate render+commit without a real change.
test-sync: ## Trigger the render workflow without changing Infrahub
	@printf '\n🧪 Manually triggering the sync workflow via Gitea workflow_dispatch...\n'
	@set -e; source scripts/lib.sh; use_gitea; \
	HTTP=$$(curl -s -o /dev/null -w "%{http_code}" -X POST \
		"$$GITEA_URL/api/v1/repos/$(GITEA_USER)/$(SYNC_REPO)/actions/workflows/sync-targets.yaml/dispatches" \
		-H "Content-Type: application/json" -u "$(GITEA_USER):$(GITEA_PASS)" \
		-d "{\"ref\": \"main\"}"); \
	if [ "$$HTTP" = "204" ]; then \
		echo "   ✅ Workflow dispatched (HTTP 204). Check the Actions tab of $(SYNC_REPO)."; \
	else \
		echo "   ❌ Dispatch failed (HTTP $$HTTP)."; \
	fi

# 8e. Dial every rendered Target from inside the cluster.
check-gnmi: ## Test that pods can reach every device's gNMI port
	@printf '\n🔎 Testing gNMI reachability from inside the cluster...\n'
	@source scripts/lib.sh; check_gnmi

# 8f. Port-forward all UIs at once and print their credentials.
ui: ## Port-forward Infrahub, Gitea, Grafana and Prometheus
	@set -e; source scripts/lib.sh; \
	port_forward infrahub infrahub-infrahub-server $(INFRAHUB_LOCAL_PORT) 8000 INFRAHUB_LOCAL_PORT; \
	port_forward $(NAMESPACE) gitea-http $(GITEA_LOCAL_PORT) 3000 GITEA_LOCAL_PORT; \
	port_forward monitoring prometheus-grafana $(GRAFANA_LOCAL_PORT) 80 GRAFANA_LOCAL_PORT; \
	port_forward monitoring prometheus-operated $(PROMETHEUS_LOCAL_PORT) 9090 PROMETHEUS_LOCAL_PORT; \
	GRAFANA_PASS=$$(kubectl get secret prometheus-grafana -n monitoring -o jsonpath="{.data.admin-password}" \
		| "$(PYTHON)" -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode())'); \
	printf '\n  %-11s %-26s %s\n' \
		Infrahub   "http://localhost:$(INFRAHUB_LOCAL_PORT)"   "token: $$(infrahub_token)" \
		Gitea      "http://localhost:$(GITEA_LOCAL_PORT)"      "$(GITEA_USER) / $(GITEA_PASS)" \
		Grafana    "http://localhost:$(GRAFANA_LOCAL_PORT)"    "admin / $$GRAFANA_PASS" \
		Prometheus "http://localhost:$(PROMETHEUS_LOCAL_PORT)" ""; \
	printf '\n  Press Ctrl-C to stop the port-forwards.\n'; \
	wait

# 9. The "Scorched Earth" Cleanup Command
teardown: clean
clean: ## Remove everything this Makefile installed from the cluster
	@printf '\n🔥 Tearing down the lab...\n'
	helm uninstall gitea -n $(NAMESPACE) > /dev/null 2>&1 || true
	kubectl delete namespace $(NAMESPACE) --ignore-not-found=true
	helm uninstall cert-manager -n cert-manager > /dev/null 2>&1 || true
	kubectl delete namespace cert-manager --ignore-not-found=true
	helm uninstall gnmic-operator -n gnmic-operator > /dev/null 2>&1 || true
	kubectl delete namespace gnmic-operator --ignore-not-found=true
	helm uninstall prometheus -n monitoring > /dev/null 2>&1 || true
	kubectl delete namespace monitoring --ignore-not-found=true
	helm uninstall infrahub -n infrahub > /dev/null 2>&1 || true
	kubectl delete namespace infrahub --ignore-not-found=true
	kubectl delete namespace $(RELAY_NS) --ignore-not-found=true
	flux uninstall -s || true
	@echo "🗑️ Lab destroyed. Ready for a fresh start!"

# 10. Check Lab Health
status: ## Show pod and Flux status
	@printf '\n📊 Checking Pods...\n'
	kubectl get pods -A | grep -E 'gitea|cert-manager|gnmic|monitoring|infrahub|relay'
	@printf '\n📊 Checking Flux Sync Status...\n'
	flux get kustomizations
