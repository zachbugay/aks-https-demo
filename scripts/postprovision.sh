#!/usr/bin/env bash

set -euo pipefail

# get and set credentials.
az aks get-credentials \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_AKS_CLUSTER_NAME" \
  --overwrite-existing

# bootstrap flux (only if not already bootstrapped on this cluster).
if kubectl --context="$AZURE_AKS_CLUSTER_NAME" \
  get gitrepository flux-system -n flux-system >/dev/null 2>&1; then
  echo "Flux is already bootstrapped on '$AZURE_AKS_CLUSTER_NAME'; skipping bootstrap."
else
  echo "Bootstrapping Flux on '$AZURE_AKS_CLUSTER_NAME'..."
  flux bootstrap github \
    --components-extra=source-watcher \
    --context="$AZURE_AKS_CLUSTER_NAME" \
    --owner="$GITHUB_USERNAME" \
    --repository="$GITHUB_REPO_NAME" \
    --branch=main \
    --personal \
    --token-auth \
    --path=clusters/demo-cluster
fi
