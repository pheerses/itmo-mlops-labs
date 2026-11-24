#!/usr/bin/env bash
set -euo pipefail
stage=${1:?expected staging or production}
[[ "$stage" == staging || "$stage" == production ]]
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
release="titovets-search-$stage"
chart=helm/mlops-search
mkdir -p reports
upgrade() {
  helm upgrade --install "$release" "$chart" -n "$NS" --atomic --timeout 5m \
    --set-string image.repository="$IMAGE" --set-string image.digest="$DIGEST" \
    --set-string buildRevision="$GITHUB_SHA" --set-string environment="$stage" --set-string rankingMode="$1"
}
check() {
  python scripts/verify_release.py --release "$release" --namespace "$NS" --expected-env "$stage" --expected-digest "$DIGEST"
}
if [[ "$stage" == production ]]; then
  staged=$(kubectl -n "$NS" get deploy titovets-search-staging-mlops-search -o jsonpath='{.spec.template.spec.containers[0].image}')
  [[ "$staged" == "$IMAGE@$DIGEST" ]]
  python scripts/verify_release.py --release titovets-search-staging --namespace "$NS" --expected-env staging --expected-digest "$DIGEST"
fi
upgrade normal
helm test "$release" -n "$NS" --timeout 3m
check | tee "reports/$stage.json"
kubectl get deployment "$release-mlops-search" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' > "reports/$stage-image.txt"
if [[ "$stage" == production ]]; then
  helm history "$release" -n "$NS" -o json > reports/history-before.json
  previous=$(jq -r 'last.revision' reports/history-before.json)
  upgrade reverse
  trap 'helm rollback "$release" "$previous" -n "$NS" --wait --timeout 5m' EXIT
  if check > reports/reverse-smoke.log 2>&1; then echo "Unexpected reverse success"; exit 1; fi
  grep -q 'semantic mismatch' reports/reverse-smoke.log
  helm rollback "$release" "$previous" -n "$NS" --wait --timeout 5m
  trap - EXIT
  check | tee reports/restored.json
  helm history "$release" -n "$NS" -o json > reports/history-after.json
fi
