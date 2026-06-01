# =============================================================================
# pipeline.ps1
# Automated Containerization Pipeline with Blockchain Integrity Verification
#
# Usage:
#   .\pipeline.ps1                          # Build, hash, store, verify, deploy
#   .\pipeline.ps1 -SkipBuild               # Hash existing note-app.tar only
#   .\pipeline.ps1 -VerifyOnly              # Verify note-app.tar against blockchain
#
# Required Environment Variables (already set on your machine):
#   ETH_ACCOUNT_ADDRESS  - Ethereum account address
#   ETH_PRIVATE_KEY      - Ethereum private key
#
# Optional Environment Variable:
#   ETH_NODE_URL         - Ethereum node URL (default: http://127.0.0.1:7545)
# =============================================================================

param(
    [string]$ImageName  = "notes-management-app",
    [string]$ArtifactId = "notes-app-v1",
    [string]$Signer     = "pipeline",
    [string]$Stage      = "build",
    [string]$NodeUrl    = "http://127.0.0.1:7545",
    [string]$TarFile    = "note-app.tar",
    [switch]$SkipBuild,
    [switch]$VerifyOnly,
    [switch]$PushToGit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Helper: timestamped log with colour
# -----------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","SUCCESS","ERROR","WARN")]
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "Cyan"    }
        "SUCCESS" { "Green"   }
        "ERROR"   { "Red"     }
        "WARN"    { "Yellow"  }
    }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

# -----------------------------------------------------------------------------
# Helper: abort pipeline on non-zero exit code
# -----------------------------------------------------------------------------
function Assert-Success {
    param([int]$Code, [string]$StepName)
    if ($Code -ne 0) {
        Write-Log "Step '$StepName' failed with exit code $Code. Pipeline aborted." "ERROR"
        exit $Code
    }
}

# -----------------------------------------------------------------------------
# Validate required environment variables
# -----------------------------------------------------------------------------
if (-not $env:ETH_ACCOUNT_ADDRESS) {
    Write-Log "ETH_ACCOUNT_ADDRESS environment variable is not set." "ERROR"
    exit 1
}
if (-not $env:ETH_PRIVATE_KEY) {
    Write-Log "ETH_PRIVATE_KEY environment variable is not set." "ERROR"
    exit 1
}

# Set ETH_NODE_URL for child processes if not already defined
if (-not $env:ETH_NODE_URL) {
    $env:ETH_NODE_URL = $NodeUrl
}

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
$ScriptDir    = $PSScriptRoot
$TarFilePath  = Join-Path $ScriptDir $TarFile
$ArtifactsDir = Join-Path $ScriptDir "artifacts"

# Ensure artifacts/ directory exists (for audit history copies)
if (-not (Test-Path $ArtifactsDir)) {
    New-Item -ItemType Directory -Path $ArtifactsDir | Out-Null
    Write-Log "Created artifacts directory: $ArtifactsDir"
}

# -----------------------------------------------------------------------------
# Pipeline header
# -----------------------------------------------------------------------------
Write-Log "============================================================" "INFO"
Write-Log "        BLOCKCHAIN CI/CD PIPELINE - STARTING" "INFO"
Write-Log "============================================================" "INFO"
Write-Log "Image Name   : $ImageName"
Write-Log "Artifact ID  : $ArtifactId"
Write-Log "Signer       : $Signer"
Write-Log "Stage        : $Stage"
Write-Log "Node URL     : $env:ETH_NODE_URL"
Write-Log "Tar File     : $TarFilePath"
Write-Log "Mode         : $(if ($VerifyOnly) {'VERIFY ONLY'} elseif ($SkipBuild) {'SKIP BUILD'} else {'FULL PIPELINE'})"
Write-Log "============================================================" "INFO"

# Auto-detect if we can skip building because no source files changed
if (-not $VerifyOnly -and -not $SkipBuild -and (Test-Path $TarFilePath)) {
    Write-Log "Checking if any source files have been modified..." "INFO"
    
    # Check git status for modifications in files copied into the docker image
    $GitDiff = git status --porcelain app.py requirements.txt templates Dockerfile 2>$null
    
    if (-not $GitDiff) {
        Write-Log "No source code changes detected. Automatically reusing existing '$TarFile' to maintain hash stability." "SUCCESS"
        $SkipBuild = $true
    } else {
        Write-Log "Source code changes detected. Rebuilding image..." "WARN"
    }
}

