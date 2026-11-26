#!/bin/bash
#
# Der Versuch, an dem die StackIT-Planung haengt: baut k0s auf CAPSTK?
#
# CAPSTK liest seine Bootstrap-Daten anbieterneutral aus
# `Machine.spec.bootstrap.dataSecretName` - aber alle seine Vorlagen und
# Codekommentare sprechen von kubeadm. Dass k0smotron dort funktioniert, ist
# plausibel und **unbewiesen**. Dieses Skript trennt die beiden Fragen, damit
# ein Fehlschlag etwas bedeutet:
#
#   phase-a  Zugangsdaten, Quota, Netz und Abbild stimmen - mit CAPSTKs
#            eigener kubeadm-Vorlage. Scheitert das, liegt es an StackIT
#            oder am Konto, nicht an uns.
#   phase-b  dasselbe mit unserem k0s-Chart. Scheitert erst das, ist es die
#            Bootstrap-Frage - und damit das Tor fuer enopax/enopax#51.
#
# Laeuft gegen einen **kind**-Cluster auf diesem Rechner, nicht gegen
# enopax-mgmt. Nichts hier beruehrt die Produktion.
#
# Siehe enopax/enopax#51.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="STACKIT-SPIKE"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

CAPSTK_VERSION="${CAPSTK_VERSION:-v0.1.0-alpha.5}"
KIND_CLUSTER="${KIND_CLUSTER:-capstk-spike}"
NAMESPACE="${NAMESPACE:-default}"
CLUSTER_NAME="${CLUSTER_NAME:-stackit-spike}"
STACKIT_REGION="${STACKIT_REGION:-eu01}"
# k0s-Fassung des Katalogs. Der CCM von StackIT haengt an der
# Kubernetes-Minor und unterstuetzt 1.34 bis 1.37 - mit v1.32 waere der
# Versuch von vornherein schief.
K0S_VERSION="${K0S_VERSION:-v1.35.4+k0s.0}"
# Fuer phase-a: eine Kubernetes-Fassung, die CAPSTKs Vorlage per apt holt.
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.35.4}"
CHART_DIR="${CHART_DIR:-${SCRIPT_DIR}/../../stackit-standalone-cp}"
WORK_DIR="${WORK_DIR:-$(pwd)/.stackit-spike}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

  prereqs    Werkzeuge und Variablen pruefen, nichts anlegen
  mgmt       kind-Cluster anlegen und CAPSTK (+ k0smotron fuer phase-b) installieren
  phase-a    Cluster mit CAPSTKs kubeadm-Vorlage bauen  (prueft Konto, Netz, Abbild)
  phase-b    Cluster mit unserem k0s-Chart bauen        (prueft den Bootstrap)
  watch      Zustand der CAPI-Objekte zeigen
  teardown   Kindcluster-Objekte loeschen und den kind-Cluster abraeumen

Variablen (phase-a und phase-b):
  STACKIT_PROJECT_ID                 Projekt-UUID
  STACKIT_SERVICE_ACCOUNT_JSON_FILE  Pfad zum Service-Account-Schluessel
  STACKIT_NETWORK_ID                 Netz-UUID (mit internetAccess!)
  STACKIT_IMAGE_ID                   Abbild-UUID (Ubuntu 24.04)
  STACKIT_MACHINE_TYPE               Flavor, z.B. c1a.4d
  STACKIT_REGION                     Vorgabe: ${STACKIT_REGION}
EOF
}

require_tools() {
    local missing=()
    for tool in kind kubectl clusterctl helm; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Fehlende Werkzeuge: ${missing[*]}"
        return 1
    fi
    print_info "Werkzeuge vorhanden: kind, kubectl, clusterctl, helm"
}

