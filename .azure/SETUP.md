# One-time setup: Azure + Azure DevOps

Everything the pipelines in `.azure/` need, in order. It applies to **both** repositories
(`NetCore.API`, `Angular.web`); steps done once are marked **(once)**, steps done per
repository **(each repo)**. Budget: about 1–2 hours, plus up to 3 working days for Microsoft
to grant free hosted build minutes (step 1). Start that first.

Names used below match the YAML. If you change one, change it in
`.azure/templates/variables/common.yml` in **both** repos.

| Thing | Name |
|---|---|
| Resource group | `rg-devops-exercise` |
| Container registry | `acrdevopsexercise`: must be globally unique, pick your own |
| Azure service connection | `sc-devops-exercise-azure` |
| Self-hosted agent pool (IIS server) | `OnPrem-IIS` |
| Environments | `sit`, `uat`, `prod` |
| Variable groups | `devops-exercise-shared`, `devops-exercise-sit`, `devops-exercise-uat`, `devops-exercise-prod` |

---

## 1. Azure DevOps organisation and project (once)

1. Go to <https://dev.azure.com> and create an organisation, then a **private** project, e.g. `DevOpsExercise`.
2. **Request the free hosted-agent grant now:** <https://aka.ms/azpipelines-parallelism-request>.
   New organisations get **zero** Microsoft-hosted minutes until this is approved (2–3 working
   days). Check under *Project settings → Parallel jobs*. The Build stage and the Container Apps
   jobs need hosted Linux agents; only IIS deployments use your own agent.

## 2. Azure resources (once)

Use Azure Cloud Shell (Bash) or a local `az` login with Owner on the subscription.

```bash
az group create --name rg-devops-exercise --location centralindia

for p in Microsoft.App Microsoft.OperationalInsights Microsoft.ContainerRegistry; do
  az provider register --namespace "$p" --wait
done

# From a clone of NetCore.API (the Bicep provisions the PROD side of BOTH apps).
az deployment group create \
  --resource-group rg-devops-exercise \
  --template-file .azure/infra/main.bicep \
  --parameters acrName=<your-unique-acr-name>
```

The outputs give `acrLoginServer`, `apiUrl` and `webUrl`. Both apps start on a placeholder image
until the first PROD deployment.

Then set `acrName: <your-unique-acr-name>` in `.azure/templates/variables/common.yml`
**in both repos**.

**Image retention** (keep the newest 10 builds per repository, plus any image a live Container
App revision still runs; untagged manifests are purged). Nothing to set up: the pipeline runs
`.azure/scripts/acr-retention.sh` after every push. The alternatives aren't available everywhere:
ACR's retention *policy* is Premium-only, and ACR Tasks (`acr purge` on a schedule) are blocked on
free-trial and some sponsored subscriptions with `TasksOperationsNotAllowed`.

**Registry-level image scanning (optional, paid after a 30-day trial).** Microsoft Defender for
Containers scans every image pushed to ACR:
`az security pricing create --name Containers --tier standard`.
The pipeline's own Trivy gates don't depend on it.

## 3. Service connections (once)

*Project settings → Service connections → New service connection*

**a. Azure Resource Manager: keyless (OIDC)**
- Identity type **App registration (automatic)**, credential **Workload identity federation**.
- Scope **Subscription** → your subscription → resource group `rg-devops-exercise`.
- Name **`sc-devops-exercise-azure`**. Leave *Grant access permission to all pipelines*
  **unchecked**, so each pipeline is authorised on its first run.

This creates an Entra app registration with a *federated credential*. Azure DevOps exchanges a
short-lived OIDC token for an Azure token on every run, so there's no client secret to store,
rotate or leak. The connection gets **Contributor** on the resource group. Also give it push
rights on the registry explicitly (Contributor doesn't cover it when the registry uses
ABAC repository permissions):

```bash
SP_ID=<"Service principal Id" from the connection's "Manage service connection roles" / App registration>
ACR_ID=$(az acr show -n <your-unique-acr-name> --query id -o tsv)
az role assignment create --assignee "$SP_ID" --role AcrPush --scope "$ACR_ID"
az role assignment create --assignee "$SP_ID" --role AcrDelete --scope "$ACR_ID"   # retention clean-up
```

**b. GitHub.** Nothing to create by hand. When you create the pipelines (step 7), Azure DevOps
offers to install the **Azure Pipelines GitHub App** on `rohityadav10/NetCore.API` and
`rohityadav10/Angular.web`. Accept it for just those two repos. **Don't** use a GitHub password
anywhere; the App uses scoped, revocable tokens.

## 4. Agent on the IIS server (once)

