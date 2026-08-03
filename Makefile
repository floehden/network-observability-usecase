# Variables
NAMESPACE := gitea
VALUES_FILE := YAML/gitea-values.yaml
REPO_NAME := network-observability-config
SYNC_REPO := infrahub-sync
GITEA_USER := admin
GITEA_PASS := password123

# Local source dirs that get pushed into the Gitea repos during setup.
FLUX_SRC := repo/network-observability-config
SYNC_SRC := repo/infrahub-sync

# Relay source
RELAY_APP := relay/app.py
RELAY_MANIFESTS := relay/relay-manifests.yaml
RELAY_NS := infrahub-relay

# In-cluster addresses
INFRAHUB_ADDR := http://infrahub-infrahub-server.infrahub.svc.cluster.local:8000
GITEA_INCLUSTER := http://gitea-http.gitea.svc.cluster.local:3000
RELAY_URL := http://infrahub-relay.infrahub-relay.svc.cluster.local/webhook

# --- TARGETS ---

.PHONY: all deploy deploy-gitea bootstrap-repo deploy-runner deploy-telemetry-infra \
	deploy-infrahub configure-infrahub sync-topology bootstrap-workflow deploy-relay \
	configure-webhook deploy-flux test-sync teardown clean status

all: deploy

# The master build command
deploy: deploy-gitea bootstrap-repo deploy-runner deploy-telemetry-infra deploy-infrahub \
	configure-infrahub sync-topology bootstrap-workflow deploy-flux deploy-relay configure-webhook
	@echo "\n🚀 Lab deployment completely fully automated!"

# 1. Setup Namespace, Secrets, and Helm
deploy-gitea:
	@echo "\n📦 Creating namespace and admin secret..."
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic gitea-admin-secret \
		--from-literal=username=admin \
		--from-literal=password=$(GITEA_PASS) \
		-n $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@echo "⛵ Deploying Gitea via Helm..."
	helm repo add gitea-charts https://dl.gitea.com/charts/
	helm repo update
	helm upgrade --install gitea gitea-charts/gitea -f $(VALUES_FILE) -n $(NAMESPACE)

# 2. Wait for Pod and Create Repositories via API
bootstrap-repo:
	@echo "\n⏳ Giving Kubernetes a moment to schedule the pod..."
	@sleep 5
	@echo "⏳ Waiting for Gitea pods to become ready..."
	kubectl wait --for=condition=ready pod -l app=gitea -n $(NAMESPACE) --timeout=300s
	@echo "🛠️ Creating repositories in Gitea..."
	@bash -c ' \
		kubectl port-forward svc/gitea-http 3000:3000 -n $(NAMESPACE) > /dev/null 2>&1 & \
		PF_PID=$$! ; \
		echo "   Polling for HTTP 200 OK on port 3000..." ; \
		RETRY=30 ; \
		while [ $$RETRY -gt 0 ]; do \
			STATUS=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/swagger || true) ; \
			if [ "$$STATUS" = "200" ]; then \
				echo "   ✅ Gitea API is actively responding!" ; \
				break ; \
			fi ; \
			sleep 2 ; \
			RETRY=$$((RETRY-1)) ; \
		done ; \
		if [ $$RETRY -eq 0 ]; then \
			echo "   ❌ Timeout waiting for Gitea API." ; \
			kill $$PF_PID 2>/dev/null || true ; \
			exit 1 ; \
		fi ; \
		echo "   Creating $(REPO_NAME)..." ; \
		curl -s -X POST "http://localhost:3000/api/v1/user/repos" -H "accept: application/json" -H "Content-Type: application/json" -u "$(GITEA_USER):$(GITEA_PASS)" -d "{\"name\": \"$(REPO_NAME)\", \"description\": \"GitOps repo for gnmic-operator\", \"private\": false, \"auto_init\": true, \"default_branch\": \"main\"}" > /dev/null; \
		echo "   Creating $(SYNC_REPO)..." ; \
		curl -s -X POST "http://localhost:3000/api/v1/user/repos" -H "accept: application/json" -H "Content-Type: application/json" -u "$(GITEA_USER):$(GITEA_PASS)" -d "{\"name\": \"$(SYNC_REPO)\", \"description\": \"Infrahub Schema and Generators\", \"private\": false, \"auto_init\": true, \"default_branch\": \"main\"}" > /dev/null; \
		kill $$PF_PID 2>/dev/null || true \
	'
	@echo "✅ Repositories created!"

