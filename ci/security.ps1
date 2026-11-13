# Activity 9 - DevSecOps scanner stages (job Healthcare-DevSecOps).
#
# Dot-source from a Jenkins `powershell` step:   . "$env:WORKSPACE/ci/security.ps1"
#
# Every scanner runs in a pinned container image. Inputs are copied INTO the
# container and reports copied OUT with `docker cp` (daemon API) instead of
# bind mounts, so the SYSTEM-only ACLs on the private temp directory never
# have to be relaxed for Docker Desktop's file sharing.
#
# Each scanner's exit code is recorded in reports/<tool>.exitcode. An exit
# code that indicates a tool failure (not "findings") fails the stage
# immediately; findings themselves are judged by ci/security/evaluate_policy.py.

. (Join-Path $PSScriptRoot 'stages.ps1')

$script:ScannerImages = @{
    trivy    = 'ghcr.io/aquasecurity/trivy:0.76.1'
    gitleaks = 'ghcr.io/gitleaks/gitleaks:v8.30.1'
    zap      = 'ghcr.io/zaproxy/zaproxy:2.16.1'
}
$script:ToolOkCodes = @{
    'gitleaks' = @(0, 3); 'semgrep' = @(0, 1); 'pip-audit' = @(0, 1)
    'trivy-image' = @(0); 'trivy-dockerfile' = @(0); 'trivy-k8s' = @(0); 'sbom' = @(0)
    'zap-baseline' = @(0, 1, 2); 'zap-api' = @(0, 1, 2)
}
$script:TrivyCacheVolume = 'healthcare-trivy-cache'

function Get-ReportsDir { return (Join-Path $env:WORKSPACE 'reports') }
function Get-SecToolsImage {
    # Tag = first 12 hex chars of the tools Dockerfile hash: identical in every
    # stage, and any change to the pinned tool versions forces a rebuild.
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $env:WORKSPACE 'ci/security/tools.Dockerfile')).Hash
    return "healthcare-sectools:$($hash.Substring(0, 12).ToLowerInvariant())"
}

function Invoke-ContainerTool {
    <#
      docker create -> docker cp inputs -> docker start -a -> docker cp outputs -> docker rm.
      Records the exit code and throws on tool failure (exit code not in the
      tool's success set) or when an expected report is missing.
    #>
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Image,
        [string[]]$Command = @(),
        [hashtable]$Inputs = @{},      # local path -> container path
        [hashtable]$Outputs = @{},     # container path -> local path
        [string[]]$RunArgs = @()
    )
    $name = "sec-$Tool-$env:BUILD_NUMBER"
    Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $name) -Quiet | Out-Null
    $create = Invoke-Native -FilePath 'docker' -ArgumentList (@('create', '--name', $name) + $RunArgs + @($Image) + $Command) -Quiet
    Assert-Success $create "Could not create the $Tool container"
    try {
        foreach ($local in $Inputs.Keys) {
            $cp = Invoke-Native -FilePath 'docker' -ArgumentList @('cp', $local, "${name}:$($Inputs[$local])") -Quiet
            Assert-Success $cp "Copying $local into the $Tool container failed"
        }
        Write-Host "---- $Tool ($Image) ----"
        $run = Invoke-Native -FilePath 'docker' -ArgumentList @('start', '-a', $name)
        $code = $run.ExitCode
        Write-Utf8NoBomLf -Path (Join-Path (Get-ReportsDir) "$Tool.exitcode") -Text "$code`n"
        if ($script:ToolOkCodes[$Tool] -notcontains $code) {
            throw "TOOL ERROR: $Tool exited with code $code, which indicates a scanner failure (not a finding). The scan result cannot be trusted."
        }
        foreach ($inner in $Outputs.Keys) {
            $cp = Invoke-Native -FilePath 'docker' -ArgumentList @('cp', "${name}:$inner", $Outputs[$inner]) -Quiet
            Assert-Success $cp "TOOL ERROR: $Tool did not produce the expected report $inner"
        }
        Write-Host "$Tool finished with exit code $code"
        return $run
    } finally {
        Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $name) -Quiet | Out-Null
    }
}