The SIT/UAT deployments run **on the IIS server itself** (`rohit-vm`), through an Azure DevOps
agent. It sits next to the existing GitHub Actions runner; they don't interfere.

1. *Organization settings → Agent pools → Add pool*: **Self-hosted**, name **`OnPrem-IIS`**.
   Don't grant it to all pipelines.
2. *User settings → Personal access tokens*: create a PAT with scope **Agent Pools (Read & manage)**
   only, expiring in 1 day. It's used once, to register the agent.
3. On `rohit-vm`, in an **elevated** PowerShell:

   ```powershell
   # Prerequisites (skip what is already installed)
   Install-WindowsFeature Web-Server, Web-Scripting-Tools, Web-Mgmt-Console
   #  - ASP.NET Core 8 Hosting Bundle: https://dotnet.microsoft.com/download/dotnet/8.0 (then: iisreset)
   #  - IIS URL Rewrite 2.1: https://www.iis.net/downloads/microsoft/url-rewrite (needed for SPA deep links)

   # Agent: take the current download link from the pool's "New agent" button.
   New-Item -ItemType Directory C:\azagent | Out-Null; Set-Location C:\azagent
   Invoke-WebRequest -Uri <agent-zip-url> -OutFile agent.zip
   Expand-Archive agent.zip -DestinationPath .
   .\config.cmd --unattended `
     --url https://dev.azure.com/<your-org> --auth pat --token <PAT> `
     --pool OnPrem-IIS --agent rohit-vm `
     --runAsService --windowsLogonAccount "NT AUTHORITY\SYSTEM"
   ```

   Use the **x64** package (the *New agent → Windows* page may be on *x86*; the URL must say
   `vsts-agent-win-x64`). A 32-bit agent runs 32-bit PowerShell, and IIS's configuration API is
   64-bit only: every deployment would fail with `80040154 Class not registered`. The deploy scripts
   refuse to run under 32-bit PowerShell and name this cause.

   The agent runs as SYSTEM because managing IIS app pools and sites needs local admin rights.
   Revoke the PAT afterwards; the agent keeps its own credential.

4. To browse the ADO-deployed sites from other machines, open the ports:
   `New-NetFirewallRule -DisplayName "ADO IIS sites" -Direction Inbound -Protocol TCP -LocalPort 8180,8181,8280,8281 -Action Allow`
   and set `iisPublicHost` in `common.yml` to `http://<server-dns-name>` (both repos).

The pipeline creates the IIS sites and app pools itself on the first deployment:
`ado-netcore-api-sit` :8181, `ado-angular-web-sit` :8180, `ado-*-uat` :8281/:8280.
They never touch the GitHub-deployed `NetCoreAPI` (:8080) or `Default Web Site` (:80).

> **Jump-box variant.** If the agent can't live on the IIS server, install it on a jump box,
> enable WinRM on the IIS server (`Enable-PSRemoting`; HTTPS listener recommended), add
> `IIS_DEPLOY_USERNAME` / `IIS_DEPLOY_PASSWORD` (secret) to the environment's variable group, and
> pass `targetServer: <iis-host>` to `templates/jobs/deploy-iis.yml`. `deploy-iis.ps1` then copies
> the artifact over PowerShell remoting and runs the same steps there.

## 5. Environments, approvals and checks (once)

*Pipelines → Environments → New environment*, three times, Resource **None**: `sit`, `uat`, `prod`.
Then *environment → ⋯ → Approvals and checks*:

| Environment | Checks |
|---|---|
| `sit` | none: deploys automatically on merge. Optional: **Exclusive lock**. |
| `uat` | **Approvals**: QA lead(s); untick *Allow approvers to approve their own runs*; timeout 3 days. |
| `prod` | **Approvals**: list the release manager **and** the product owner / business sign-off as approvers. With several individual users listed, **all** must approve: that's the second sign-off. **Business hours**: Mon–Thu, 09:00–17:00, *(UTC+05:30) Chennai, Kolkata, Mumbai, New Delhi*. **Branch control**: allowed branches `refs/heads/release,refs/heads/main`. **Exclusive lock**: one production deployment at a time. |

Working alone on the exercise? Add only yourself, and keep *Allow approvers to approve their own
runs* ticked under **Advanced**, or you can't approve the runs you queued.

Approvers get an e-mail automatically when a stage waits for them. The pipeline's own automated
PROD checks (evidence plus a fresh re-scan) run in the `Preflight` job after the approvals.

## 6. Variable groups (once)

*Pipelines → Library → + Variable group*. Tick the 🔒 on every secret value.