if (-not $VerifyOnly -and -not $SkipBuild) {
    Write-Log "STEP 1/5 - Building Docker image '$ImageName'..." "INFO"

    docker build -t $ImageName $ScriptDir
    Assert-Success $LASTEXITCODE "Docker Build"
    Write-Log "Docker image '$ImageName' built successfully." "SUCCESS"

    Write-Log "STEP 2/5 - Exporting image to: $TarFile" "INFO"

    docker save $ImageName -o $TarFilePath
    Assert-Success $LASTEXITCODE "Docker Save"

    $TarSizeMB = [math]::Round((Get-Item $TarFilePath).Length / 1MB, 2)
    Write-Log "Image exported. File: $TarFile  Size: ${TarSizeMB} MB" "SUCCESS"

    # Copy to artifacts/ with timestamp for audit history
    $Timestamp    = Get-Date -Format "yyyyMMdd_HHmmss"
    $HistoryCopy  = Join-Path $ArtifactsDir "$ImageName-$Timestamp.tar"
    Copy-Item -Path $TarFilePath -Destination $HistoryCopy
    Write-Log "Audit copy saved: $HistoryCopy" "INFO"

} else {
    # Verify the tar file exists
    if (-not (Test-Path $TarFilePath)) {
        Write-Log "Tar file not found: $TarFilePath" "ERROR"
        exit 1
    }
    $TarSizeMB = [math]::Round((Get-Item $TarFilePath).Length / 1MB, 2)
    Write-Log "STEP 1-2 SKIPPED. Using existing: $TarFile (${TarSizeMB} MB)" "WARN"
}

