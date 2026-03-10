#!/bin/sh
# A helper script to setup ArgoCD portforward
set -eu

SCRIPT_DIR="$(dirname ${BASH_SOURCE[0]})"
export KUBECONFIG="$SCRIPT_DIR/kubeconfig-argocd"

if [ ! -f "$KUBECONFIG" ]; then
  aws eks update-kubeconfig --name k8tre-dev-argocd
fi

kubectl -nargocd get secret argocd-initial-admin-secret -ojsonpath='{.data.password}' | base64 -d
echo

kubectl port-forward svc/argocd-server -n argocd 8080:80