# 3. Extract Token and Deploy CI/CD Runner
deploy-runner:
	@echo "\n🔑 Generating Act Runner Token and deploying runner..."
	@bash -c ' \
		GITEA_POD=$$(kubectl get pods -n $(NAMESPACE) -l app=gitea -o jsonpath="{.items[0].metadata.name}"); \
		RUNNER_TOKEN=$$(kubectl exec -n $(NAMESPACE) $$GITEA_POD -- gitea --config /data/gitea/conf/app.ini actions generate-runner-token); \
		cat YAML/gitea-runner.yaml | sed "s/TOKEN_PLACEHOLDER/$$RUNNER_TOKEN/g" | sed "s/NAMESPACE_PLACEHOLDER/$(NAMESPACE)/g" | kubectl apply -f - \
	'
	@echo "🏃 Runner deployed!"

# 4. Install Telemetry Infrastructure (Cert-Manager, gNMIC, Prometheus)
deploy-telemetry-infra:
	@echo "\n📡 Installing Cert-Manager..."
	helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.19.4 --namespace cert-manager --create-namespace --set crds.enabled=true
	@echo "🛠️ Installing gNMIC Operator..."
	helm upgrade --install gnmic-operator oci://ghcr.io/gnmic/operator/charts/gnmic-operator --version 0.2.0 --namespace gnmic-operator --create-namespace
	@echo "📊 Installing Prometheus Stack..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace

# 5. Install Infrahub (Source of Truth)
deploy-infrahub:
	@echo "\n🏗️ Installing Infrahub..."
	helm upgrade --install infrahub oci://registry.opsmill.io/opsmill/chart/infrahub --namespace infrahub --create-namespace

# 6. Load Schema into Infrahub
configure-infrahub:
	@echo "\n⏳ Giving Kubernetes a moment to schedule the Infrahub pods..."
	@sleep 10
	@echo "⏳ Waiting for Infrahub APIs to initialize (Neo4j takes a few minutes)..."
	@if ! command -v infrahubctl >/dev/null 2>&1; then \
		echo "❌ ERROR: infrahub-sdk is not installed. Please run 'pip install infrahub-sdk' before deploying." ; \
		exit 1 ; \
	fi
	@echo "   Waiting for infrahub-server pod to become ready..."
	@kubectl wait --for=condition=ready pod -l infrahub/service=server -n infrahub --timeout=600s
	@echo "   Extracting Admin Token and Injecting Topology Models..."
	@bash -c ' \
		INFRAHUB_POD=$$(kubectl get pod -l infrahub/service=server -n infrahub -o jsonpath="{.items[0].metadata.name}"); \
		INFRAHUB_TOKEN=$$(kubectl exec -n infrahub $$INFRAHUB_POD -- printenv INFRAHUB_INITIAL_ADMIN_TOKEN | tr -d "\r"); \
		export INFRAHUB_API_TOKEN="$$INFRAHUB_TOKEN"; \
		export INFRAHUB_ADDRESS="$(INFRAHUB_ADDR)"; \
		infrahubctl schema load YAML/schema.yml \
	'
	@echo "✅ Infrahub schema loaded!"

# 7. Sync Containerlab Topology to Infrahub
sync-topology:
	@echo "\n🐍 Syncing Containerlab Topology into Infrahub..."
	@if ! python3 -c "import yaml; import infrahub_sdk" >/dev/null 2>&1; then \
		echo "❌ ERROR: Python dependencies missing. Run 'pip install infrahub-sdk pyyaml'." ; \
		exit 1 ; \
	fi
	@bash -c ' \
		INFRAHUB_POD=$$(kubectl get pod -l infrahub/service=server -n infrahub -o jsonpath="{.items[0].metadata.name}"); \
		INFRAHUB_TOKEN=$$(kubectl exec -n infrahub $$INFRAHUB_POD -- printenv INFRAHUB_INITIAL_ADMIN_TOKEN | tr -d "\r"); \
		export INFRAHUB_API_TOKEN="$$INFRAHUB_TOKEN"; \
		export INFRAHUB_ADDRESS="$(INFRAHUB_ADDR)"; \
		python3 sync_topology.py \
	'
	@echo "✅ Topology fully synced to the Source of Truth!"

