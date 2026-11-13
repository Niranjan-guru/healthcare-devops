# Reusable pipeline stage implementations shared by the three Jenkins jobs:
#   Healthcare-CI-CD (Activity 7), Healthcare-Blue-Green (Activity 8) and
#   Healthcare-DevSecOps (Activity 9).
#
# Dot-source from a Jenkins `powershell` step:   . "$env:WORKSPACE/ci/stages.ps1"
# Each function throws on failure, which fails the Jenkins step.

. (Join-Path $PSScriptRoot 'lib.ps1')

function Initialize-Build {
    # Verifies that the checked-out commit is the latest origin/main and
    # creates a private (SYSTEM-only) temporary directory for this build.
    Write-Section 'Commit verification'
    $remote = Invoke-Native -FilePath 'git' -ArgumentList @('ls-remote', 'origin', 'refs/heads/main') -Quiet
    Assert-Success $remote 'git ls-remote origin failed'
    $line = $remote.Output | Where-Object { $_ -match '^[0-9a-f]{40}\s+refs/heads/main$' } | Select-Object -First 1
    if (-not $line) { throw 'Could not determine the latest origin/main commit.' }
    $latest = ($line -split '\s+')[0]
    Write-Host "Checked out commit : $env:GIT_COMMIT_FULL"
    Write-Host "Latest origin/main : $latest"
    if ($latest -ne $env:GIT_COMMIT_FULL) { throw 'The checked-out commit is not the latest commit on origin/main.' }
    Write-Host "Image to build     : $env:IMAGE"

    Write-Section 'Private temporary directory'
    if (Test-Path -LiteralPath $env:CI_TMP) { Remove-Item -LiteralPath $env:CI_TMP -Recurse -Force }
    New-Item -ItemType Directory -Path $env:CI_TMP | Out-Null
    Protect-PrivatePath -Path $env:CI_TMP -Directory
}

function Test-SourceTree {
    $required = @(
        'app/app.py', 'app/requirements.txt', 'requirements-dev.txt', 'pytest.ini',
        'tests/test_app.py', 'tests/test_manifests.py', 'Dockerfile', '.dockerignore',
        'k8s/namespace.yaml', 'k8s/deployment.yaml', 'k8s/service.yaml',
        'k8s/blue-green/deployment-blue.yaml', 'k8s/blue-green/deployment-green.yaml',
        'k8s/blue-green/service.yaml', 'k8s/blue-green/service-preview.yaml',
        'ci/lib.ps1', 'ci/stages.ps1', 'ci/remote/k8s-lib.sh', 'ci/remote/verify-host.sh',
        'ci/remote/deploy.sh', 'ci/remote/bluegreen.sh', 'ci/remote/ns-lock.sh', 'ci/remote/smoke-test.sh'
    )
    foreach ($file in $required) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required file missing: $file" }
    }
    Write-Host "All $($required.Count) required files present."
    # (Files sent to the EC2 host are normalised to LF by New-DeploymentBundle.)

    # Secret hygiene: no key material or kubeconfigs tracked in Git.
    $tracked = Invoke-Native -FilePath 'git' -ArgumentList @('ls-files') -Quiet
    Assert-Success $tracked 'git ls-files failed'
    $bad = @($tracked.Output | Where-Object { $_ -match '\.(pem|key|ppk)$|(^|/)kubeconfig$|(^|/)id_(rsa|ed25519)' })
    if ($bad.Count -gt 0) { throw "Secret-like files are tracked in Git: $($bad -join ', ')" }
    $grep = Invoke-Native -FilePath 'git' -ArgumentList @('grep', '-l', '-E', '-e', '-----BEGIN [A-Z ]*PRIVATE KEY-----') -Quiet
    if ($grep.ExitCode -eq 0) { throw "Private key material found in tracked files: $($grep.Output -join ', ')" }
    if ($grep.ExitCode -ne 1) { throw "git grep failed (exit code $($grep.ExitCode))." }
    Write-Host 'No private keys or kubeconfig files are tracked.'
}

