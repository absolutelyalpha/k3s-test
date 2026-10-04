#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Create, list or revoke least-privilege kubeconfigs for other people.
# Run this ON the cluster VM, not on your laptop.
#
#   ./create-scoped-user.sh <user> [namespace] [view|edit|admin]
#   ./create-scoped-user.sh alice            # read-only in namespace default
#   ./create-scoped-user.sh bob team-a edit  # can deploy in namespace team-a
#   ./create-scoped-user.sh --list           # who has access to what
#   ./create-scoped-user.sh --revoke alice   # remove alice completely
#
# Why not just hand over /root/.kube/config? That file is cluster-admin: it can
# read every Secret (service account tokens, TLS keys) and run pods anywhere.
# This script instead mints an ed25519 client certificate for one user, binds it
# to a Role/RoleBinding, and writes a kubeconfig containing only that identity.
# Every object it creates is labelled k3s-scoped-user=<user>, which is what makes
# --revoke complete rather than "delete the three things I remember".
# ---------------------------------------------------------------------------
# no `set -e`: the revoke path walks listings with grep/jq-ish pipelines whose
# exit status is not a meaningful error signal, and a silent abort there would
# leave access behind. Every step that must succeed checks its own status.
set -uo pipefail

usage() {
  cat <<'EOF'
usage:
  create-scoped-user.sh <user> [namespace] [view|edit|admin]
  create-scoped-user.sh --list
  create-scoped-user.sh --revoke <user>

env:
  CLUSTER_NAME   short cluster label written into the kubeconfig (default: hostname prefix)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --list)
    KUBECTL=/usr/local/bin/kubectl
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    echo "== scoped users and their bindings =="
    "$KUBECTL" get clusterrolebindings -o custom-columns=\
'NAME:.metadata.name,USER:.subjects[0].name,ROLE:.roleRef.name' \
      | grep -v ' k3s: ' | grep -v ' system: ' || true
    echo
    "$KUBECTL" get rolebindings -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,USER:.subjects[0].name,ROLE:.roleRef.name' \
      | grep -v ' system: ' || true
    exit 0 ;;
  --revoke)
    USER_NAME="${2:-}"
    [ -n "$USER_NAME" ] || { usage; exit 1; }
    KUBECTL=/usr/local/bin/kubectl
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    DIR=/root/users
    lbl="k3s-scoped-user=${USER_NAME}"

    echo "==> 1/3 removing RBAC that grants ${USER_NAME}"
    # authoritative sweep: delete every (cluster)rolebinding whose *subject* is
    # this user, whatever it is named or labelled
    for spec in "clusterrolebinding:" "rolebinding:-A"; do
      kind=${spec%%:*}; allns=${spec#*:}
      # note: kubectl wants flags AFTER the resource type, so "get rolebinding -A"
      $KUBECTL get "$kind" $allns \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{" "}{range .subjects[*]}{.name}{"|"}{end}{"\n"}{end}' \
      | while read -r objname objns subjects; do
          [ -n "$objname" ] || continue
          case "$subjects" in
            *"${USER_NAME}|"*)
              if [ "$kind" = rolebinding ]; then
                "$KUBECTL" -n "$objns" delete rolebinding "$objname" --ignore-not-found
              else
                "$KUBECTL" delete clusterrolebinding "$objname" --ignore-not-found
              fi ;;
          esac
        done
    done

    echo "==> 2/3 removing ${USER_NAME}'s certificate signing requests"
    "$KUBECTL" delete csr -l "$lbl" --ignore-not-found

    echo "==> 3/3 removing local credentials"
    rm -fv "${DIR}/${USER_NAME}.kubeconfig" "${DIR}/${USER_NAME}.key" \
             "${DIR}/${USER_NAME}.crt" "${DIR}/${USER_NAME}.csr" \
             "${DIR}/${USER_NAME}.csr.yaml" 2>/dev/null || true

    echo
    echo "  ${USER_NAME} is out: no RBAC binds that identity any more, so every"
    echo "  request made with its certificate is denied - including from copies of"
    echo "  the kubeconfig that still exist on other machines."
    exit 0 ;;
esac

USER_NAME="${1:-}"
NS="${2:-default}"
LEVEL="${3:-view}"

[ -n "$USER_NAME" ] || { usage; exit 1; }
case "$LEVEL" in view|edit|admin) ;; *) echo "level must be view, edit or admin"; exit 1 ;; esac
case "$USER_NAME" in *[!a-zA-Z0-9._-]*) echo "user name must be alphanumeric with . _ -"; exit 1 ;; esac
command -v openssl >/dev/null || { echo "openssl is required (apt-get install -y openssl)"; exit 1; }

KUBECTL=/usr/local/bin/kubectl
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
DIR=/root/users
OUT="$DIR/${USER_NAME}.kubeconfig"
CLUSTER="${CLUSTER_NAME:-$(hostname -s | tr -cs 'a-zA-Z0-9' '-' | cut -c1-8)}"
LBL="k3s-scoped-user=${USER_NAME}"

# the address the friend will use; written by setup-k3s.sh
# shellcheck disable=SC1091
[ -f /root/cluster-facts.env ] && . /root/cluster-facts.env
ADV="${APISERVER_ADVERTISE:-}"
if [ -z "$ADV" ]; then
  ADV=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[ -n "$ADV" ] || { echo "cannot determine the apiserver address"; exit 1; }

install -d -m 700 "$DIR"

