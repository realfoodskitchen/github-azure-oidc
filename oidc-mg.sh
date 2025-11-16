#!/bin/bash
set -euo pipefail

# ./oidc-mg.sh {APP_NAME} {ORG|USER/REPO} {FICS_FILE} [ENVIRONMENT...]
# Configures GitHub OIDC against an Azure management group. Creates/uses an AD app,
# ensures a Service Principal has Contributor at the MG scope, provisions FICs, and
# writes the GitHub secrets needed by workflows.
#
# Quick guide:
#   1. Prepare prerequisites: Azure CLI, GitHub CLI, jq, and envsubst installed and logged in. (note these are pre-installed in Azure Cloud Shell if running the script there.)
#   2. Build or update your FIC definition JSON (see fics.json for an example).
#   3. Run this script with: ./oidc-mg.sh <APP_NAME> <ORG/REPO> <FICS_FILE> [ENV...] Leaving the Environment blank will result in repo-level secrets.
#   4. When prompted, pick the management group scope and (if not provided) GitHub environment names.

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <APP_NAME> <ORG|USER/REPO> <FICS_FILE> [ENVIRONMENT...]"
    exit 1
fi

# Role assignments in Codespaces are unreliable; exit early with guidance.
IS_CODESPACE=${CODESPACES:-"false"}
if [[ "$IS_CODESPACE" == "true" ]]
then
    echo "This script doesn't work in GitHub Codespaces.  See this issue for updates. https://github.com/Azure/azure-cli/issues/21025 "
    exit 0
fi

APP_NAME=$1
export REPO=$2
FICS_FILE=$3
shift 3
ENVIRONMENTS=("$@")

# Validate the FIC definition file before doing any Azure work.
if [[ ! -f "$FICS_FILE" ]]; then
    echo "Federated identity credentials file not found: $FICS_FILE"
    exit 1
fi

# Confirm required CLIs exist.
for DEP in az gh jq envsubst; do
    if ! command -v "$DEP" >/dev/null 2>&1; then
        echo "The '$DEP' command is required but not installed or not on PATH."
        exit 1
    fi
done

# Utility to trim whitespace from interactive entries.
trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Ensure `gh` can call the API/secrets endpoint without prompting mid-script.
ensure_github_login() {
    if gh auth status -h github.com >/dev/null 2>&1; then
        echo "GitHub CLI already authenticated."
    else
        echo "GitHub CLI not authenticated. Logging in..."
        gh auth login
    fi
}

# Show existing environments to avoid typos during secret scoping.
list_github_environments() {
    local repo_slug=$1
    echo "Retrieving GitHub environments for $repo_slug..."
    if ! ENV_OUTPUT=$(gh api \
        -H "Accept: application/vnd.github+json" \
        "/repos/${repo_slug}/environments?per_page=100" 2>/dev/null); then
        echo "Unable to list GitHub environments (verify repository access)."
        return
    fi

    local COUNT
    COUNT=$(echo "$ENV_OUTPUT" | jq '.total_count // 0')
    if [[ "$COUNT" -eq 0 ]]; then
        echo "No GitHub environments currently exist for $repo_slug."
        return
    fi

    echo "Available GitHub environments:"
    echo "$ENV_OUTPUT" | jq -r '.environments[]?.name' | while IFS= read -r name; do
        echo "- $name"
    done
}

ensure_github_login
list_github_environments "$REPO"

