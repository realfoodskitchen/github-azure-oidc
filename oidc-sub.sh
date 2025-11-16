#!/bin/bash
set -euo pipefail

# ./oidc-sub.sh {APP_NAME} {ORG|USER/REPO} {FICS_FILE} [ENVIRONMENT...]
# Configures GitHub OIDC against an Azure subscription. Creates/uses an AD app,
# ensures a Service Principal has Contributor at the MG scope, provisions FICs, and
# writes the GitHub secrets needed by workflows.
#
# Quick guide:
#   1. Prepare prerequisites: Azure CLI, GitHub CLI, jq, and envsubst installed and logged in. (note these are pre-installed in Azure Cloud Shell if running the script there.)
#   2. Build or update your FIC definition JSON (see fics.json for an example).
#   3. Run this script with: ./oidc-sub.sh <APP_NAME> <ORG/REPO> <FICS_FILE> [ENV...] Leaving the Environment blank will result in repo-level secrets.
#   4. When prompted, pick the management group scope and (if not provided) GitHub environment names.
IS_CODESPACE=${CODESPACES:-"false"}
if $IS_CODESPACE == "true"
then
    echo "This script doesn't work in GitHub Codespaces.  See this issue for updates. https://github.com/Azure/azure-cli/issues/21025 "
    exit 0
fi

APP_NAME=$1
export REPO=$2
FICS_FILE=$3
shift 3
ENVIRONMENTS=("$@")

echo "Checking Azure CLI login status..."
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'id' -o tsv || true)

if [[ -z "$EXPIRED_TOKEN" ]]
then
    az login -o none
fi

ACCOUNT=$(az account show --query '[id,name]')
echo $ACCOUNT

read -r -p "Do you want to use the above subscription? (Y/n) " response
response=${response:-Y}
case "$response" in
    [yY][eE][sS]|[yY]) 
        ;;
    *)
        echo "Use the \`az account set -s\` command to set the subscription you'd like to use and re-run this script."
        exit 0
        ;;
esac

echo "Getting Subscription Id..."
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
echo "Subscription: $SUB_NAME ($SUB_ID)"
ROLE_SCOPE="/subscriptions/$SUB_ID"

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
    sleep 30s
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
    sleep 30s

    echo "Creating initial Contributor role assignment on $ROLE_SCOPE..."
    az role assignment create \
        --role contributor \
        --scope "$ROLE_SCOPE" \
        --assignee-object-id $SP_ID \
        --assignee-principal-type ServicePrincipal
    sleep 30s
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

echo "Logging into GitHub CLI..."
gh auth login

if [[ ${#ENVIRONMENTS[@]} -eq 0 ]]; then
    echo "No environments specified. Creating repo-level secrets..."
    gh secret set AZURE_CLIENT_ID -b${APP_ID} --repo $REPO
    gh secret set AZURE_SUBSCRIPTION_ID -b${SUB_ID} --repo $REPO
    gh secret set AZURE_TENANT_ID -b${TENANT_ID} --repo $REPO
else
    echo "Environments specified; configuring secrets only for: ${ENVIRONMENTS[*]}"
    for ENV_NAME in "${ENVIRONMENTS[@]}"; do
        if [[ -z "$ENV_NAME" ]]; then
            continue
        fi
        echo "Setting environment secrets for '$ENV_NAME'..."
        gh secret set AZURE_CLIENT_ID -b${APP_ID} --repo $REPO --env "$ENV_NAME"
        gh secret set AZURE_SUBSCRIPTION_ID -b${SUB_ID} --repo $REPO --env "$ENV_NAME"
        gh secret set AZURE_TENANT_ID -b${TENANT_ID} --repo $REPO --env "$ENV_NAME"
    done
fi
