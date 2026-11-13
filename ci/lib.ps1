# Shared helpers for the Healthcare CI/CD Jenkins pipeline.
#
# Dot-source from a Jenkins `powershell` step:   . "$env:WORKSPACE\ci\lib.ps1"
#
# Designed for Windows PowerShell 5.1 running under the Jenkins service
# account (LocalSystem). Nothing in here prints secret material.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:SystemSid = 'S-1-5-18'          # NT AUTHORITY\SYSTEM
$script:AdministratorsSid = 'S-1-5-32-544'

function Write-Section([string]$Text) {
    Write-Host ''
    Write-Host "==== $Text ===="
}

function Invoke-Native {
    <#
      Runs a native executable, streams its stdout+stderr to the log and
      returns @{ ExitCode; Output }.  Windows PowerShell 5.1 wraps native
      stderr lines in ErrorRecords and, with ErrorActionPreference=Stop,
      throws on the first one (e.g. a benign "Warning: Permanently added"
      from ssh or docker build progress).  Here stderr is converted to
      plain text and success/failure is decided ONLY by the exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$InputText,
        [switch]$Quiet
    )
    $buffer = New-Object System.Collections.Generic.List[string]
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $handler = {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            $buffer.Add($line)
            if (-not $Quiet) { Write-Host $line }
        }
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $InputText | & $FilePath @ArgumentList 2>&1 | ForEach-Object $handler
        } else {
            & $FilePath @ArgumentList 2>&1 | ForEach-Object $handler
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
        # The exit code has been captured and is judged by the caller. Reset
        # it so an *expected* non-zero code (e.g. `git grep` finding nothing)
        # does not leak out as the Jenkins powershell step's exit status.
        # Genuine failures are raised with `throw`, which still fails the step.
        $global:LASTEXITCODE = 0
    }
    if ($null -eq $exitCode) { $exitCode = -1 }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $buffer.ToArray() }
}

function Assert-Success {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Message)
    if ($Result.ExitCode -ne 0) {
        throw "$Message (exit code $($Result.ExitCode))"
    }
}

function Assert-SafeToken {
    # Values interpolated into remote shell command lines must be simple tokens.
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -notmatch '^[A-Za-z0-9._:/@-]+$') {
        throw "Unsafe value for ${Name}: only [A-Za-z0-9._:/@-] is allowed."
    }
}