# Prompt for environment names only if they were not provided as arguments.
if [[ ${#ENVIRONMENTS[@]} -eq 0 ]]; then
    echo
    read -r -p "Enter GitHub environment names (comma-separated) or press Enter to configure repo-level secrets: " ENV_RESPONSE
    if [[ -n "$ENV_RESPONSE" ]]; then
        IFS=',' read -ra ENVIRONMENTS <<< "$ENV_RESPONSE"
        TMP_ENV=()
        for env in "${ENVIRONMENTS[@]}"; do
            TRIMMED_ENV=$(trim_whitespace "$env")
            if [[ -n "$TRIMMED_ENV" ]]; then
                TMP_ENV+=("$TRIMMED_ENV")
            fi
        done
        ENVIRONMENTS=("${TMP_ENV[@]}")
    fi
fi

echo "Checking Azure CLI login status..."
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'id' -o tsv || true)

if [[ -z "$EXPIRED_TOKEN" ]]
then
    az login -o none
fi

# List available management groups so the operator can select a scope confidently.
echo "Fetching management groups (name | displayName | id)..."
MG_LIST=$(az rest \
    --method get \
    --url "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2021-04-01" \
    --query "value[].{name:name,displayName:properties.displayName,id:id}" \
    -o json --only-show-errors) || true

if [[ -z "$MG_LIST" || "$MG_LIST" == "null" ]]; then
    echo "Unable to retrieve management groups. Ensure you have access to management groups in this tenant."
    exit 1
fi
if [[ "$(echo "$MG_LIST" | jq length)" -eq 0 ]]; then
    echo "No management groups were returned for this account. Please ensure you have access before re-running."
    exit 1
fi
echo "$MG_LIST" | jq -r '.[] | "- \(.displayName) | name: \(.name) | id: \(.id)"'

while true; do
    echo
    read -r -p "Enter the management group name or resource ID: " MG_SELECTION
    if [[ -z "$MG_SELECTION" ]]; then
        echo "A management group identifier is required for this script."
        continue
    fi
    MG_SCOPE=$(echo "$MG_LIST" | jq -r --arg sel "$MG_SELECTION" '.[] | select(.id==$sel or .name==$sel or .displayName==$sel) | .id')
    if [[ -z "$MG_SCOPE" ]]; then
        if [[ "$MG_SELECTION" == /providers/Microsoft.Management/managementGroups/* ]]; then
            MG_SCOPE="$MG_SELECTION"
        else
            MG_SCOPE="/providers/Microsoft.Management/managementGroups/$MG_SELECTION"
        fi
    fi
    if [[ -n "$MG_SCOPE" ]]; then
        echo "Using management group scope: $MG_SCOPE"
        break
    else
        echo "Unable to match '$MG_SELECTION' to a management group. Please try again."
    fi
done

ROLE_SCOPE="$MG_SCOPE"

echo "Getting Tenant Id..."
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "TENANT_ID: $TENANT_ID"

echo "Configuring application..."

#  First check if an app with the same name exists, if so use it, if not create one
APP_ID=$(az ad app list --filter "displayName eq '$APP_NAME'" --query [].appId -o tsv)

if [[ -z "$APP_ID" ]]
then
    echo "Creating AD app..."
    APP_ID=$(az ad app create --display-name ${APP_NAME} --query appId -o tsv)
    echo "Sleeping for 30 seconds to give time for the APP to be created."
    sleep 30
else
    echo "Existing AD app found."
fi

echo "APP_ID: $APP_ID"

echo "Configuring Service Principal..."

echo "First checking if the Service Principal already exists..."
SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query [].id -o tsv)
if [[ -z "$SP_ID" ]]
then
    echo "Creating service principal..."
    SP_ID=$(az ad sp create --id $APP_ID --query id -o tsv)

    echo "Sleeping for 30 seconds to give time for the SP to be created."
    sleep 30

    echo "Creating initial Contributor role assignment on $ROLE_SCOPE..."
    az role assignment create \
        --role contributor \
        --scope "$ROLE_SCOPE" \
        --assignee-object-id $SP_ID \
        --assignee-principal-type ServicePrincipal
    sleep 30
else
    echo "Existing Service Principal found."
fi

echo "Ensuring Contributor role assignment on $ROLE_SCOPE..."
ASSIGNMENT_OUTPUT=$(az role assignment create \
    --role contributor \
    --scope "$ROLE_SCOPE" \
    --assignee-object-id $SP_ID \
    --assignee-principal-type ServicePrincipal \
    --only-show-errors 2>&1) || true

echo "Azure CLI response:"
echo "$ASSIGNMENT_OUTPUT"

echo "Current role assignments for this SP on $ROLE_SCOPE:"
az role assignment list \
    --assignee $SP_ID \
    --role contributor \
    --scope "$ROLE_SCOPE" \
    --output table

echo "SP_ID: $SP_ID"

echo "Creating Federated Identity Credentials..."
echo 
for FIC in $(envsubst < $FICS_FILE | jq -c '.[]'); do
    SUBJECT=$(jq -r '.subject' <<< "$FIC")
    
    echo "Creating FIC with subject '${SUBJECT}'."
    az ad app federated-credential create --id  $APP_ID --parameters ${FIC} || true
done

# To get an Azure AD app FICs
# az ad app federated-credential list --id $APP_ID

# To delete an Azure AD app FIC
# az ad app federated-credential list --id $APP_ID --federated-credential-id ${FIC_ID}

# You can view your FICs in the portal here:
# https://portal.azure.com/#view/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview/menuId~/null and search for the service principal ID
# https://ms.portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/${APP_ID}
# Certificates & secrets, Click on Federated credentials

# Secret creation targets repo-level scope unless specific environments were requested.
if [[ ${#ENVIRONMENTS[@]} -eq 0 ]]; then
    echo "No environments specified. Creating repo-level secrets..."
    gh secret set AZURE_CLIENT_ID -b${APP_ID} --repo $REPO
    gh secret set AZURE_MANAGEMENT_GROUP_ID -b${MG_SCOPE} --repo $REPO
    gh secret set AZURE_TENANT_ID -b${TENANT_ID} --repo $REPO
else
    echo "Environments specified; configuring secrets only for: ${ENVIRONMENTS[*]}"
    for ENV_NAME in "${ENVIRONMENTS[@]}"; do
        if [[ -z "$ENV_NAME" ]]; then
            continue
        fi
        echo "Setting environment secrets for '$ENV_NAME'..."
        gh secret set AZURE_CLIENT_ID -b${APP_ID} --repo $REPO --env "$ENV_NAME"
        gh secret set AZURE_MANAGEMENT_GROUP_ID -b${MG_SCOPE} --repo $REPO --env "$ENV_NAME"
        gh secret set AZURE_TENANT_ID -b${TENANT_ID} --repo $REPO --env "$ENV_NAME"
    done
fi