require_vars() {
    local missing=()
    for var in STACKIT_PROJECT_ID STACKIT_SERVICE_ACCOUNT_JSON_FILE \
               STACKIT_NETWORK_ID STACKIT_IMAGE_ID STACKIT_MACHINE_TYPE; do
        [ -n "${!var:-}" ] || missing+=("$var")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Fehlende Variablen: ${missing[*]}"
        print_warn "Alle drei Kennungen sind UUIDs. Das Abbild findet man mit:"
        print_warn "  stackit image list --project-id \$STACKIT_PROJECT_ID --output-format json --label-selector linux,prod | jq -r '.[] | select(.name == \"Ubuntu 24.04\") | .id'"
        return 1
    fi
    if [ ! -f "${STACKIT_SERVICE_ACCOUNT_JSON_FILE}" ]; then
        print_error "Schluesseldatei nicht gefunden: ${STACKIT_SERVICE_ACCOUNT_JSON_FILE}"
        return 1
    fi
    print_info "Variablen vollstaendig, Projekt ${STACKIT_PROJECT_ID} in ${STACKIT_REGION}"
    print_warn "Das Netz ${STACKIT_NETWORK_ID} braucht internetAccess. Ohne SNAT laedt k0s sein Binary nicht - und das sieht aus wie ein Bootstrap-Fehler, ist aber keiner."
}

cmd_prereqs() {
    require_tools
    require_vars || true
}

cmd_mgmt() {
    require_tools
    mkdir -p "${WORK_DIR}"

    if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
        print_info "kind-Cluster ${KIND_CLUSTER} existiert schon"
    else
        print_header "kind-Cluster ${KIND_CLUSTER} anlegen"
        kind create cluster --name "${KIND_CLUSTER}"
    fi
    kubectl config use-context "kind-${KIND_CLUSTER}"

    cat > "${WORK_DIR}/clusterctl.yaml" <<EOF
providers:
  - name: stackit
    url: https://github.com/stackitcloud/cluster-api-provider-stackit/releases/download/${CAPSTK_VERSION}/infrastructure-components.yaml
    type: InfrastructureProvider
EOF

    print_header "CAPSTK ${CAPSTK_VERSION} und k0smotron installieren"
    # k0smotron liefert Bootstrap *und* Steuerungsebene fuer k0s; kubeadm
    # kommt als Vorgabe mit, damit phase-a ohne zweiten Lauf geht.
    clusterctl init \
        --config "${WORK_DIR}/clusterctl.yaml" \
        --infrastructure "stackit:${CAPSTK_VERSION}" \
        --bootstrap k0sproject-k0smotron \
        --control-plane k0sproject-k0smotron \
        --bootstrap kubeadm \
        --control-plane kubeadm

    kubectl rollout status --namespace capstk-system deployment/capstk-controller-manager --timeout=300s
    print_info "Management-Cluster steht"
}

create_credentials() {
    kubectl create secret generic stackit-credentials \
        --namespace "${NAMESPACE}" \
        --from-literal=project-id="${STACKIT_PROJECT_ID}" \
        --from-file=serviceaccount.json="${STACKIT_SERVICE_ACCOUNT_JSON_FILE}" \
        --dry-run=client -o yaml | kubectl apply -f -
}

cmd_phase_a() {
    require_tools
    require_vars
    mkdir -p "${WORK_DIR}"
    create_credentials

    print_header "Phase A: CAPSTKs eigene kubeadm-Vorlage"
    print_info "Das prueft Konto, Rechte, Quota, Netz und Abbild - nicht unseren Bootstrap."

    local template="${WORK_DIR}/cluster-template-${CAPSTK_VERSION}.yaml"
    if [ ! -f "${template}" ]; then
        curl --fail --location --silent --show-error \
            --output "${template}" \
            "https://github.com/stackitcloud/cluster-api-provider-stackit/releases/download/${CAPSTK_VERSION}/cluster-template.yaml"
    fi

    STACKIT_SERVICE_ACCOUNT_JSON_B64="$(base64 < "${STACKIT_SERVICE_ACCOUNT_JSON_FILE}" | tr -d '\n')" \
    STACKIT_CREDENTIALS_SECRET_NAME=stackit-credentials \
    STACKIT_CLOUD_CONTROLLER_MANAGER_IMAGE="ghcr.io/stackitcloud/cloud-provider-stackit/cloud-controller-manager:${KUBERNETES_VERSION#v}" \
    KUBERNETES_APT_REPOSITORY_MINOR="$(echo "${KUBERNETES_VERSION}" | cut -d. -f1,2)" \
    CONTROL_PLANE_MACHINE_COUNT=1 \
    WORKER_MACHINE_COUNT=1 \
    STACKIT_PROJECT_ID="${STACKIT_PROJECT_ID}" \
    STACKIT_REGION="${STACKIT_REGION}" \
    STACKIT_NETWORK_ID="${STACKIT_NETWORK_ID}" \
    STACKIT_IMAGE_ID="${STACKIT_IMAGE_ID}" \
    STACKIT_MACHINE_TYPE="${STACKIT_MACHINE_TYPE}" \
    KUBERNETES_VERSION="${KUBERNETES_VERSION}" \
        clusterctl generate cluster "${CLUSTER_NAME}-kubeadm" \
            --from "${template}" \
            --target-namespace "${NAMESPACE}" \
            > "${WORK_DIR}/phase-a.yaml"

    print_info "Gerendert nach ${WORK_DIR}/phase-a.yaml"
    kubectl apply -f "${WORK_DIR}/phase-a.yaml"
    print_warn "Jetzt zusehen: $(basename "$0") watch"
}