| Group | Variable | Secret | Value |
|---|---|---|---|
| `devops-exercise-shared` | `TEAMS_WEBHOOK_URL` | yes | Teams → channel → *Workflows* → "Post to a channel when a webhook request is received" → copy URL. **Leave empty** to disable notifications. |
| `devops-exercise-sit` | `ConnectionStrings__Default` | yes | SIT SQL Server connection string (placeholder is fine: the sample API has no database yet) |
| `devops-exercise-uat` | `ConnectionStrings__Default` | yes | UAT connection string |
| `devops-exercise-prod` | `ConnectionStrings__Default` | yes | PROD connection string |

Optional: create the groups with *Link secrets from an Azure key vault* instead, so the secrets
live in Key Vault and Azure DevOps only references them.

## 7. Create the pipelines (each repo)

*Pipelines → New pipeline → GitHub (YAML)* → pick the repo (install the Azure Pipelines app when
asked) → **Existing Azure Pipelines YAML file**:

| Repo | Pipeline name | Branch | Path |
|---|---|---|---|
| NetCore.API | `NetCore.API` | `release` (or `feature/azure-devops` before it's merged) | `/.azure/azure-pipelines.yml` |
| NetCore.API | `NetCore.API - rollback` | `release` | `/.azure/rollback.yml` |
| Angular.web | `Angular.web` | `release` | `/.azure/azure-pipelines.yml` |
| Angular.web | `Angular.web - rollback` | `release` | `/.azure/rollback.yml` |

Choose **Save** (not Run), then rename. Use the pipeline editor's **⋯ → Validate** to compile the
YAML without running it. On the first run Azure DevOps shows *"This pipeline needs permission to
access N resources"*. Choose **Permit** for the service connection, agent pool, environments and
variable groups: that's the per-pipeline authorisation from step 3.

## 8. GitHub branch protection (each repo)

GitHub → *Settings → Branches → Add rule* for `release`:
*Require a pull request before merging*, and *Require status checks to pass*. Select the
`NetCore.API` / `Angular.web` Azure Pipelines check (it appears after the pipeline's first PR run).
The flow is now enforced: feature branch → PR → all gates green → merge → SIT.

## 9. Optional extensions (once)

- **SARIF SAST Scans Tab** (free, Marketplace): renders the `CodeAnalysisLogs` artifact
  (Semgrep findings) as a *Scans* tab on each run.
- **SonarCloud** (free for public repos): install the extension, create a `SonarCloud` service
  connection named `sc-sonarcloud`, set `sonarCloudOrganization` in `azure-pipelines.yml`, and
  queue with **Run SonarCloud analysis** ticked. The build then also fails on the SonarCloud
  quality gate.

## 10. First run: what you should see

1. **Push `feature/azure-devops`**: only the Build stage runs. Check the *Tests* and
   *Code Coverage* tabs, and the artifacts: `api-drop`/`web-drop`, `deploy-scripts`,
   `quality-*`, `CodeAnalysisLogs`. No image is pushed.
2. **Merge the PR into `release`**: Build, image pushed to ACR as `<repo>:<build number>`,
   then **SIT deploys by itself**. Open `http://rohit-vm:8180`: the badge reads
   `SIT | v<build> | Operational | API: Healthy v<build>` once both apps are deployed.
3. **UAT** waits for approval; approve it in the run view.
4. **PROD** waits for both approvals *and* business hours, runs `Preflight`, then the canary.
   Open the Bicep `webUrl`: `PROD | v<build> | ... | API: Healthy v<build>`.
5. **Rollback drill**: queue `NetCore.API - rollback` with `target = sit` and see the site
   switch back to the previous build (`deployments.log` under `C:\inetpub\ado\<site>` on the server).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No hosted parallelism has been purchased or granted` | Step 1: the grant hasn't been approved yet. |
| `Variable group was not found or not authorized` | Create all four groups (step 6), then *Permit* on the run. |
| `unauthorized: authentication required` on `docker push` | AcrPush role missing (step 3a), or `acrName` in `common.yml` doesn't match the registry. |
| IIS stage: `Import-Module WebAdministration` fails | Install `Web-Scripting-Tools` (step 4). |
| IIS stage: `80040154 Class not registered`, or "32-bit PowerShell cannot manage IIS" | The x86 agent is installed; reinstall with `vsts-agent-win-x64` (step 4). |
| IIS API site answers HTTP 500.19 / 500.31 | ASP.NET Core Hosting Bundle missing; install, then `iisreset`. |
| SPA deep link (e.g. `/some/route`) returns 404 on IIS | URL Rewrite isn't installed. The deploy logs a warning and skips the rule rather than break the site. |
| PROD stage waits with "Business hours" | By design; it resumes inside the window. |