function Invoke-ApplicationTests {
    param([string]$JUnitPath)
    Write-Section "Building test image $env:TEST_IMAGE"
    $build = Invoke-Native -FilePath 'docker' -ArgumentList @('build', '--progress=plain', '--target', 'test', '-t', $env:TEST_IMAGE, '.')
    Assert-Success $build 'Building the test image failed'

    Write-Section 'Running unit and manifest tests'
    $name = "healthcare-test-$env:BUILD_NUMBER"
    $runArgs = @('run', '--network', 'none', '--name', $name, $env:TEST_IMAGE)
    if ($JUnitPath) { $runArgs += @('python', '-m', 'pytest', '-v', '-p', 'no:cacheprovider', '--junitxml=/tmp/junit.xml') }
    $tests = Invoke-Native -FilePath 'docker' -ArgumentList $runArgs
    try {
        if ($JUnitPath) {
            $copy = Invoke-Native -FilePath 'docker' -ArgumentList @('cp', "${name}:/tmp/junit.xml", $JUnitPath) -Quiet
            Assert-Success $copy 'Copying the JUnit report out of the test container failed'
        }
    } finally {
        Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $name) -Quiet | Out-Null
    }
    Assert-Success $tests 'Application tests FAILED'
    if (-not ($tests.Output | Where-Object { $_ -match '\d+ passed' })) { throw 'pytest did not report any passed tests.' }
}

function Build-RuntimeImage {
    $build = Invoke-Native -FilePath 'docker' -ArgumentList @(
        'build', '--progress=plain', '--target', 'runtime',
        '--build-arg', "APP_VERSION=$env:IMAGE_TAG",
        '--label', "org.opencontainers.image.revision=$env:GIT_COMMIT_FULL",
        '--label', "org.opencontainers.image.version=$env:IMAGE_TAG",
        '--label', 'org.opencontainers.image.source=https://github.com/Niranjan-guru/healthcare-devops',
        '-t', $env:IMAGE, '.')
    Assert-Success $build "Building $env:IMAGE failed"
    Write-Host "Built $env:IMAGE"
}

function Test-RuntimeImage {
    $inspect = Invoke-Native -FilePath 'docker' -ArgumentList @('image', 'inspect', $env:IMAGE) -Quiet
    Assert-Success $inspect 'docker image inspect failed'
    $config = (($inspect.Output -join "`n") | ConvertFrom-Json)[0].Config
    if ($config.User -ne '10001') { throw "Image user is '$($config.User)', expected 10001 (non-root)." }
    if (-not ($config.ExposedPorts.PSObject.Properties.Name -contains '5000/tcp')) { throw 'Image does not expose 5000/tcp.' }
    if (-not $config.Healthcheck -or -not $config.Healthcheck.Test) { throw 'Image has no HEALTHCHECK.' }
    if ($config.Env -notcontains "APP_VERSION=$env:IMAGE_TAG") { throw 'APP_VERSION is not baked into the image.' }
    Write-Host 'Image metadata OK: user 10001, port 5000/tcp, HEALTHCHECK present, APP_VERSION set.'

    $name = "healthcare-validate-$env:BUILD_NUMBER"
    $run = Invoke-Native -FilePath 'docker' -ArgumentList @('run', '-d', '--name', $name, '-p', '127.0.0.1::5000', $env:IMAGE) -Quiet
    Assert-Success $run 'Could not start the image'
    try {
        $port = Invoke-Native -FilePath 'docker' -ArgumentList @('port', $name, '5000/tcp') -Quiet
        Assert-Success $port 'Could not determine the published port'
        $hostPort = (($port.Output | Select-Object -First 1) -split ':')[-1].Trim()
        $base = "http://127.0.0.1:$hostPort"

        $healthy = $false
        for ($i = 1; $i -le 30 -and -not $healthy; $i++) {
            try {
                $r = Invoke-WebRequest -UseBasicParsing -Uri "$base/health" -TimeoutSec 3
                $healthy = ($r.StatusCode -eq 200)
            } catch { Start-Sleep -Seconds 1 }
        }
        if (-not $healthy) { throw '/health did not return HTTP 200 within 30 seconds.' }
        Write-Host '/health -> 200'

        $version = (Invoke-RestMethod -Uri "$base/version" -TimeoutSec 5).version
        if ($version -ne $env:IMAGE_TAG) { throw "/version returned '$version', expected '$env:IMAGE_TAG'." }
        Write-Host "/version -> $version"

        $uid = Invoke-Native -FilePath 'docker' -ArgumentList @('exec', $name, 'id', '-u') -Quiet
        Assert-Success $uid 'docker exec id -u failed'
        if (($uid.Output -join '').Trim() -ne '10001') { throw "Container runs as UID $($uid.Output), expected 10001." }
        Write-Host 'Container process runs as UID 10001.'

        $status = ''
        for ($i = 1; $i -le 30 -and $status -ne 'healthy'; $i++) {
            $h = Invoke-Native -FilePath 'docker' -ArgumentList @('inspect', '--format', '{{.State.Health.Status}}', $name) -Quiet
            $status = ($h.Output -join '').Trim()
            if ($status -eq 'unhealthy') { break }
            if ($status -ne 'healthy') { Start-Sleep -Seconds 2 }
        }
        if ($status -ne 'healthy') { throw "Docker HEALTHCHECK status is '$status', expected 'healthy'." }
        Write-Host 'Docker HEALTHCHECK reports healthy.'
    } catch {
        Write-Host '--- container logs ---'
        Invoke-Native -FilePath 'docker' -ArgumentList @('logs', '--tail', '50', $name) | Out-Null
        throw
    } finally {
        Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $name) -Quiet | Out-Null
    }
}