echo "==> 1/5 key pair for ${USER_NAME}"
openssl genpkey -algorithm ed25519 -out "$DIR/${USER_NAME}.key" 2>/dev/null
chmod 600 "$DIR/${USER_NAME}.key"
openssl req -new -key "$DIR/${USER_NAME}.key" \
  -out "$DIR/${USER_NAME}.csr" -subj "/CN=${USER_NAME}/O=users" \
  -addext "keyUsage=digitalSignature" 2>/dev/null

echo "==> 2/5 certificate signing request"
cat > "$DIR/${USER_NAME}.csr.yaml" <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}-$(date +%s)
  labels:
    k3s-scoped-user: "${USER_NAME}"
spec:
  request: $(base64 -w0 "$DIR/${USER_NAME}.csr")
  signerName: kubernetes.io/kube-apiserver-client
  usages: ["client auth"]
EOF
CSR_NAME=$("$KUBECTL" apply -f "$DIR/${USER_NAME}.csr.yaml" -o jsonpath='{.metadata.name}')
"$KUBECTL" certificate approve "$CSR_NAME"
CERT=$("$KUBECTL" get csr "$CSR_NAME" -o jsonpath='{.status.certificate}')
[ -n "$CERT" ] || { echo "the apiserver issued no certificate"; exit 1; }
printf '%s' "$CERT" | base64 -d > "$DIR/${USER_NAME}.crt"

echo "==> 3/5 RBAC (${LEVEL} in namespace ${NS})"
if [ "$LEVEL" = "admin" ]; then
  "$KUBECTL" create clusterrolebinding "${USER_NAME}-admin" \
    --clusterrole=cluster-admin --user="${USER_NAME}" \
    --dry-run=client -o yaml > "$DIR/${USER_NAME}.crb.yaml"
  "$KUBECTL" label --overwrite --local -f "$DIR/${USER_NAME}.crb.yaml" "$LBL" >/dev/null
  "$KUBECTL" apply -f "$DIR/${USER_NAME}.crb.yaml" >/dev/null
else
  "$KUBECTL" create clusterrole k3s-infra-view \
    --verb=get,list,watch \
    --resource=nodes,namespaces,persistentvolumes,storageclasses 2>/dev/null \
    || echo "    (clusterrole k3s-infra-view already exists)"
  "$KUBECTL" create clusterrolebinding "${USER_NAME}-infra-view" \
    --clusterrole=k3s-infra-view --user="${USER_NAME}" \
    --dry-run=client -o yaml > "$DIR/${USER_NAME}.crb.yaml"
  "$KUBECTL" label --overwrite --local -f "$DIR/${USER_NAME}.crb.yaml" "$LBL" >/dev/null
  "$KUBECTL" apply -f "$DIR/${USER_NAME}.crb.yaml" >/dev/null
  "$KUBECTL" create rolebinding "${USER_NAME}-${LEVEL}-${NS}" \
    --clusterrole="${LEVEL}" --user="${USER_NAME}" -n "$NS" \
    --dry-run=client -o yaml > "$DIR/${USER_NAME}.rb.yaml"
  "$KUBECTL" label --overwrite --local -f "$DIR/${USER_NAME}.rb.yaml" "$LBL" >/dev/null
  "$KUBECTL" apply -f "$DIR/${USER_NAME}.rb.yaml" >/dev/null
fi

echo "==> 4/5 kubeconfig ${OUT}"
CA=/var/lib/rancher/k3s/server/tls/server-ca.crt
if [ ! -f "$CA" ]; then
  # fall back to the CA embedded in the admin kubeconfig
  mkdir -p "$DIR"
  "$KUBECTL" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
    | base64 -d > "$DIR/server-ca.crt"
  CA="$DIR/server-ca.crt"
fi
rm -f "$OUT"
"$KUBECTL" config set-cluster "$CLUSTER" --server="https://${ADV}:6443" \
  --certificate-authority="$CA" --embed-certs=true --kubeconfig="$OUT"
"$KUBECTL" config set-credentials "$USER_NAME" \
  --client-certificate="$DIR/${USER_NAME}.crt" \
  --client-key="$DIR/${USER_NAME}.key" --embed-certs=true --kubeconfig="$OUT"
"$KUBECTL" config set-context "$USER_NAME" \
  --cluster="$CLUSTER" --user="$USER_NAME" --kubeconfig="$OUT"
"$KUBECTL" config use-context "$USER_NAME" --kubeconfig="$OUT"
chmod 600 "$OUT"

echo "==> 5/5 verification (what the friend can and cannot do)"
echo "    can-i list pods in ${NS}:          $("$KUBECTL" --kubeconfig="$OUT" auth can-i list pods -n "$NS")"
echo "    can-i list secrets in ${NS}:       $("$KUBECTL" --kubeconfig="$OUT" auth can-i list secrets -n "$NS")"
echo "    can-i create pods in ${NS}:        $("$KUBECTL" --kubeconfig="$OUT" auth can-i create pods -n "$NS")"
echo "    can-i get nodes (read-only infra): $("$KUBECTL" --kubeconfig="$OUT" auth can-i get nodes)"

cat <<EOF

  hand over:
     scp ${OUT} <friend>:~/kubeconfig-${USER_NAME}.yaml
     # on the friend's machine
     export KUBECONFIG=~/kubeconfig-${USER_NAME}.yaml
     kubectl get nodes
     kubectl auth can-i --list

  server address baked in: https://${ADV}:6443
  if that address is not reachable from the friend's network, either re-run this
  script with APISERVER_ADVERTISE set to an address they can reach, or use
  scripts/friend-connect.sh to tunnel 6443.

  audit / revoke:
     bash $(basename "$0") --list
     bash $(basename "$0") --revoke ${USER_NAME}
EOF