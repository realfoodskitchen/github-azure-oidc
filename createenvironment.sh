#!/bin/bash
# Script to create GitHub environments for a repository.
# 
# To run, use the following command:
# ./createenvironment.sh <org/repo> <environment1> [environment2 ... environmentN]
# 
# Note: Quote environment names that contain spaces (e.g., "Landing Zone").
# 
# All parameters are required to avoid hard-coded values.
# 
# Example:
# bash createenvironment.sh realfoodskitchen/homelab Sandbox "Landing Zone" Production Development

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <org/repo> <environment1> [environment2 ... environmentN]

Note: Quote environment names that contain spaces (e.g., "Landing Zone").

All parameters are required to avoid hard-coded values.
USAGE
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

REPO_SLUG=$1
shift 1
ENVIRONMENTS=("$@")

if [[ "$REPO_SLUG" != */* ]]; then
  echo "Repository must be in org/repo format (e.g., realfoodskitchen/homelab)"
  exit 1
fi

echo "Using repository: $REPO_SLUG"
echo "Logging into GitHub CLI (interactive)..."
gh auth login
echo "Login complete."
echo

for env in "${ENVIRONMENTS[@]}"; do
  echo "Creating environment: $env"

  gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/repos/${REPO_SLUG}/environments/${env// /%20}" \
    --input <(printf '{}')

  echo "Environment created: $env"
  echo
done

echo "All environments created successfully."