function Connect-DockerHub {
    # Requires DOCKERHUB_USR / DOCKERHUB_PSW (Jenkins credential binding) and an
    # isolated DOCKER_CONFIG directory.
    New-Item -ItemType Directory -Force -Path $env:DOCKER_CONFIG | Out-Null
    Protect-PrivatePath -Path $env:DOCKER_CONFIG -Directory
    $user = $env:DOCKERHUB_USR.Trim()
    if ($user -cne 'niranjanbalaguru') { throw "Credential 'dockerhub-creds' does not hold the expected Docker Hub username." }
    $token = Get-DockerHubToken -ShowDiagnostics
    $login = Invoke-Native -FilePath 'docker' -ArgumentList @('login', '--username', $user, '--password-stdin') -InputText $token
    Remove-Variable token
    Assert-Success $login "Docker Hub authentication failed - check that credential 'dockerhub-creds' holds a valid Read/Write access token"
    if (-not (Test-Path -LiteralPath (Join-Path $env:DOCKER_CONFIG 'config.json'))) { throw 'docker login did not use the isolated DOCKER_CONFIG.' }
    Write-Host 'Authenticated to Docker Hub using an isolated, temporary Docker config.'
}

function Publish-Image {
    $push = Invoke-Native -FilePath 'docker' -ArgumentList @('push', $env:IMAGE)
    Assert-Success $push "Pushing $env:IMAGE failed"
    $digest = $null
    foreach ($line in $push.Output) { if ($line -match 'digest:\s+(sha256:[0-9a-f]{64})') { $digest = $Matches[1] } }
    if (-not $digest) { throw 'Could not read the pushed image digest from docker push output.' }
    Write-Utf8NoBomLf -Path (Join-Path $env:CI_TMP 'pushed-digest.txt') -Text $digest
    Write-Host "Pushed $env:IMAGE ($digest)"
}

function Confirm-PublishedImage {
    # Verifies through the Docker Hub registry API that the immutable tag
    # resolves to the digest that was pushed. Optionally moves 'latest'.
    param([switch]$TagLatest)
    $expected = [IO.File]::ReadAllText((Join-Path $env:CI_TMP 'pushed-digest.txt')).Trim()
    $remote = Get-DockerHubDigest -Repository $env:IMAGE_REPO -Tag $env:IMAGE_TAG
    Write-Host "Docker Hub $($env:IMAGE): $remote"
    if ($remote -ne $expected) { throw "Docker Hub digest $remote does not match pushed digest $expected." }

    if ($TagLatest) {
        $latest = "$($env:IMAGE_REPO):latest"
        Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('tag', $env:IMAGE, $latest)) 'docker tag latest failed'
        Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('push', $latest)) 'Pushing latest failed'
        $remoteLatest = Get-DockerHubDigest -Repository $env:IMAGE_REPO -Tag 'latest'
        if ($remoteLatest -ne $expected) { throw "Docker Hub 'latest' digest $remoteLatest does not match $expected." }
        Write-Host "Verified: $env:IMAGE and latest resolve to $expected on Docker Hub."
    } else {
        Write-Host "Verified: $env:IMAGE resolves to $expected on Docker Hub."
    }
    $env:IMAGE_DIGEST = $expected
}

function Disconnect-DockerHub {
    $logout = Invoke-Native -FilePath 'docker' -ArgumentList @('logout') -Quiet
    Assert-Success $logout 'docker logout failed'
    Remove-Item -LiteralPath $env:DOCKER_CONFIG -Recurse -Force
    Write-Host 'Logged out and removed the temporary Docker config.'
}