# 7b. Push render script + workflow into infrahub-sync, static manifests into the Flux repo.
bootstrap-workflow:
	@echo "\n📤 Pushing automation into Gitea repositories..."
	@if [ ! -d "$(SYNC_SRC)" ]; then echo "❌ ERROR: $(SYNC_SRC) not found."; exit 1; fi
	@if [ ! -d "$(FLUX_SRC)" ]; then echo "❌ ERROR: $(FLUX_SRC) not found."; exit 1; fi
	@bash -c ' \
		set -e ; \
		kubectl port-forward svc/gitea-http 3000:3000 -n $(NAMESPACE) > /dev/null 2>&1 & \
		PF_PID=$$! ; \
		sleep 3 ; \
		WORK=$$(mktemp -d) ; \
		echo "   Populating $(SYNC_REPO)..." ; \
		git clone -q http://$(GITEA_USER):$(GITEA_PASS)@localhost:3000/$(GITEA_USER)/$(SYNC_REPO).git $$WORK/sync ; \
		cp -r $(SYNC_SRC)/. $$WORK/sync/ ; \
		cd $$WORK/sync ; git add -A ; \
		git -c user.email=bot@lab.local -c user.name=setup commit -q -m "Add render script and sync workflow" || echo "   (nothing new in $(SYNC_REPO))" ; \
		git push -q origin main ; cd - > /dev/null ; \
		echo "   Populating $(REPO_NAME)..." ; \
		git clone -q http://$(GITEA_USER):$(GITEA_PASS)@localhost:3000/$(GITEA_USER)/$(REPO_NAME).git $$WORK/flux ; \
		cp -r $(FLUX_SRC)/. $$WORK/flux/ ; \
		cd $$WORK/flux ; git add -A ; \
		git -c user.email=bot@lab.local -c user.name=setup commit -q -m "Add initial telemetry manifests" || echo "   (nothing new in $(REPO_NAME))" ; \
		git push -q origin main || echo "   (push to $(REPO_NAME) skipped/failed)" ; cd - > /dev/null ; \
		rm -rf $$WORK ; \
		echo "   Minting a push token and setting Gitea Actions secrets on $(SYNC_REPO)..." ; \
		PUSH_TOKEN=$$(curl -s -X POST "http://localhost:3000/api/v1/users/$(GITEA_USER)/tokens" \
			-H "Content-Type: application/json" -u "$(GITEA_USER):$(GITEA_PASS)" \
			-d "{\"name\": \"push-$$(date +%s)\", \"scopes\": [\"write:repository\"]}" \
			| python3 -c "import sys,json; print(json.load(sys.stdin)[\"sha1\"])") ; \
		INFRAHUB_POD=$$(kubectl get pod -l infrahub/service=server -n infrahub -o jsonpath="{.items[0].metadata.name}"); \
		INFRAHUB_TOKEN=$$(kubectl exec -n infrahub $$INFRAHUB_POD -- printenv INFRAHUB_INITIAL_ADMIN_TOKEN | tr -d "\r"); \
		PUSH_STATUS=$$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
			"http://localhost:3000/api/v1/repos/$(GITEA_USER)/$(SYNC_REPO)/actions/secrets/PUSH_PASSWORD" \
			-H "Content-Type: application/json" -u "$(GITEA_USER):$(GITEA_PASS)" \
			-d "{\"data\": \"$$PUSH_TOKEN\"}") ; \
		echo "     PUSH_PASSWORD (token) -> HTTP $$PUSH_STATUS" ; \
		TOK_STATUS=$$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
			"http://localhost:3000/api/v1/repos/$(GITEA_USER)/$(SYNC_REPO)/actions/secrets/INFRAHUB_API_TOKEN" \
			-H "Content-Type: application/json" -u "$(GITEA_USER):$(GITEA_PASS)" \
			-d "{\"data\": \"$$INFRAHUB_TOKEN\"}") ; \
		echo "     INFRAHUB_API_TOKEN -> HTTP $$TOK_STATUS" ; \
		kill $$PF_PID 2>/dev/null || true \
	'
	@echo "✅ Automation pushed and Actions secrets set!"

# 8. Install and Configure Flux GitOps
deploy-flux:
	@if ! command -v flux >/dev/null 2>&1; then \
		echo "❌ ERROR: flux is not installed. Please install it with 'brew install flux' before deploying." ; \
		exit 1 ; \
	fi
	@echo "\n🌀 Installing Flux controllers..."
	flux install
	@echo "🔗 Connecting Flux to local Gitea repository..."
	@cat YAML/flux-system.yaml | sed "s/REPO_NAME_PLACEHOLDER/$(REPO_NAME)/g" | kubectl apply -f -
	@echo "✅ Flux connected!"