function Initialize-SecurityTools {
    New-Item -ItemType Directory -Force -Path (Get-ReportsDir) | Out-Null
    foreach ($image in $script:ScannerImages.Values) {
        $present = Invoke-Native -FilePath 'docker' -ArgumentList @('image', 'inspect', $image) -Quiet
        if ($present.ExitCode -ne 0) {
            $pulled = $false
            for ($attempt = 1; $attempt -le 3 -and -not $pulled; $attempt++) {
                $pull = Invoke-Native -FilePath 'docker' -ArgumentList @('pull', '-q', $image) -Quiet
                $pulled = ($pull.ExitCode -eq 0)
                if (-not $pulled -and $attempt -lt 3) { Write-Host "pull of $image failed (attempt $attempt/3); retrying in 10s"; Start-Sleep -Seconds 10 }
            }
            if (-not $pulled) { throw "TOOL ERROR: could not pull scanner image $image" }
        }
        Write-Host "scanner image ready: $image"
    }
    # Python tools (Semgrep, pip-audit, PyYAML) in a pinned image; the tag is
    # derived from the Dockerfile content so a change forces a rebuild.
    $build = Invoke-Native -FilePath 'docker' -ArgumentList @('build', '-q', '-f', 'ci/security/tools.Dockerfile', '-t', (Get-SecToolsImage), 'ci/security') -Quiet
    Assert-Success $build 'Building the security tools image failed'
    $versions = Invoke-Native -FilePath 'docker' -ArgumentList @('run', '--rm', '--network', 'none', (Get-SecToolsImage), 'sh', '-c', 'semgrep --version; pip-audit --version') -Quiet
    Assert-Success $versions 'Security tools image is not functional'
    Write-Host "security tools image ready: $(Get-SecToolsImage) (semgrep $($versions.Output[-2]), $($versions.Output[-1]))"

    # Clean export of exactly the commit under test (no workspace leftovers).
    $src = Join-Path $env:CI_TMP 'src'
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    $tar = Join-Path $env:CI_TMP 'src.tar'
    Assert-Success (Invoke-Native -FilePath 'git' -ArgumentList @('archive', '--format=tar', '-o', $tar, $env:GIT_COMMIT_FULL) -Quiet) 'git archive failed'
    # Use Windows' bsdtar explicitly: Git's GNU tar (often first on PATH) treats
    # 'C:\...' as a remote host specification and fails.
    $bsdtar = Join-Path $env:SystemRoot 'System32/tar.exe'
    Assert-Success (Invoke-Native -FilePath $bsdtar -ArgumentList @('-xf', $tar, '-C', $src) -Quiet) 'extracting the source export failed'
    Remove-Item -LiteralPath $tar -Force
    foreach ($f in 'app/app.py', 'Dockerfile', 'app/requirements.txt', 'k8s/deployment.yaml', 'ci/security/evaluate_policy.py') {
        if (-not (Test-Path -LiteralPath (Join-Path $src $f) -PathType Leaf)) { throw "Source export is incomplete: $f missing. Refusing to scan an empty tree." }
    }
    Write-Host "source export of $env:GIT_COMMIT_SHORT prepared for scanning"
}

function Get-SourceExport { return (Join-Path $env:CI_TMP 'src') }