function Confirm-Ec2Connection {
    # Secure the key, pin the host key, prove SSH authentication and confirm
    # that the host really is the intended EC2 instance.
    param([Parameter(Mandatory)][string]$BundleDir)
    $who = [Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Host "Jenkins agent account: $($who.Name) [$($who.User.Value)]"

    Write-Section 'Securing the temporary private key file'
    Protect-PrivatePath -Path $env:EC2_SSH
    $icacls = Invoke-Native -FilePath 'icacls.exe' -ArgumentList @($env:EC2_SSH) -Quiet
    Assert-Success $icacls 'icacls could not read the key ACL'
    $icacls.Output | ForEach-Object { Write-Host "  icacls: $_" }
    $fp = Invoke-Native -FilePath 'ssh-keygen.exe' -ArgumentList @('-l', '-E', 'sha256', '-f', $env:EC2_SSH) -Quiet
    Assert-Success $fp 'OpenSSH could not load the private key (format or permissions)'
    Write-Host "Key accepted by ssh-keygen: $((($fp.Output -join ' ') -split '\s+' | Where-Object { $_ -like 'SHA256:*' }) | Select-Object -First 1)"

    Write-Section 'Verifying EC2 host key'
    Initialize-Ec2KnownHosts

    Write-Section 'Testing SSH authentication'
    $probe = Invoke-Ssh -RemoteCommand 'echo ssh-auth-ok'
    if ($probe.ExitCode -ne 0 -or -not ($probe.Output -contains 'ssh-auth-ok')) {
        throw "SSH authentication to $(Get-SshTarget) failed (exit code $($probe.ExitCode))."
    }
    Write-Host "SSH authentication to $(Get-SshTarget) succeeded."

    Write-Section 'Confirming EC2 instance identity'
    $verify = Invoke-RemoteBundle -LocalDir $BundleDir -Files @('verify-host.sh') `
        -EntryScript 'verify-host.sh' -ScriptArguments @($env:EC2_INSTANCE_ID, $env:EC2_PRIVATE_IP)
    Assert-Success $verify 'EC2 instance identity verification failed'
}

function Invoke-BuildCleanup {
    # post { always }: remove containers, build-specific local tags, the
    # private temp directory and confirm no credential files remain.
    param([string[]]$ExtraImages = @())
    $problems = @()
    foreach ($name in @("healthcare-validate-$env:BUILD_NUMBER", "healthcare-test-$env:BUILD_NUMBER")) {
        $found = Invoke-Native -FilePath 'docker' -ArgumentList @('ps', '-a', '-q', '--filter', "name=^$name$") -Quiet
        if ($found.Output -join '') {
            $rm = Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $name) -Quiet
            if ($rm.ExitCode -ne 0) { $problems += "could not remove container $name" }
        }
    }
    foreach ($image in (@($env:TEST_IMAGE, $env:IMAGE) + $ExtraImages)) {
        if (-not $image) { continue }
        $exists = Invoke-Native -FilePath 'docker' -ArgumentList @('image', 'inspect', $image) -Quiet
        if ($exists.ExitCode -eq 0) {
            $rmi = Invoke-Native -FilePath 'docker' -ArgumentList @('image', 'rm', $image) -Quiet
            if ($rmi.ExitCode -ne 0) { $problems += "could not remove local image tag $image" }
        }
    }
    if ($env:CI_TMP -and (Test-Path -LiteralPath $env:CI_TMP)) {
        Remove-Item -LiteralPath $env:CI_TMP -Recurse -Force -ErrorAction Continue
        if (Test-Path -LiteralPath $env:CI_TMP) { $problems += "temporary directory $env:CI_TMP still exists" }
    }
    $secretFiles = "$env:WORKSPACE@tmp/secretFiles"
    if (Test-Path -LiteralPath $secretFiles) {
        $left = @(Get-ChildItem -LiteralPath $secretFiles -Recurse -File -Force)
        if ($left.Count -gt 0) { $problems += "$($left.Count) credential file(s) remain under secretFiles" }
    }
    if ($problems.Count -gt 0) { throw "Cleanup problems: $($problems -join '; ')" }
    Write-Host 'Cleanup complete: no temporary credentials, containers or build-specific files left behind.'
}