function Write-Utf8NoBomLf {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $normalised = $Text.Replace("`r`n", "`n")
    [IO.File]::WriteAllText($Path, $normalised, (New-Object System.Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------------------
# Windows ACL hardening
# ---------------------------------------------------------------------------

function Get-AllowedSids {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sids = @($script:SystemSid)
    if ($current -ne $script:SystemSid) { $sids += $current }   # only when not running as LocalSystem
    return ,$sids
}

function Invoke-Icacls {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$Purpose)
    $result = Invoke-Native -FilePath 'icacls.exe' -ArgumentList $Arguments -Quiet
    if ($result.ExitCode -ne 0) {
        $result.Output | ForEach-Object { Write-Host "  icacls: $_" }
        throw "icacls failed while trying to $Purpose (exit code $($result.ExitCode))."
    }
}

function Protect-PrivatePath {
    <#
      Restricts a file or directory so that only NT AUTHORITY\SYSTEM
      (S-1-5-18) - plus the current account when not running as SYSTEM -
      has access.  Inherited ACEs (e.g. BUILTIN\Users:(RX) inherited from
      the Jenkins workspace) are removed, every other explicit ACE is
      removed, the owner is fixed if necessary, and the result is verified.
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Path to protect does not exist: $Path" }
    $allowed = Get-AllowedSids
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $inherit = if ($Directory) { '(OI)(CI)' } else { '' }

    # 1. Disable inheritance and drop all inherited ACEs.
    Invoke-Icacls -Arguments @($Path, '/inheritance:r') -Purpose 'remove inherited permissions'

    # 2. Grant full control to the allowed SIDs only (replacing their explicit ACEs).
    foreach ($sid in $allowed) {
        Invoke-Icacls -Arguments @($Path, '/grant:r', "*${sid}:${inherit}(F)") -Purpose "grant access to $sid"
    }

    # 3. Remove any remaining explicit ACE for any other principal.
    $acl = Get-Acl -LiteralPath $Path
    $others = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
        ForEach-Object { $_.IdentityReference.Value } |
        Where-Object { $allowed -notcontains $_ } | Sort-Object -Unique)
    foreach ($sid in $others) {
        Invoke-Icacls -Arguments @($Path, '/remove', "*$sid") -Purpose "remove access for $sid"
    }

    # 4. OpenSSH requires the owner to be the current user, SYSTEM or Administrators.
    $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if (@($script:SystemSid, $script:AdministratorsSid, $currentSid) -notcontains $owner) {
        Invoke-Icacls -Arguments @($Path, '/setowner', "*$currentSid") -Purpose 'set the file owner'
    }

    # 5. Verify.
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { throw "ACL verification failed: inheritance is still enabled on $Path" }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $unexpected = @($rules | Where-Object { $allowed -notcontains $_.IdentityReference.Value })
    if ($unexpected.Count -gt 0) {
        throw "ACL verification failed: unexpected principals still have access: $(($unexpected | ForEach-Object { $_.IdentityReference.Value }) -join ', ')"
    }
    $mine = @($rules | Where-Object { $_.IdentityReference.Value -eq $currentSid -and $_.AccessControlType -eq 'Allow' })
    if ($mine.Count -eq 0) { throw "ACL verification failed: the current account ($currentSid) has no access." }
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if (@($script:SystemSid, $script:AdministratorsSid, $currentSid) -notcontains $owner) {
        throw "ACL verification failed: owner $owner is not permitted."
    }
    Write-Host "Protected ACL verified (owner $owner; access limited to $($allowed -join ', '))."
}

# ---------------------------------------------------------------------------
# SSH to the EC2 K3s node
# ---------------------------------------------------------------------------

function Get-KnownHostsPath { return (Join-Path $env:CI_TMP 'ec2_known_hosts') }

function Initialize-Ec2KnownHosts {
    <#
      Fetches the EC2 host's ED25519 key and accepts it ONLY if its SHA256
      fingerprint matches the pinned EC2_HOSTKEY_FP.  ssh then runs with
      StrictHostKeyChecking=yes against this file, so a replaced or
      impersonated host is rejected.
    #>
    $knownHosts = Get-KnownHostsPath
    $line = $null
    for ($attempt = 1; $attempt -le 3 -and -not $line; $attempt++) {
        $scan = Invoke-Native -FilePath 'ssh-keyscan.exe' -ArgumentList @('-T', '10', '-t', 'ed25519', $env:EC2_HOST) -Quiet
        $line = $scan.Output | Where-Object { $_ -match '^\S+\s+ssh-ed25519\s+[A-Za-z0-9+/=]+\s*$' } | Select-Object -First 1
        if (-not $line -and $attempt -lt 3) {
            Write-Host "ssh-keyscan attempt $attempt/3 returned no ED25519 key; retrying in 5s."
            Start-Sleep -Seconds 5
        }
    }
    if (-not $line) { throw "Could not retrieve the SSH host key of $($env:EC2_HOST) (port 22 unreachable or blocked)." }

    Write-Utf8NoBomLf -Path $knownHosts -Text ($line.Trim() + "`n")
    $fp = Invoke-Native -FilePath 'ssh-keygen.exe' -ArgumentList @('-l', '-E', 'sha256', '-f', $knownHosts) -Quiet
    Assert-Success $fp 'ssh-keygen could not fingerprint the scanned host key'
    $actual = (($fp.Output -join ' ') -split '\s+') | Where-Object { $_ -like 'SHA256:*' } | Select-Object -First 1
    if ($actual -ne $env:EC2_HOSTKEY_FP) {
        Remove-Item -LiteralPath $knownHosts -Force
        throw "HOST KEY MISMATCH for $($env:EC2_HOST): expected $($env:EC2_HOSTKEY_FP), got $actual. The IP may now belong to a different machine. Refusing to connect."
    }
    Write-Host "EC2 host key verified against pinned fingerprint $actual."
}

function Initialize-SshSession {
    # Idempotent: secure the Jenkins-provided key file and the pinned known_hosts.
    if (-not $env:EC2_SSH -or -not (Test-Path -LiteralPath $env:EC2_SSH -PathType Leaf)) {
        throw "The SSH private key from Jenkins credential 'aws-ec2-ssh' is not available."
    }
    Protect-PrivatePath -Path $env:EC2_SSH
    if (-not (Test-Path -LiteralPath (Get-KnownHostsPath))) { Initialize-Ec2KnownHosts }
}

function Get-SshOptions {
    $knownHosts = (Get-KnownHostsPath).Replace('\', '/')
    return @(
        '-i', $env:EC2_SSH,
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', "UserKnownHostsFile=$knownHosts",
        '-o', 'HostKeyAlgorithms=ssh-ed25519',
        '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=4',
        '-o', 'LogLevel=ERROR'
    )
}

function Get-SshTarget { return "$($env:EC2_SSH_USR)@$($env:EC2_HOST)" }

function Write-SshDiagnosis {
    param([string[]]$Output)
    $text = $Output -join "`n"
    if ($text -match 'UNPROTECTED PRIVATE KEY FILE|bad permissions') {
        Write-Host 'DIAGNOSIS: OpenSSH rejected the private key file permissions.'
    } elseif ($text -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed') {
        Write-Host 'DIAGNOSIS: Host key verification failed - the host is not the pinned EC2 instance.'
    } elseif ($text -match 'Permission denied \(publickey') {
        Write-Host "DIAGNOSIS: The EC2 host rejected the key - credential 'aws-ec2-ssh' does not match the instance key pair, or the username is wrong."
    } elseif ($text -match 'timed out|Connection refused|No route to host|Could not resolve') {
        Write-Host 'DIAGNOSIS: Network failure - instance stopped, IP changed, or the security group does not allow this agent on port 22.'
    }
}

function Invoke-Ssh {
    param([Parameter(Mandatory)][string]$RemoteCommand, [switch]$Quiet)
    $sshArgs = (Get-SshOptions) + @((Get-SshTarget), $RemoteCommand)
    $result = Invoke-Native -FilePath 'ssh.exe' -ArgumentList $sshArgs -Quiet:$Quiet
    if ($result.ExitCode -eq 255) { Write-SshDiagnosis $result.Output }
    return $result
}

function Invoke-RemoteBundle {
    <#
      Copies the given files (paths relative to $LocalDir) into a fresh
      mktemp directory on the EC2 host, runs the entry script with bash,
      and always removes the remote directory afterwards.  Returns the
      result of the entry script.
    #>
    param(
        [Parameter(Mandatory)][string]$LocalDir,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$EntryScript,
        [string[]]$ScriptArguments = @()
    )
    foreach ($value in $ScriptArguments) { Assert-SafeToken -Value $value -Name 'remote script argument' }

    $mk = Invoke-Ssh -RemoteCommand 'mktemp -d /tmp/healthcare-ci.XXXXXXXXXX' -Quiet
    Assert-Success $mk 'Could not create a remote working directory over SSH'
    $remoteDir = $mk.Output | Where-Object { $_ -match '^/tmp/healthcare-ci\.[A-Za-z0-9]{10}$' } | Select-Object -Last 1
    if (-not $remoteDir) { throw 'Unexpected output from remote mktemp.' }

    try {
        Push-Location -LiteralPath $LocalDir
        try {
            $scpArgs = (Get-SshOptions) + $Files + @("$(Get-SshTarget):$remoteDir/")
            $copy = Invoke-Native -FilePath 'scp.exe' -ArgumentList $scpArgs
            Assert-Success $copy 'Copying files to the EC2 host failed'
        } finally {
            Pop-Location
        }
        $command = (@('bash', "$remoteDir/$EntryScript", $remoteDir) + $ScriptArguments) -join ' '
        return (Invoke-Ssh -RemoteCommand $command)
    } finally {
        $cleanup = Invoke-Ssh -RemoteCommand "rm -rf -- $remoteDir" -Quiet
        if ($cleanup.ExitCode -ne 0) { Write-Warning "Could not remove remote directory $remoteDir (exit $($cleanup.ExitCode))." }
    }
}

function New-DeploymentBundle {
    <#
      Copies the Kubernetes manifests and remote scripts into $Destination
      (LF line endings, no BOM) and pins the Deployment to $Image.  Fails if
      the image line cannot be replaced exactly once.
    #>
    param([Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Image)
    Assert-SafeToken -Value $Image -Name 'image'
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination | Out-Null

    $sources = @{
        'namespace.yaml'  = 'k8s\namespace.yaml'
        'service.yaml'    = 'k8s\service.yaml'
        'deployment.yaml' = 'k8s\deployment.yaml'
        'verify-host.sh'  = 'ci\remote\verify-host.sh'
        'deploy.sh'       = 'ci\remote\deploy.sh'
        'smoke-test.sh'   = 'ci\remote\smoke-test.sh'
    }
    foreach ($name in $sources.Keys) {
        $text = [IO.File]::ReadAllText((Join-Path $env:WORKSPACE $sources[$name]))
        if ($name -eq 'deployment.yaml') {
            $pattern = '(?m)^(\s*image:\s*)niranjanbalaguru/healthcare-app:[^\s#]+[ \t]*\r?$'
            $found = [regex]::Matches($text, $pattern)
            if ($found.Count -ne 1) { throw "Expected exactly one healthcare-app image line in k8s/deployment.yaml, found $($found.Count)." }
            $text = [regex]::Replace($text, $pattern, ('${1}' + $Image))
        }
        Write-Utf8NoBomLf -Path (Join-Path $Destination $name) -Text $text
    }
    Write-Host "Deployment bundle rendered for image $Image"
}

# ---------------------------------------------------------------------------
# Docker Hub registry API (verifies what is actually stored in Docker Hub)
# ---------------------------------------------------------------------------

function Get-DockerHubDigest {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Tag)
    $pair = "$($env:DOCKERHUB_USR):$($env:DOCKERHUB_PSW)"
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    $tokenUri = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${Repository}:pull"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Headers @{ Authorization = "Basic $basic" } -TimeoutSec 30
    $accept = @(
        'application/vnd.oci.image.index.v1+json',
        'application/vnd.docker.distribution.manifest.list.v2+json',
        'application/vnd.oci.image.manifest.v1+json',
        'application/vnd.docker.distribution.manifest.v2+json'
    ) -join ', '
    $response = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 30 `
        -Uri "https://registry-1.docker.io/v2/$Repository/manifests/$Tag" `
        -Headers @{ Authorization = "Bearer $($tokenResponse.token)"; Accept = $accept }
    return [string]$response.Headers['Docker-Content-Digest']
}