function Invoke-SecretScan {
    $reports = Get-ReportsDir
    Write-Section 'Gitleaks: full Git history of the repository'
    Invoke-ContainerTool -Tool 'gitleaks' -Image $script:ScannerImages.gitleaks `
        -Command @('git', '/repo', '--redact', '--no-banner', '--report-format', 'json', '--report-path', '/tmp/gitleaks.json', '--exit-code', '3') `
        -Inputs @{ (Join-Path $env:WORKSPACE '.') = '/repo' } -Outputs @{ '/tmp/gitleaks.json' = (Join-Path $reports 'gitleaks.json') } | Out-Null
    $leaks = @(Get-Content -Raw (Join-Path $reports 'gitleaks.json') | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ })
    Write-Host "Gitleaks history scan: $($leaks.Count) leak(s) found (secret values are redacted in the report)."

    Write-Section 'Gitleaks self-test: a synthetic secret must be detected'
    $fixtureDir = Join-Path $env:CI_TMP 'secret-fixture'
    New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null
    $rng = New-Object System.Random
    $alnum = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/+'
    $akid = 'AKIA' + -join (1..16 | ForEach-Object { $alnum[$rng.Next($alnum.Length)] })
    $sk = -join (1..40 | ForEach-Object { $b64[$rng.Next($b64.Length)] })
    # Random, non-functional values generated at runtime; never committed or printed.
    Write-Utf8NoBomLf -Path (Join-Path $fixtureDir 'synthetic_credentials.py') -Text "aws_access_key_id = `"$akid`"`naws_secret_access_key = `"$sk`"`n"
    Remove-Variable akid, sk
    $selfTest = Join-Path $reports 'gitleaks-selftest.json'
    $prevOk = $script:ToolOkCodes['gitleaks']
    try {
        $script:ToolOkCodes['gitleaks-selftest'] = @(3)   # the self-test MUST find the secret
        Invoke-ContainerTool -Tool 'gitleaks-selftest' -Image $script:ScannerImages.gitleaks `
            -Command @('dir', '/scan', '--redact', '--no-banner', '--report-format', 'json', '--report-path', '/tmp/selftest.json', '--exit-code', '3') `
            -Inputs @{ (Join-Path $fixtureDir '.') = '/scan' } -Outputs @{ '/tmp/selftest.json' = $selfTest } | Out-Null
    } finally {
        Remove-Item -LiteralPath $fixtureDir -Recurse -Force
        $script:ToolOkCodes['gitleaks'] = $prevOk
    }
    if (Test-Path -LiteralPath $fixtureDir) { throw 'The synthetic secret fixture could not be removed.' }
    $detected = @(Get-Content -Raw $selfTest | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ })
    $rules = @($detected | ForEach-Object { $_.RuleID } | Sort-Object -Unique)
    if ($rules -notcontains 'aws-access-token') { throw "Gitleaks self-test FAILED: the synthetic AWS access key was not detected (rules: $($rules -join ', '))." }
    if (@($detected | Where-Object { $_.Secret -ne 'REDACTED' }).Count -gt 0) { throw 'Gitleaks self-test report contains unredacted secret values.' }
    Write-Host "Gitleaks self-test PASSED: detected [$($rules -join ', ')] in the synthetic fixture; values redacted; fixture removed."
}

function Invoke-Sast {
    $reports = Get-ReportsDir
    Invoke-ContainerTool -Tool 'semgrep' -Image (Get-SecToolsImage) `
        -Command @('semgrep', 'scan', '--config', 'p/python', '--config', 'p/flask', '--config', 'p/dockerfile',
                   '--config', 'p/secrets', '--config', 'p/security-audit', '--metrics=off', '--json',
                   '--output', '/tmp/semgrep.json', '--quiet', '/src') `
        -Inputs @{ (Join-Path (Get-SourceExport) '.') = '/src' } -Outputs @{ '/tmp/semgrep.json' = (Join-Path $reports 'semgrep.json') } | Out-Null
    $data = Get-Content -Raw (Join-Path $reports 'semgrep.json') | ConvertFrom-Json
    $scanned = @($data.paths.scanned | ForEach-Object { $_.Replace('/src/', '') })
    foreach ($must in 'app/app.py', 'Dockerfile') {
        if ($scanned -notcontains $must) { throw "TOOL ERROR: Semgrep did not scan $must ($($scanned.Count) files scanned); an empty scan is not a pass." }
    }
    Write-Host "Semgrep: $($scanned.Count) files scanned, $(@($data.results | Where-Object { $_ }).Count) finding(s), $(@($data.errors | Where-Object { $_ }).Count) scan error(s)"
    foreach ($r in $data.results) { Write-Host "  [$($r.extra.severity)] $($r.check_id.Split('.')[-1]) $($r.path.Replace('/src/', '')):$($r.start.line)" }
}

function Invoke-DependencyScan {
    $reports = Get-ReportsDir
    Invoke-ContainerTool -Tool 'pip-audit' -Image (Get-SecToolsImage) `
        -Command @('pip-audit', '-r', '/src/app/requirements.txt', '-r', '/src/requirements-dev.txt', '--format', 'json',
                   '--output', '/tmp/pip-audit.json', '--desc', 'on', '--progress-spinner', 'off') `
        -Inputs @{ (Join-Path (Get-SourceExport) '.') = '/src' } -Outputs @{ '/tmp/pip-audit.json' = (Join-Path $reports 'pip-audit.json') } | Out-Null
    $data = Get-Content -Raw (Join-Path $reports 'pip-audit.json') | ConvertFrom-Json
    Write-Host "pip-audit: $(@($data.dependencies).Count) packages resolved (direct + transitive)"
    foreach ($d in $data.dependencies) { foreach ($v in $d.vulns) { Write-Host "  $($d.name) $($d.version): $($v.id) fix: $($v.fix_versions -join ', ')" } }
}

