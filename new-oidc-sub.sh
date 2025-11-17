#!/bin/bash
set -euo pipefail

# Interactive helper that configures GitHub OIDC against a specific Azure subscription.

if [[ ${CODESPACES:-"false"} == "true" ]]; then
    echo "This script cannot run inside GitHub Codespaces due to CLI limitations."
    exit 1
fi

for DEP in az gh jq envsubst; do
    if ! command -v "$DEP" >/dev/null 2>&1; then
        echo "Missing dependency: $DEP. Please install it before re-running."
        exit 1
    fi
done

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

ensure_github_login() {
    if gh auth status -h github.com >/dev/null 2>&1; then
        echo "GitHub CLI already authenticated."
    else
        echo "GitHub CLI not authenticated. Logging in..."
        gh auth login
    fi
}

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

urlencode() {
    local raw="$1"
    jq -rn --arg v "$raw" '$v|@uri'
}

prompt_repo() {
    local response
    while true; do
        read -r -p "Enter GitHub repository (org/repo): " response
        response=$(trim "$response")
        if [[ -z "$response" ]]; then
            echo "Repository is required."
            continue
        fi
        if [[ "$response" != */* ]]; then
            echo "Repository must be provided in org/repo format."
            continue
        fi
        export REPO="$response"
        break
    done
}

prompt_environment() {
    local response
    while true; do
        read -r -p "Enter GitHub environment name: " response
        response=$(trim "$response")
        if [[ -n "$response" ]]; then
            ENV_NAME="$response"
            export ENV_NAME
            break
        fi
        echo "Environment name cannot be empty."
    done
}

ensure_environment_exists() {
    local repo_slug=$1
    local env_name=$2
    local encoded
    encoded=$(urlencode "$env_name")
    echo "Ensuring GitHub environment '$env_name' exists..."
    gh api \
        --method PUT \
        -H "Accept: application/vnd.github+json" \
        "/repos/${repo_slug}/environments/${encoded}" \
        --input <(printf '{}')
    echo "Environment '$env_name' is ready."
}

prompt_fics_file() {
    local response default_file="fics.json"
    while true; do
        read -r -p "Enter path to federated identity definitions [${default_file}]: " response
        response=$(trim "$response")
        if [[ -z "$response" ]]; then
            response="$default_file"
        fi
        if [[ -f "$response" ]]; then
            FICS_FILE="$response"
            break
        fi
        echo "File not found: $response"
    done
}

prompt_app_name() {
    local slug default_name response
    slug=$(echo "$ENV_NAME" | tr '[:space:]' '-' | tr -s '-' '-' | sed -E 's/[^A-Za-z0-9-]//g')
    slug="${slug#-}"
    slug="${slug%-}"
    if [[ -z "$slug" ]]; then
        slug="Environment"
    fi
    default_name="Github-OIDC-${slug}"
    read -r -p "Enter Azure AD app registration name [${default_name}]: " response
    response=$(trim "$response")
    if [[ -z "$response" ]]; then
        response="$default_name"
    fi
    APP_NAME="$response"
    export APP_NAME
}

prompt_repo
ensure_github_login
list_github_environments "$REPO"
prompt_environment
ensure_environment_exists "$REPO" "$ENV_NAME"
prompt_app_name
prompt_fics_file

echo "Checking Azure CLI login status..."
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'id' -o tsv || true)
if [[ -z "$EXPIRED_TOKEN" ]]; then
    az login -o none
fi

echo "Fetching subscriptions (name | id)..."
SUB_LIST=$(az account list --query "[].{name:name,id:id}" -o json --only-show-errors) || true
if [[ -z "$SUB_LIST" || "$SUB_LIST" == "null" ]]; then
    echo "Unable to retrieve subscriptions. Ensure you have access."
    exit 1
fi
if [[ "$(echo "$SUB_LIST" | jq length)" -eq 0 ]]; then
    echo "No subscriptions returned for this account."
    exit 1
fi
echo "$SUB_LIST" | jq -r '.[] | "- \(.name) | id: \(.id)"'

while true; do
    echo
    read -r -p "Enter the subscription name or ID to target: " SUB_SELECTION
    SUB_SELECTION=$(trim "$SUB_SELECTION")
    if [[ -z "$SUB_SELECTION" ]]; then
        echo "A subscription identifier is required."
        continue
    fi
    SUBSCRIPTION_ID=$(echo "$SUB_LIST" | jq -r --arg sel "$SUB_SELECTION" '.[] | select(.id==$sel or .name==$sel) | .id')
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
        if [[ "$SUB_SELECTION" == /subscriptions/* ]]; then
            SUBSCRIPTION_ID="${SUB_SELECTION#/subscriptions/}"
        else
            SUBSCRIPTION_ID="$SUB_SELECTION"
        fi
    fi
    if [[ -n "$SUBSCRIPTION_ID" ]]; then
        echo "Using subscription: $SUBSCRIPTION_ID"
        break
    fi
    echo "Unable to match '$SUB_SELECTION' to a subscription. Please try again."
done

ROLE_SCOPE="/subscriptions/$SUBSCRIPTION_ID"

echo "Getting Tenant Id..."
TENANT_ID=$(az account show --subscription "$SUBSCRIPTION_ID" --query tenantId -o tsv)
echo "TENANT_ID: $TENANT_ID"

echo "Configuring application..."
APP_ID=$(az ad app list --filter "displayName eq '$APP_NAME'" --query [].appId -o tsv)

if [[ -z "$APP_ID" ]]; then
    echo "Creating AD app '$APP_NAME'..."
    APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
    echo "Sleeping for 30 seconds to allow Azure AD to finish provisioning the app."
    sleep 30
else
    echo "Existing AD app found."
fi

echo "APP_ID: $APP_ID"

echo "Configuring Service Principal..."
SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query [].id -o tsv)
if [[ -z "$SP_ID" ]]; then
    echo "Creating service principal..."
    SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
    echo "Sleeping for 30 seconds to allow the service principal to finish provisioning."
    sleep 30
    echo "Creating initial Contributor role assignment on $ROLE_SCOPE..."
    az role assignment create \
        --role contributor \
        --scope "$ROLE_SCOPE" \
        --assignee-object-id "$SP_ID" \
        --assignee-principal-type ServicePrincipal
    sleep 30
else
    echo "Existing Service Principal found."
fi

echo "Ensuring Contributor role assignment on $ROLE_SCOPE..."
ASSIGNMENT_OUTPUT=$(az role assignment create \
    --role contributor \
    --scope "$ROLE_SCOPE" \
    --assignee-object-id "$SP_ID" \
    --assignee-principal-type ServicePrincipal \
    --only-show-errors 2>&1) || true

echo "Azure CLI response:"
echo "$ASSIGNMENT_OUTPUT"

echo "Current role assignments for this SP on $ROLE_SCOPE:"
az role assignment list \
    --assignee "$SP_ID" \
    --role contributor \
    --scope "$ROLE_SCOPE" \
    --output table

echo "SP_ID: $SP_ID"

echo "Creating Federated Identity Credentials from $FICS_FILE..."
for FIC in $(envsubst < "$FICS_FILE" | jq -c '.[]'); do
    SUBJECT=$(jq -r '.subject' <<< "$FIC")
    echo "Creating FIC with subject '${SUBJECT}'."
    az ad app federated-credential create --id "$APP_ID" --parameters "${FIC}" || true
done

echo "Setting GitHub secrets for environment '$ENV_NAME'..."
gh secret set AZURE_CLIENT_ID -b"$APP_ID" --repo "$REPO" --env "$ENV_NAME"
gh secret set AZURE_SUBSCRIPTION_ID -b"$SUBSCRIPTION_ID" --repo "$REPO" --env "$ENV_NAME"
gh secret set AZURE_TENANT_ID -b"$TENANT_ID" --repo "$REPO" --env "$ENV_NAME"

cat <<SUMMARY

All done!
- Repository: $REPO
- Environment: $ENV_NAME
- App Registration: $APP_NAME ($APP_ID)
- Service Principal: $SP_ID
- Subscription Scope: $ROLE_SCOPE

You can now use the configured environment secrets in your GitHub workflows.
SUMMARY
