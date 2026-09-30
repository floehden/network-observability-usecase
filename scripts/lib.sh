# Shared shell helpers for the Makefile targets. Sourced, not executed.
#
# Everything that runs on your machine (infrahubctl, the Python scripts, curl
# against the Gitea API) goes through kubectl port-forwards to 127.0.0.1.
# That keeps the Makefile independent of how a given Kubernetes distribution
# exposes cluster DNS to the host (OrbStack resolves *.svc.cluster.local on the
# host; kind, k3d, minikube, k3s and managed clusters do not).
#
# Expects the Makefile to export: NAMESPACE GITEA_USER GITEA_PASS PYTHON
# GITEA_LOCAL_PORT INFRAHUB_LOCAL_PORT GRAFANA_LOCAL_PORT PROMETHEUS_LOCAL_PORT
#
# Kept compatible with macOS' bash 3.2 (no mapfile, no associative arrays).

GITEA_URL="http://127.0.0.1:${GITEA_LOCAL_PORT}"
INFRAHUB_URL="http://127.0.0.1:${INFRAHUB_LOCAL_PORT}"

_PF_PIDS=""
_cleanup_port_forwards() {
	for pid in $_PF_PIDS; do
		kill "$pid" 2>/dev/null || true
		# Reap it so the local port is free before the next target binds it.
		wait "$pid" 2>/dev/null || true
	done
}
trap _cleanup_port_forwards EXIT

# port_forward <namespace> <service> <local-port> <remote-port> [port-variable]
# Backgrounds a kubectl port-forward and blocks until it is listening. The
# forward is stopped automatically when the calling shell exits.
port_forward() {
	local ns=$1 svc=$2 lport=$3 rport=$4 var=${5:-} log pid i
	log=$(mktemp)
	kubectl port-forward -n "$ns" "svc/$svc" "$lport:$rport" >"$log" 2>&1 &
	pid=$!
	_PF_PIDS="$_PF_PIDS $pid"
	for i in $(seq 1 30); do
		if grep -q "Forwarding from 127.0.0.1:$lport" "$log"; then
			rm -f "$log"
			return 0
		fi
		# If 127.0.0.1 is taken but [::1] is free, kubectl silently forwards only
		# [::1]. The helpers here talk to 127.0.0.1, so treat that as a failure.
		if ! kill -0 "$pid" 2>/dev/null || grep -q "Forwarding from" "$log"; then
			kill "$pid" 2>/dev/null || true
			echo "   ❌ Port-forward to $ns/$svc on local port $lport failed:" >&2
			sed 's/^/      /' "$log" >&2
			if [ -n "$var" ]; then
				echo "      If port $lport is taken, choose another one: make <target> $var=<port>" >&2
			fi
			rm -f "$log"
			return 1
		fi
		sleep 1
	done
	echo "   ❌ Timed out waiting for port-forward to $ns/$svc on local port $lport." >&2
	rm -f "$log"
	return 1
}

# wait_for_http <url> [timeout-seconds]
# Succeeds once the URL answers with anything other than a connection error or
# a 5xx (i.e. the application behind it is up, not just the socket).
wait_for_http() {
	local url=$1 timeout=${2:-60} code i
	for i in $(seq 1 "$timeout"); do
		code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
		case "$code" in
			2??|3??|4??) return 0 ;;
		esac
		sleep 1
	done
	echo "   ❌ Timed out waiting for $url (last HTTP status: ${code:-none})." >&2
	return 1
}

# --- Gitea ----------------------------------------------------------------

use_gitea() {
	port_forward "$NAMESPACE" gitea-http "$GITEA_LOCAL_PORT" 3000 GITEA_LOCAL_PORT
	wait_for_http "$GITEA_URL/api/swagger" 60
}

# gitea_git_url <repo> -> authenticated clone URL through the port-forward
gitea_git_url() {
	printf 'http://%s:%s@127.0.0.1:%s/%s/%s.git' \
		"$GITEA_USER" "$GITEA_PASS" "$GITEA_LOCAL_PORT" "$GITEA_USER" "$1"
}

# gitea_create_repo <name> <description>
gitea_create_repo() {
	curl -s -o /dev/null -X POST "$GITEA_URL/api/v1/user/repos" \
		-H "accept: application/json" -H "Content-Type: application/json" \
		-u "$GITEA_USER:$GITEA_PASS" \
		-d "{\"name\": \"$1\", \"description\": \"$2\", \"private\": false, \"auto_init\": true, \"default_branch\": \"main\"}"
}

# gitea_mint_token <name-prefix> -> prints a new write:repository API token
gitea_mint_token() {
	local resp token
	resp=$(curl -s -X POST "$GITEA_URL/api/v1/users/$GITEA_USER/tokens" \
		-H "Content-Type: application/json" -u "$GITEA_USER:$GITEA_PASS" \
		-d "{\"name\": \"$1-$(date +%s)\", \"scopes\": [\"write:repository\"]}")
	token=$(printf '%s' "$resp" | "$PYTHON" -c 'import sys,json; print(json.load(sys.stdin).get("sha1", ""))' 2>/dev/null || true)
	if [ -z "$token" ]; then
		echo "   ❌ Failed to mint Gitea token: $resp" >&2
		return 1
	fi
	printf '%s' "$token"
}

# gitea_set_secret <repo> <name> <value> -> prints the HTTP status
gitea_set_secret() {
	curl -s -o /dev/null -w "%{http_code}" -X PUT \
		"$GITEA_URL/api/v1/repos/$GITEA_USER/$1/actions/secrets/$2" \
		-H "Content-Type: application/json" -u "$GITEA_USER:$GITEA_PASS" \
		-d "{\"data\": \"$3\"}"
}