function Invoke-TrivyConfig {
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][string]$SourcePath)
    $reports = Get-ReportsDir
    Invoke-ContainerTool -Tool $Tool -Image $script:ScannerImages.trivy `
        -RunArgs @('-v', "$($script:TrivyCacheVolume):/root/.cache/trivy") `
        -Command @('config', '--format', 'json', '--output', "/tmp/$Tool.json", '--quiet', '/scan') `
        -Inputs @{ $SourcePath = '/scan' } -Outputs @{ "/tmp/$Tool.json" = (Join-Path $reports "$Tool.json") } | Out-Null
    $data = Get-Content -Raw (Join-Path $reports "$Tool.json") | ConvertFrom-Json
    $mis = @($data.Results | ForEach-Object { $_.Misconfigurations } | Where-Object { $_ -and $_.Status -eq 'FAIL' })
    Write-Host "Trivy config ($Tool): $($mis.Count) failed check(s)"
    $mis | Group-Object Severity | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
    foreach ($m in $mis) { Write-Host "  [$($m.Severity)] $($m.ID) $($m.Title)" }
}

function Invoke-DockerfileScan {
    $dir = Join-Path $env:CI_TMP 'dockerfile-scan'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath (Join-Path (Get-SourceExport) 'Dockerfile') -Destination $dir
    Invoke-TrivyConfig -Tool 'trivy-dockerfile' -SourcePath (Join-Path $dir '.')
}

function Invoke-K8sManifestScan {
    Invoke-TrivyConfig -Tool 'trivy-k8s' -SourcePath (Join-Path (Get-SourceExport) 'k8s\.')
}

function Save-ImageArchive {
    $tar = Join-Path $env:CI_TMP 'image.tar'
    if (-not (Test-Path -LiteralPath $tar)) {
        Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('save', $env:IMAGE, '-o', $tar) -Quiet) "docker save of $env:IMAGE failed"
    }
    return $tar
}

function Invoke-ImageScan {
    $reports = Get-ReportsDir
    $tar = Save-ImageArchive
    Invoke-ContainerTool -Tool 'trivy-image' -Image $script:ScannerImages.trivy `
        -RunArgs @('-v', "$($script:TrivyCacheVolume):/root/.cache/trivy") `
        -Command @('image', '--input', '/tmp/image.tar', '--scanners', 'vuln,secret', '--format', 'json', '--output', '/tmp/trivy-image.json', '--quiet') `
        -Inputs @{ $tar = '/tmp/image.tar' } -Outputs @{ '/tmp/trivy-image.json' = (Join-Path $reports 'trivy-image.json') } | Out-Null
    $data = Get-Content -Raw (Join-Path $reports 'trivy-image.json') | ConvertFrom-Json
    $vulns = @($data.Results | ForEach-Object { $_.Vulnerabilities } | Where-Object { $_ })
    $unique = $vulns | Sort-Object VulnerabilityID, PkgName -Unique
    Write-Host "Trivy image scan of $env:IMAGE ($($data.Metadata.OS.Family) $($data.Metadata.OS.Name)): $(@($unique).Count) unique vulnerabilities"
    $unique | Group-Object Severity | Sort-Object Name | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
    $fixable = @($unique | Where-Object { $_.Severity -in 'CRITICAL', 'HIGH' -and $_.FixedVersion })
    Write-Host "  CRITICAL/HIGH with a fix available: $($fixable.Count)"
}