# =============================================================================
# STEP 3 & 4 - Integrity Verification & Blockchain State Synchronization
# =============================================================================
if ($VerifyOnly) {
    Write-Log "Verifying $TarFile integrity against blockchain..." "INFO"
    python "$ScriptDir\verify_artifact.py" `
        --artifact-path $TarFilePath `
        --artifact-id   $ArtifactId `
        --node-url      $env:ETH_NODE_URL
    $VerifyExitCode = $LASTEXITCODE

    if ($VerifyExitCode -ne 0) {
        Write-Log "============================================================" "ERROR"
        Write-Log "  VERIFICATION FAILED - ARTIFACT MAY HAVE BEEN TAMPERED" "ERROR"
        Write-Log "  DEPLOYMENT IS BLOCKED. Container will NOT be started." "ERROR"
        Write-Log "============================================================" "ERROR"
        exit 1
    }
    Write-Log "Verification PASSED. $TarFile integrity confirmed." "SUCCESS"
} else {
    Write-Log "Performing pre-check verification of newly built $TarFile against blockchain..." "INFO"
    
    # Run verification check to see if the hash is already authorized on the blockchain
    $VerifyOutput = python "$ScriptDir\verify_artifact.py" `
        --artifact-path $TarFilePath `
        --artifact-id   $ArtifactId `
        --node-url      $env:ETH_NODE_URL 2>&1
    $VerifyExitCode = $LASTEXITCODE

    if ($VerifyExitCode -eq 0) {
        # The hash already matches the blockchain! This is the "same code" (Authorized)
        Write-Log "Verification PASSED. Hash matches blockchain. Already AUTHORIZED." "SUCCESS"
    } else {
        # The hash is different! This could be a new code update or unauthorized tampering
        Write-Log "------------------------------------------------------------" "WARN"
        Write-Log "NEW CODE VERSION DETECTED: Hash of $TarFile does not match blockchain." "WARN"
        Write-Log "------------------------------------------------------------" "WARN"
        
        # Prompt the user for the Ethereum Private Key
        Write-Host "This update is currently UNREGISTERED on the blockchain." -ForegroundColor Yellow
        Write-Host "Please enter the Administrator's Ethereum Private Key to sign this transaction:" -ForegroundColor Cyan
        $InputKey = Read-Host "Ethereum Private Key"
        
        if ([string]::IsNullOrWhiteSpace($InputKey)) {
            Write-Log "============================================================" "ERROR"
            Write-Log "  AUTHENTICATION FAILED - NO KEY PROVIDED" "ERROR"
            Write-Log "  UNAUTHORIZED CHANGE DETECTED - DEPLOYMENT BLOCKED" "ERROR"
            Write-Log "  Deployment aborted. Container will NOT be started." "ERROR"
            Write-Log "============================================================" "ERROR"
            exit 1
        }

        # Backup the current env key
        $OldEnvKey = $env:ETH_PRIVATE_KEY
        
        # Temporarily override with the entered Ethereum private key
        $env:ETH_PRIVATE_KEY = $InputKey.Trim()

        # Attempt to sign and store the hash on the blockchain using the provided key
        Write-Log "Attempting cryptographic transaction signing with the provided Ethereum Private Key..." "INFO"
        
        # Temporarily disable standard error halting so we can handle the python error gracefully
        $OldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"

        python "$ScriptDir\deploy_contract.py" `
            --artifact-path $TarFilePath `
            --artifact-id   $ArtifactId `
            --signer        $Signer `
            --stage         $Stage `
            --node-url      $env:ETH_NODE_URL
            
        $DeployExitCode = $LASTEXITCODE
        
        # Restore the environment key and error preference
        $env:ETH_PRIVATE_KEY = $OldEnvKey
        $ErrorActionPreference = $OldErrorActionPreference

        if ($DeployExitCode -eq 0) {
            Write-Log "ADMINISTRATOR CRYPTOGRAPHIC SIGNATURE VERIFIED successfully!" "SUCCESS"
            Write-Log "New hash registered on blockchain successfully." "SUCCESS"
        } else {
            Write-Log "============================================================" "ERROR"
            Write-Log "  CRYPTOGRAPHIC AUTHENTICATION FAILED - INVALID ETHEREUM PRIVATE KEY" "ERROR"
            Write-Log "  UNAUTHORIZED CHANGE DETECTED - DEPLOYMENT BLOCKED" "ERROR"
            Write-Log "  Deployment aborted. Container will NOT be started." "ERROR"
            Write-Log "============================================================" "ERROR"
            exit 1
        }
    }
}

# =============================================================================
# STEP 5 - Start container via docker-compose
# =============================================================================
if (-not $VerifyOnly) {
    Write-Log "STEP 5/5 - Starting container via docker-compose..." "INFO"

    docker-compose -f "$ScriptDir\docker-compose.yml" up -d
    Assert-Success $LASTEXITCODE "Docker Compose Up"

    Write-Log "Container started successfully." "SUCCESS"
} else {
    Write-Log "STEP 5 SKIPPED (verify-only mode)." "WARN"
}

# =============================================================================
# STEP 6 - Commit and Push to GitHub
# =============================================================================
if ($PushToGit) {
    Write-Log "STEP 6/6 - Committing and pushing code to GitHub..." "INFO"
    
    # Check if there are changes to commit
    $gitStatus = git status --porcelain
    if ($gitStatus) {
        Write-Log "Changes detected. Staging files..." "INFO"
        git add -A
        Assert-Success $LASTEXITCODE "Git Add"
        
        $CommitMsg = "Pipeline Auto-Commit: Verified artifact '$ArtifactId' on blockchain"
        Write-Log "Committing changes with message: '$CommitMsg'..." "INFO"
        git commit -m $CommitMsg
        Assert-Success $LASTEXITCODE "Git Commit"
    } else {
        Write-Log "No local changes to commit." "INFO"
    }

    # Get current branch name
    $Branch = git branch --show-current
    if (-not $Branch) { $Branch = "main" }
    
    Write-Log "Pushing to remote 'origin' on branch '$Branch'..." "INFO"
    git push origin $Branch
    Assert-Success $LASTEXITCODE "Git Push"
    
    Write-Log "Code successfully pushed to GitHub." "SUCCESS"
}

# -----------------------------------------------------------------------------
# Pipeline footer
# -----------------------------------------------------------------------------
Write-Log "============================================================" "SUCCESS"
Write-Log "        PIPELINE COMPLETED SUCCESSFULLY" "SUCCESS"
Write-Log "  Artifact   : $TarFile" "SUCCESS"
Write-Log "  Blockchain : Hash stored and verified" "SUCCESS"
if (-not $VerifyOnly) {
    Write-Log "  Container  : $ImageName running on http://localhost:5000" "SUCCESS"
}
Write-Log "  History    : Audit copies kept in artifacts/" "SUCCESS"
Write-Log "============================================================" "SUCCESS"