# --- Infrahub -------------------------------------------------------------

infrahub_token() {
	local pod
	pod=$(kubectl get pod -l infrahub/service=server -n infrahub -o jsonpath="{.items[0].metadata.name}")
	kubectl exec -n infrahub "$pod" -- printenv INFRAHUB_INITIAL_ADMIN_TOKEN | tr -d "\r"
}

# Port-forwards Infrahub and exports INFRAHUB_ADDRESS / INFRAHUB_API_TOKEN for
# infrahubctl and the Python scripts.
use_infrahub() {
	port_forward infrahub infrahub-infrahub-server "$INFRAHUB_LOCAL_PORT" 8000 INFRAHUB_LOCAL_PORT
	wait_for_http "$INFRAHUB_URL/" 120
	INFRAHUB_API_TOKEN=$(infrahub_token)
	INFRAHUB_ADDRESS="$INFRAHUB_URL"
	export INFRAHUB_ADDRESS INFRAHUB_API_TOKEN
}

# --- Diagnostics ----------------------------------------------------------

# doctor: verify tools, cluster access and gNMI reachability prerequisites.
doctor() {
	local failed=0 cmd
	ok()   { echo "   ✅ $*"; }
	warn() { echo "   ⚠️  $*"; }
	bad()  { echo "   ❌ $*"; failed=1; }

	echo "   Tools:"
	for cmd in kubectl helm flux git curl; do
		if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"; else bad "$cmd not found (see Prerequisites in readme.md)"; fi
	done
	if command -v "$PYTHON" >/dev/null 2>&1 || [ -x "$PYTHON" ]; then
		if "$PYTHON" -c "import yaml, infrahub_sdk" >/dev/null 2>&1; then
			ok "$PYTHON with infrahub-sdk and pyyaml"
		else
			bad "$PYTHON is missing infrahub-sdk/pyyaml. Run 'make venv' (or pip install -r requirements.txt)."
		fi
	else
		bad "$PYTHON not found. Install Python 3, then run 'make venv'."
	fi
	if command -v "$INFRAHUBCTL" >/dev/null 2>&1 || [ -x "$INFRAHUBCTL" ]; then
		ok "infrahubctl"
	else
		bad "infrahubctl not found. Run 'make venv' (or pip install 'infrahub-sdk[ctl]')."
	fi

	echo "   Cluster:"
	if kubectl get nodes --request-timeout=5s >/dev/null 2>&1; then
		ok "kubectl can reach context '${KUBE_CONTEXT:-<none>}'"
	else
		bad "kubectl cannot reach a cluster (context '${KUBE_CONTEXT:-<none>}'). Create one, e.g. 'make kind-up'."
	fi

	echo "   gNMI reachability (GNMI_MODE=$GNMI_MODE):"
	case "$GNMI_MODE" in
		mgmt)
			if command -v docker >/dev/null 2>&1 && docker network inspect "$CLAB_MGMT_NET" >/dev/null 2>&1; then
				ok "containerlab mgmt network '$CLAB_MGMT_NET' exists"
			else
				warn "containerlab mgmt network '$CLAB_MGMT_NET' not found. Deploy the lab first: 'make lab-up'."
			fi
			case "$KUBE_CONTEXT" in
				kind-*)
					local cluster=${KUBE_CONTEXT#kind-} node
					for node in $(kind get nodes --name "$cluster" 2>/dev/null); do
						if docker inspect -f '{{json .NetworkSettings.Networks}}' "$node" 2>/dev/null | grep -q "\"$CLAB_MGMT_NET\""; then
							ok "kind node $node is attached to '$CLAB_MGMT_NET'"
						else
							bad "kind node $node is not attached to '$CLAB_MGMT_NET'. Run 'make lab-connect KIND_CLUSTER=$cluster'."
						fi
					done
					;;
				*)
					warn "Pods must be able to reach the clab mgmt subnet directly. Verify after deploy with 'make check-gnmi'."
					;;
			esac
			;;
		host)
			if [ -n "$GNMI_HOST_IP" ]; then
				ok "dialing $GNMI_HOST_IP on each node's published port"
			else
				bad "GNMI_MODE=host requires GNMI_HOST_IP (set it in local.mk)."
			fi
			;;
		*)
			bad "unknown GNMI_MODE '$GNMI_MODE' (use 'mgmt' or 'host')."
			;;
	esac

	return $failed
}

# check_gnmi: dial every rendered Target from a throwaway pod.
check_gnmi() {
	local targets script="" line name addr host port
	targets=$(kubectl get targets.operator.gnmic.dev -n default \
		-o jsonpath='{range .items[*]}{.metadata.name}={.spec.address}{"\n"}{end}' 2>/dev/null || true)
	if [ -z "$targets" ]; then
		echo "   ❌ No gNMIc Target resources found. Has Flux applied the config repo yet? ('flux get kustomizations')" >&2
		return 1
	fi
	for line in $targets; do
		name=${line%%=*}; addr=${line#*=}; host=${addr%:*}; port=${addr##*:}
		script="$script if nc -z -w 3 $host $port; then echo '   ✅ $name ($addr)'; else echo '   ❌ $name ($addr) unreachable'; fail=1; fi;"
	done
	kubectl delete pod gnmi-reachability -n default --ignore-not-found >/dev/null
	kubectl run gnmi-reachability -n default --rm -i --quiet --restart=Never \
		--image=busybox:1.36 --command -- sh -c "fail=0; $script exit \$fail"
}