function New-ImageSbom {
    $reports = Get-ReportsDir
    $tar = Save-ImageArchive
    $sbomName = "sbom-$env:IMAGE_TAG.cdx.json"
    Invoke-ContainerTool -Tool 'sbom' -Image $script:ScannerImages.trivy `
        -RunArgs @('-v', "$($script:TrivyCacheVolume):/root/.cache/trivy") `
        -Command @('image', '--input', '/tmp/image.tar', '--format', 'cyclonedx', '--output', '/tmp/sbom.json', '--quiet') `
        -Inputs @{ $tar = '/tmp/image.tar' } -Outputs @{ '/tmp/sbom.json' = (Join-Path $reports $sbomName) } | Out-Null
    $sbom = Get-Content -Raw (Join-Path $reports $sbomName) | ConvertFrom-Json
    $imageId = ((Invoke-Native -FilePath 'docker' -ArgumentList @('image', 'inspect', '--format', '{{.Id}}', $env:IMAGE) -Quiet).Output -join '').Trim()
    $meta = [ordered]@{
        image = $env:IMAGE; image_id = $imageId; git_commit = $env:GIT_COMMIT_FULL; jenkins_job = $env:JOB_NAME
        jenkins_build = $env:BUILD_NUMBER; sbom_file = $sbomName; sbom_format = "CycloneDX $($sbom.specVersion)"
        components = @($sbom.components).Count; generated_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    Write-Utf8NoBomLf -Path (Join-Path $reports 'sbom-metadata.json') -Text (($meta | ConvertTo-Json) + "`n")
    $apps = @($sbom.components | Where-Object { $_.name -in 'flask', 'gunicorn', 'werkzeug', 'jinja2' } | ForEach-Object { "$($_.name) $($_.version)" })
    Write-Host "SBOM ${sbomName}: CycloneDX $($sbom.specVersion), $(@($sbom.components).Count) components; app dependencies: $($apps -join ', ')"
    Write-Host "Traceability: image $env:IMAGE ($imageId) <- commit $env:GIT_COMMIT_FULL <- Jenkins $env:JOB_NAME #$env:BUILD_NUMBER"
}