# 8b. Deploy the Infrahub->Gitea relay service.
#     The app code is shipped as a ConfigMap built from relay/app.py, so there
#     is no image to build or push — a stock python image runs it.
deploy-relay:
	@echo "\n🔀 Deploying Infrahub->Gitea relay..."
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
	@echo "\n🪝 Wiring Infrahub events -> relay -> Gitea..."
	@bash -c ' \
		set -e ; \
		kubectl port-forward svc/gitea-http 3000:3000 -n $(NAMESPACE) > /dev/null 2>&1 & \
		PF_PID=$$! ; \
		sleep 3 ; \
		echo "   Minting a Gitea API token..." ; \
		TOKEN_JSON=$$(curl -s -X POST "http://localhost:3000/api/v1/users/$(GITEA_USER)/tokens" \
			-H "Content-Type: application/json" -u "$(GITEA_USER):$(GITEA_PASS)" \
			-d "{\"name\": \"relay-dispatch-$$(date +%s)\", \"scopes\": [\"write:repository\"]}") ; \
		GITEA_TOKEN=$$(echo "$$TOKEN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[\"sha1\"])") ; \
		if [ -z "$$GITEA_TOKEN" ]; then echo "   ❌ Failed to mint Gitea token: $$TOKEN_JSON"; kill $$PF_PID 2>/dev/null || true; exit 1; fi ; \
		echo "   Injecting token into relay Secret..." ; \
		kubectl create secret generic relay-secrets \
			--from-literal=GITEA_TOKEN="$$GITEA_TOKEN" \
			--from-literal=SHARED_KEY="" \
			-n $(RELAY_NS) --dry-run=client -o yaml | kubectl apply -f - ; \
		kubectl rollout restart deployment/infrahub-relay -n $(RELAY_NS) ; \
		echo "   Waiting for relay to be ready..." ; \
		kubectl rollout status deployment/infrahub-relay -n $(RELAY_NS) --timeout=120s ; \
		echo "   Creating the Infrahub webhook -> relay..." ; \
		INFRAHUB_POD=$$(kubectl get pod -l infrahub/service=server -n infrahub -o jsonpath="{.items[0].metadata.name}"); \
		INFRAHUB_TOKEN=$$(kubectl exec -n infrahub $$INFRAHUB_POD -- printenv INFRAHUB_INITIAL_ADMIN_TOKEN | tr -d "\r"); \
		export INFRAHUB_API_TOKEN="$$INFRAHUB_TOKEN"; \
		export INFRAHUB_ADDRESS="$(INFRAHUB_ADDR)"; \
		python3 configure_webhook.py "$(RELAY_URL)" "" ; \
		kill $$PF_PID 2>/dev/null || true \
	'
	@echo "✅ Loop wired! Infrahub change -> relay -> Gitea workflow -> Flux."

# 8d. Manually fire the workflow to validate render+commit without a real change.
test-sync:
	@echo "\n🧪 Manually triggering the sync workflow via Gitea workflow_dispatch..."
	@bash -c ' \
		set -e ; \
		kubectl port-forward svc/gitea-http 3000:3000 -n $(NAMESPACE) > /dev/null 2>&1 & \
		PF_PID=$$! ; \
		sleep 4 ; \
		HTTP=$$(curl -s -o /dev/null -w "%{http_code}" -X POST \
			"http://localhost:3000/api/v1/repos/$(GITEA_USER)/$(SYNC_REPO)/actions/workflows/sync-targets.yaml/dispatches" \
			-H "Content-Type: application/json" -u "$(GITEA_USER):$(GITEA_PASS)" \
			-d "{\"ref\": \"main\"}") ; \
		if [ "$$HTTP" = "204" ]; then \
			echo "   ✅ Workflow dispatched (HTTP 204). Check the Actions tab of $(SYNC_REPO)." ; \
		else \
			echo "   ❌ Dispatch failed (HTTP $$HTTP)." ; \
		fi ; \
		kill $$PF_PID 2>/dev/null || true \
	'

# 9. The "Scorched Earth" Cleanup Command
teardown: clean
clean:
	@echo "\n🔥 Tearing down the lab..."
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
status:
	@echo "\n📊 Checking Pods..."
	kubectl get pods -A | grep -E 'gitea|cert-manager|gnmic|monitoring|infrahub|relay'
	@echo "\n📊 Checking Flux Sync Status..."
	flux get kustomizations