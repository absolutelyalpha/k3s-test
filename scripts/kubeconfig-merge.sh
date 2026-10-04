#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Merge several clusters into ONE kubeconfig with one clean context per cluster.
#
#   ./kubeconfig-merge.sh -o clusters.yaml ~/mine.yaml ~/friend.yaml
#   ./kubeconfig-merge.sh -o clusters.yaml -c friend ~/mine.yaml ~/friend.yaml
#   ./kubeconfig-merge.sh -o clusters.yaml --verify ~/mine.yaml ~/friend.yaml
#
# Contexts are renamed to the kubeconfig's basename (mine, friend, ...) so two
# clusters that both shipped a "default" context cannot collide, and every
# embedded certificate is inlined so the result is a single portable file.
# Works with cert-based (the ones create-scoped-user.sh makes) and token-based
# kubeconfigs.
# ---------------------------------------------------------------------------
set -uo pipefail

OUT=./clusters.yaml
DEFAULT_CTX=""
VERIFY=0
INPUTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out)     OUT="$2"; shift 2 ;;
    -c|--default) DEFAULT_CTX="$2"; shift 2 ;;
    --verify)     VERIFY=1; shift ;;
    -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
    *)            INPUTS+=("$1"); shift ;;
  esac
done

[ ${#INPUTS[@]} -ge 1 ] || { echo "usage: $0 [-o out.yaml] [-c context] [--verify] <kubeconfig>..."; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required"; exit 1; }
command -v base64   >/dev/null || { echo "base64 is required"; exit 1; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# OS path separator for KUBECONFIG lists (POSIX uses :, Windows uses ;)
case "$(uname -s 2>/dev/null || echo Linux)" in
  CYGWIN*|MINGW*|MSYS*) PATHSEP=';' ;;
  *)                    PATHSEP=':' ;;
esac

sanitize() { echo "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//' | cut -c1-40; }

jsonpath_get() { kubectl --kubeconfig "$1" config view --raw --minify -o "jsonpath=$2" 2>/dev/null; }

rm -f "$OUT"
CLEAN=()
for f in "${INPUTS[@]}"; do
  [ -f "$f" ] || { echo "no such kubeconfig: $f"; exit 1; }

  base=$(sanitize "$(basename "$f" | sed 's/\.ya\?ml$//')")
  [ -n "$base" ] || base=cluster

  server=$(jsonpath_get "$f" '{.clusters[0].cluster.server}')
  [ -n "$server" ] || { echo "$f: no server found in the kubeconfig"; exit 1; }

  ca=$(jsonpath_get "$f" '{.clusters[0].cluster.certificate-authority-data}')
  if [ -z "$ca" ]; then
    capath=$(jsonpath_get "$f" '{.clusters[0].cluster.certificate-authority}')
    [ -n "$capath" ] && ca=$(base64 -w0 < "$capath" 2>/dev/null)
  fi
  [ -n "$ca" ] || { echo "$f: no cluster CA found"; exit 1; }

  crt=$(jsonpath_get "$f" '{.users[0].user.client-certificate-data}')
  if [ -z "$crt" ]; then
    crtpath=$(jsonpath_get "$f" '{.users[0].user.client-certificate}')
    [ -n "$crtpath" ] && crt=$(base64 -w0 < "$crtpath" 2>/dev/null)
  fi
  key=$(jsonpath_get "$f" '{.users[0].user.client-key-data}')
  if [ -z "$key" ]; then
    keypath=$(jsonpath_get "$f" '{.users[0].user.client-key}')
    [ -n "$keypath" ] && key=$(base64 -w0 < "$keypath" 2>/dev/null)
  fi
  token=$(jsonpath_get "$f" '{.users[0].user.token}')

  printf '%s' "$ca"  | base64 -d > "$tmpdir/$base.ca"  2>/dev/null
  set_cluster="--server=$server --certificate-authority=$tmpdir/$base.ca --embed-certs=true"
  kubectl --kubeconfig "$OUT" config set-cluster "$base" $set_cluster >/dev/null

  if [ -n "$crt" ] && [ -n "$key" ]; then
    printf '%s' "$crt" | base64 -d > "$tmpdir/$base.crt" 2>/dev/null
    printf '%s' "$key" | base64 -d > "$tmpdir/$base.key" 2>/dev/null
    kubectl --kubeconfig "$OUT" config set-credentials "$base" \
      --client-certificate="$tmpdir/$base.crt" --client-key="$tmpdir/$base.key" \
      --embed-certs=true >/dev/null
  elif [ -n "$token" ]; then
    kubectl --kubeconfig "$OUT" config set-credentials "$base" --token="$token" >/dev/null
  else
    echo "$f: no client certificate and no token found (exec plugins are not merged)"
    exit 1
  fi

  kubectl --kubeconfig "$OUT" config set-context "$base" \
    --cluster="$base" --user="$base" >/dev/null
  CLEAN+=("$base")
done

# de-duplicate (two inputs with the same basename would share a context name)
[ "${#CLEAN[@]}" -eq "${#INPUTS[@]}" ] || { echo "two kubeconfigs share a basename; rename one"; exit 1; }

kubectl --kubeconfig "$OUT" config use-context "${CLEAN[0]}" >/dev/null
if [ -n "$DEFAULT_CTX" ]; then
  kubectl --kubeconfig "$OUT" config use-context "$DEFAULT_CTX" >/dev/null || {
    echo "context '$DEFAULT_CTX' is not in $OUT (have: ${CLEAN[*]})"; exit 1; }
fi
chmod 600 "$OUT"

echo "wrote $OUT"
kubectl --kubeconfig "$OUT" config get-contexts

rc=0
if [ "$VERIFY" = "1" ]; then
  for ctx in "${CLEAN[@]}"; do
    if out=$(kubectl --kubeconfig "$OUT" --context "$ctx" get nodes -o wide 2>&1); then
      echo "OK   $ctx -> $(echo "$out" | sed -n '2p' | awk '{print $1" "$2}')"
    else
      echo "FAIL $ctx: $(echo "$out" | head -1)"
      rc=1
    fi
  done
else
  cat <<EOF

  use it:
     export KUBECONFIG=\$PWD/$(basename "$OUT")
     kubectl config get-contexts
     kubectl --context <name> get pods -A
  to check every cluster at once:  ./kubeconfig-merge.sh -o clusters.yaml --verify ${INPUTS[*]}
EOF
fi
exit $rc