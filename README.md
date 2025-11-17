# new-oidc-mg.sh

`new-oidc-mg.sh` is an interactive helper that wires up GitHub OIDC authentication against an Azure management group in one guided run. It walks you through the values it needs, creates missing Azure/GitHub resources, and produces environment-scoped secrets ready for workflows.

## What the script configures
- Ensures `gh` is authenticated and displays current environments for the chosen repository.
- Prompts for the repository, GitHub environment, optional FIC definition file, and builds an app name of the form `Github-OIDC-<environment>`.
- Creates the GitHub environment (if missing) and ensures the FIC definition file (defaults to `fics.json`) exists.
- Confirms Azure CLI authentication and lists available management groups so you can select the scope.
- Creates/reuses an Azure AD app registration and service principal, then guarantees it has Contributor on the selected management group.
- Provisions each federated identity credential from the supplied JSON file.
- Writes `AZURE_CLIENT_ID`, `AZURE_MANAGEMENT_GROUP_ID`, and `AZURE_TENANT_ID` as secrets on the chosen GitHub environment.

## Prerequisites
- Bash environment with `az`, `gh`, `jq`, and `envsubst` on `PATH`.
- Logged-in Azure CLI account with access to list management groups and assign roles.
- Logged-in GitHub CLI account with permission to manage environments and secrets.
- Federated identity definition JSON (see `fics.json` for an example layout).

## Usage
```bash
./new-oidc-mg.sh
```
Follow the prompts:
1. Provide the GitHub repository in `org/repo` form.
2. Supply the GitHub environment name to configure. The script will create it if it does not exist.
3. Accept or override the generated Azure AD app registration name (`Github-OIDC-<environment>`).
4. Point to the FIC definition file (default `fics.json`).
5. Pick the management group (by name, display name, or resource ID) where the service principal should have Contributor access.

The script then runs the Azure/GitHub automation steps without further input. At completion it prints the identifiers for the created/updated resources so you can reference them in workflows or documentation.
