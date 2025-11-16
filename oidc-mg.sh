#!/bin/bash
set -euo pipefail

# ./oidc-mg.sh {APP_NAME} {ORG|USER/REPO} {FICS_FILE}

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <APP_NAME> <ORG|USER/REPO> <FICS_FILE>"
    exit 1
fi

IS_CODESPACE=${CODESPACES:-"false"}
if [[ "$IS_CODESPACE" == "true" ]]
then
    echo "This script doesn't work in GitHub Codespaces.  See this issue for updates. https://github.com/Azure/azure-cli/issues/21025 "
    exit 0
fi

APP_NAME=$1
export REPO=$2
FICS_FILE=$3

if [[ ! -f "$FICS_FILE" ]]; then
    echo "Federated identity credentials file not found: $FICS_FILE"
    exit 1
fi

for DEP in az gh jq envsubst; do
    if ! command -v "$DEP" >/dev/null 2>&1; then
        echo "The '$DEP' command is required but not installed or not on PATH."
        exit 1
    fi
done

echo "Checking Azure CLI login status..."
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'id' -o tsv || true)

if [[ -z "$EXPIRED_TOKEN" ]]
then
    az login -o none
fi

ACCOUNT=$(az account show --query '[id,name]')
echo $ACCOUNT

echo "Getting Subscription Id..."
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
echo "SUB: $SUB_NAME ($SUB_ID)"

ensure_managementgroups_extension() {
    if ! az extension show --name managementgroups >/dev/null 2>&1; then
        echo "Azure CLI 'managementgroups' extension not found. Installing..."
        az extension add --name managementgroups >/dev/null
        echo "Extension installed."
    fi
}

ensure_managementgroups_extension

echo "Fetching management groups (name | displayName | id)..."
if ! MG_LIST=$(az account management-group list --query "value[].{name:name,displayName:displayName,id:id}" -o json --only-show-errors); then
    echo "Unable to retrieve management groups. Ensure you have access and the managementgroups extension installed."
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

    echo "Creating role assignment..."
    az role assignment create --role contributor --scope "$MG_SCOPE" --assignee-object-id $SP_ID --assignee-principal-type ServicePrincipal
    sleep 30s
else
    echo "Existing Service Principal found."
fi

echo "Ensuring role assignment on $MG_SCOPE..."
ASSIGNMENT_COUNT=$(az role assignment list --assignee-object-id $SP_ID --scope "$MG_SCOPE" --query "length(@)" -o tsv)
if [[ "$ASSIGNMENT_COUNT" == "0" ]]; then
    az role assignment create --role contributor --scope "$MG_SCOPE" --assignee-object-id $SP_ID --assignee-principal-type ServicePrincipal
else
    echo "Role assignment already exists for this scope."
fi

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

echo "Creating the following GitHub repo secrets..."
echo AZURE_CLIENT_ID=$APP_ID
echo AZURE_SUBSCRIPTION_ID=$SUB_ID
echo AZURE_TENANT_ID=$TENANT_ID

echo "Logging into GitHub CLI..."
gh auth login

gh secret set AZURE_CLIENT_ID -b${APP_ID} --repo $REPO
gh secret set AZURE_SUBSCRIPTION_ID -b${SUB_ID} --repo $REPO
gh secret set AZURE_TENANT_ID -b${TENANT_ID} --repo $REPO