cmd_phase_b() {
    require_tools
    require_vars
    mkdir -p "${WORK_DIR}"
    create_credentials

    if [ ! -f "${CHART_DIR}/Chart.yaml" ]; then
        print_error "Chart nicht gefunden: ${CHART_DIR} (CHART_DIR setzen)"
        return 1
    fi

    print_header "Phase B: unser k0s-Chart stackit-standalone-cp"
    print_info "Scheitert erst das, ist es die Bootstrap-Frage - das Tor von enopax/enopax#51."

    helm template "${CLUSTER_NAME}" "${CHART_DIR}" \
        --namespace "${NAMESPACE}" \
        --set projectID="${STACKIT_PROJECT_ID}" \
        --set region="${STACKIT_REGION}" \
        --set credentialsSecretRef.name=stackit-credentials \
        --set network.id="${STACKIT_NETWORK_ID}" \
        --set controlPlane.imageID="${STACKIT_IMAGE_ID}" \
        --set controlPlane.machineType="${STACKIT_MACHINE_TYPE}" \
        --set worker.imageID="${STACKIT_IMAGE_ID}" \
        --set worker.machineType="${STACKIT_MACHINE_TYPE}" \
        --set controlPlaneNumber=1 \
        --set workersNumber=1 \
        --set k0s.version="${K0S_VERSION}" \
        > "${WORK_DIR}/phase-b.yaml"

    print_info "Gerendert nach ${WORK_DIR}/phase-b.yaml"
    print_warn "cloud-provider-stackit muss als Chart veroeffentlicht sein (oci://ghcr.io/enopax/charts), sonst scheitert die k0s-Extension - nicht der Bootstrap."
    kubectl apply -f "${WORK_DIR}/phase-b.yaml"
    print_warn "Jetzt zusehen: $(basename "$0") watch"
}

cmd_watch() {
    kubectl get cluster,machine,stackitcluster,stackitmachine --namespace "${NAMESPACE}" || true
    echo
    print_info "Bedingungen des Clusters:"
    kubectl get cluster --namespace "${NAMESPACE}" -o json 2>/dev/null \
        | python3 -c 'import json,sys
for c in json.load(sys.stdin).get("items", []):
    print(" ", c["metadata"]["name"])
    for cond in c.get("status", {}).get("conditions", []):
        print("   ", cond["type"], cond["status"], cond.get("message", "")[:90])' || true
    echo
    print_info "Wenn eine StackitMachine haengt, sagt der Provider warum:"
    echo "  kubectl logs -n capstk-system deployment/capstk-controller-manager --tail=100"
}

cmd_teardown() {
    print_header "Abraeumen"
    for f in "${WORK_DIR}/phase-b.yaml" "${WORK_DIR}/phase-a.yaml"; do
        [ -f "$f" ] && kubectl delete -f "$f" --ignore-not-found --wait=true || true
    done
    print_warn "Im StackIT-Projekt nachsehen, dass nichts stehen bleibt: Server, Netz (falls verwaltet), oeffentliche IPs, Load Balancer, Volumes, Security Groups."
    print_warn "Erst danach den kind-Cluster loeschen - ohne Controller raeumt niemand mehr auf:"
    echo "  kind delete cluster --name ${KIND_CLUSTER}"
}

case "${1:-}" in
    prereqs)  cmd_prereqs ;;
    mgmt)     cmd_mgmt ;;
    phase-a)  cmd_phase_a ;;
    phase-b)  cmd_phase_b ;;
    watch)    cmd_watch ;;
    teardown) cmd_teardown ;;
    *)        usage; exit 1 ;;
esac