function Invoke-Dast {
    # OWASP ZAP against a DISPOSABLE container of the image under test on an
    # internal-only Docker network (no internet, never the live deployment).
    $reports = Get-ReportsDir
    $network = "healthcare-dast-$env:BUILD_NUMBER"
    $target = 'healthcare-dast-target'
    $targetName = "healthcare-dast-target-$env:BUILD_NUMBER"
    $zapVolume = "healthcare-zap-$env:BUILD_NUMBER"
    Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $targetName) -Quiet | Out-Null
    Invoke-Native -FilePath 'docker' -ArgumentList @('network', 'rm', $network) -Quiet | Out-Null
    Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('network', 'create', '--internal', $network) -Quiet) 'Creating the isolated DAST network failed'
    try {
        $run = Invoke-Native -FilePath 'docker' -ArgumentList @('run', '-d', '--name', $targetName, '--network', $network,
            '--network-alias', $target, '--read-only', '--tmpfs', '/tmp', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', $env:IMAGE) -Quiet
        Assert-Success $run 'Starting the disposable DAST target failed'
        $ready = $false
        for ($i = 1; $i -le 30 -and -not $ready; $i++) {
            $probe = Invoke-Native -FilePath 'docker' -ArgumentList @('exec', $targetName, 'python', '-c',
                "import urllib.request;urllib.request.urlopen('http://127.0.0.1:5000/health',timeout=2)") -Quiet
            $ready = ($probe.ExitCode -eq 0)
            if (-not $ready) { Start-Sleep -Seconds 1 }
        }
        if (-not $ready) { throw 'The DAST target did not become healthy within 30 seconds.' }
        Write-Host "DAST target $targetName ($env:IMAGE) is healthy on isolated network $network"

        # ZAP's packaged scripts only write reports into a *mounted* /zap/wrk.
        # A per-build named volume (no host path) satisfies that without
        # relaxing any Windows ACLs; ownership is handed to the zap user.
        Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('volume', 'create', $zapVolume) -Quiet) 'Creating the ZAP work volume failed'
        Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('run', '--rm', '--user', 'root', '--network', 'none', '-v', "${zapVolume}:/zap/wrk",
            '--entrypoint', 'chown', $script:ScannerImages.zap, 'zap:zap', '/zap/wrk') -Quiet) 'Preparing the ZAP work volume failed'
        $zapArgs = @('--network', $network, '-v', "${zapVolume}:/zap/wrk")
        Invoke-ContainerTool -Tool 'zap-baseline' -Image $script:ScannerImages.zap -RunArgs $zapArgs `
            -Command @('zap-baseline.py', '-t', "http://${target}:5000/", '-J', 'zap-baseline.json', '-r', 'zap-baseline.html', '-I', '-z', '-silent') `
            -Outputs @{ '/zap/wrk/zap-baseline.json' = (Join-Path $reports 'zap-baseline.json'); '/zap/wrk/zap-baseline.html' = (Join-Path $reports 'zap-baseline.html') } | Out-Null
        Invoke-ContainerTool -Tool 'zap-api' -Image $script:ScannerImages.zap -RunArgs $zapArgs `
            -Command @('zap-api-scan.py', '-t', '/zap/wrk/openapi.yaml', '-f', 'openapi', '-J', 'zap-api.json', '-r', 'zap-api.html', '-I', '-z', '-silent') `
            -Inputs @{ (Join-Path (Get-SourceExport) 'ci\security\openapi.yaml') = '/zap/wrk/openapi.yaml' } `
            -Outputs @{ '/zap/wrk/zap-api.json' = (Join-Path $reports 'zap-api.json'); '/zap/wrk/zap-api.html' = (Join-Path $reports 'zap-api.html') } | Out-Null
        foreach ($f in 'zap-baseline.json', 'zap-api.json') {
            $alerts = @((Get-Content -Raw (Join-Path $reports $f) | ConvertFrom-Json).site | ForEach-Object { $_.alerts } | Where-Object { $_ })
            Write-Host "$f : $($alerts.Count) alert type(s)"
            foreach ($a in $alerts) { Write-Host "  [$($a.riskdesc)] $($a.pluginid) $($a.alert) x$($a.count)" }
        }
    } finally {
        Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $targetName) -Quiet | Out-Null
        Invoke-Native -FilePath 'docker' -ArgumentList @('network', 'rm', $network) -Quiet | Out-Null
        Invoke-Native -FilePath 'docker' -ArgumentList @('volume', 'rm', '-f', $zapVolume) -Quiet | Out-Null
    }
}

function Invoke-SecurityPolicy {
    $reports = Get-ReportsDir
    $meta = [ordered]@{ image = $env:IMAGE; commit = $env:GIT_COMMIT_FULL; build = "$env:JOB_NAME #$env:BUILD_NUMBER" }
    Write-Utf8NoBomLf -Path (Join-Path $reports 'build-metadata.json') -Text (($meta | ConvertTo-Json) + "`n")
    $name = "sec-policy-$env:BUILD_NUMBER"
    Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $name) -Quiet | Out-Null
    Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('create', '--name', $name, '--network', 'none', (Get-SecToolsImage),
        'python', '/src/ci/security/evaluate_policy.py', '/tmp/reports', '/src/ci/security/security-policy.yaml', '/tmp/reports/build-metadata.json', '/tmp/gate') -Quiet) 'Creating the policy container failed'
    try {
        Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('cp', (Join-Path (Get-SourceExport) '.'), "${name}:/src") -Quiet) 'Copying sources into the policy container failed'
        Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('cp', (Join-Path $reports '.'), "${name}:/tmp/reports") -Quiet) 'Copying reports into the policy container failed'
        $eval = Invoke-Native -FilePath 'docker' -ArgumentList @('start', '-a', $name)
        foreach ($f in 'security-summary.json', 'security-report.md') {
            Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('cp', "${name}:/tmp/gate/$f", (Join-Path $reports $f)) -Quiet) "Policy evaluation did not produce $f"
        }
    } finally {
        Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $name) -Quiet | Out-Null
    }
    switch ($eval.ExitCode) {
        0 { Write-Host 'SECURITY GATE: PASS - the release policy is satisfied.' }
        1 { throw 'SECURITY GATE: FAIL - blocking findings violate the release policy (see security-report.md for each finding and its fix).' }
        2 { throw 'SECURITY GATE: TOOL-ERROR - at least one scanner failed or produced no valid report; the result cannot be trusted.' }
        default { throw "SECURITY GATE: policy evaluator crashed (exit code $($eval.ExitCode))." }
    }
}

function Test-ReportsForSecrets {
    # Archived artifacts must never contain secret material.
    $patterns = @('-----BEGIN [A-Z ]*PRIVATE KEY-----', 'dckr_pat_[A-Za-z0-9_-]{10,}', 'AKIA[0-9A-Z]{16}', 'ghp_[A-Za-z0-9]{30,}')
    $hits = @(Get-ChildItem -LiteralPath (Get-ReportsDir) -File -Recurse | Select-String -Pattern $patterns)
    if ($hits.Count -gt 0) {
        throw "Report artifacts contain secret-like values in: $(($hits | ForEach-Object { $_.Filename } | Sort-Object -Unique) -join ', '). Not archiving."
    }
    Write-Host "Artifact secret check passed: no secret-like values in $(@(Get-ChildItem -LiteralPath (Get-ReportsDir) -File).Count) report files."
}
