// Healthcare DevOps CI/CD pipeline (academic demonstration project).
//
// Agent: Windows Jenkins controller (service account LocalSystem) with
// Docker Desktop and Windows OpenSSH. Target: K3s on an EC2 instance,
// driven remotely over SSH with `sudo kubectl` (the K3s API port is never
// exposed and no kubeconfig leaves the EC2 host).
//
// Helper logic lives in ci/lib.ps1 (Windows side) and ci/remote/*.sh (EC2
// side) so that it can be reviewed and tested outside Jenkins.
//
// Note: PowerShell blocks use forward slashes in paths because Groovy
// treats backslashes inside ''' strings as escape characters.

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '25'))
    }

    environment {
        IMAGE_REPO      = 'niranjanbalaguru/healthcare-app'
        // Deployment target. The pipeline refuses to deploy unless the host
        // presents this SSH host key AND reports this instance ID/private IP.
        EC2_HOST        = '184.73.3.54'
        EC2_INSTANCE_ID = 'i-00f631df0f5cf81d8'
        EC2_PRIVATE_IP  = '172.31.25.50'
        EC2_HOSTKEY_FP  = 'SHA256:B4W0XuwdBWHb4H78QudSeZPiNrVAm79DNNkZPggq0RU'
    }

    stages {

        stage('Checkout') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                script {
                    def scmVars = checkout scm
                    def commit = scmVars.GIT_COMMIT
                    if (!(commit ==~ /[0-9a-f]{40}/)) {
                        error("Checkout did not return a valid commit SHA: ${commit}")
                    }
                    env.GIT_COMMIT_FULL  = commit
                    env.GIT_COMMIT_SHORT = commit.substring(0, 7)
                    // Unique, traceable tag: <build-number>-<short-sha>
                    env.IMAGE_TAG  = "${env.BUILD_NUMBER}-${env.GIT_COMMIT_SHORT}"
                    env.IMAGE      = "${env.IMAGE_REPO}:${env.IMAGE_TAG}"
                    env.TEST_IMAGE = "healthcare-app-test:${env.IMAGE_TAG}"
                    env.CI_TMP     = "${env.WORKSPACE}@tmp\\ci-${env.BUILD_NUMBER}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.GIT_COMMIT_SHORT}"
                }
                powershell label: 'Verify commit and prepare private temp dir', script: '''
                    . "$env:WORKSPACE/ci/lib.ps1"
                    Write-Section 'Commit verification'
                    $remote = Invoke-Native -FilePath 'git' -ArgumentList @('ls-remote', 'origin', 'refs/heads/main') -Quiet
                    Assert-Success $remote 'git ls-remote origin failed'
                    $line = $remote.Output | Where-Object { $_ -match '^[0-9a-f]{40}\\s+refs/heads/main$' } | Select-Object -First 1
                    if (-not $line) { throw 'Could not determine the latest origin/main commit.' }
                    $latest = ($line -split '\\s+')[0]
                    Write-Host "Checked out commit : $env:GIT_COMMIT_FULL"
                    Write-Host "Latest origin/main : $latest"
                    if ($latest -ne $env:GIT_COMMIT_FULL) {
                        throw 'The checked-out commit is not the latest commit on origin/main.'
                    }
                    Write-Host "Image to build     : $env:IMAGE"

                    Write-Section 'Private temporary directory'
                    if (Test-Path -LiteralPath $env:CI_TMP) { Remove-Item -LiteralPath $env:CI_TMP -Recurse -Force }
                    New-Item -ItemType Directory -Path $env:CI_TMP | Out-Null
                    Protect-PrivatePath -Path $env:CI_TMP -Directory
                '''
            }
        }

        stage('Validate Source') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                powershell label: 'Validate repository contents', script: '''
                    . "$env:WORKSPACE/ci/lib.ps1"
                    $required = @(
                        'app/app.py', 'app/requirements.txt', 'requirements-dev.txt', 'pytest.ini',
                        'tests/test_app.py', 'tests/test_manifests.py', 'Dockerfile', '.dockerignore',
                        'k8s/namespace.yaml', 'k8s/deployment.yaml', 'k8s/service.yaml',
                        'ci/lib.ps1', 'ci/remote/verify-host.sh', 'ci/remote/deploy.sh', 'ci/remote/smoke-test.sh'
                    )
                    foreach ($file in $required) {
                        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required file missing: $file" }
                    }
                    Write-Host "All $($required.Count) required files present."

                    # Files consumed on Linux must not contain CR characters.
                    foreach ($file in @('ci/remote/verify-host.sh', 'ci/remote/deploy.sh', 'ci/remote/smoke-test.sh',
                                        'k8s/namespace.yaml', 'k8s/deployment.yaml', 'k8s/service.yaml')) {
                        if ([IO.File]::ReadAllText((Resolve-Path $file)).Contains("`r")) { throw "$file has CRLF line endings." }
                    }
                    Write-Host 'Linux-side files use LF line endings.'

                    # Secret hygiene: no key material or kubeconfigs tracked in Git.
                    $tracked = Invoke-Native -FilePath 'git' -ArgumentList @('ls-files') -Quiet
                    Assert-Success $tracked 'git ls-files failed'
                    $bad = @($tracked.Output | Where-Object { $_ -match '\\.(pem|key|ppk)$|(^|/)kubeconfig$|(^|/)id_(rsa|ed25519)' })
                    if ($bad.Count -gt 0) { throw "Secret-like files are tracked in Git: $($bad -join ', ')" }
                    $grep = Invoke-Native -FilePath 'git' -ArgumentList @('grep', '-l', '-E', '-e', '-----BEGIN [A-Z ]*PRIVATE KEY-----') -Quiet
                    if ($grep.ExitCode -eq 0) { throw "Private key material found in tracked files: $($grep.Output -join ', ')" }
                    if ($grep.ExitCode -ne 1) { throw "git grep failed (exit code $($grep.ExitCode))." }
                    Write-Host 'No private keys or kubeconfig files are tracked.'
                '''
            }
        }

        stage('Run Application Tests') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Build test image and run pytest', script: '''
                    . "$env:WORKSPACE/ci/lib.ps1"
                    Write-Section "Building test image $env:TEST_IMAGE"
                    $build = Invoke-Native -FilePath 'docker' -ArgumentList @('build', '--progress=plain', '--target', 'test', '-t', $env:TEST_IMAGE, '.')
                    Assert-Success $build 'Building the test image failed'

                    Write-Section 'Running unit and manifest tests'
                    $tests = Invoke-Native -FilePath 'docker' -ArgumentList @('run', '--rm', '--network', 'none', '--name', "healthcare-test-$env:BUILD_NUMBER", $env:TEST_IMAGE)
                    Assert-Success $tests 'Application tests FAILED'
                    if (-not ($tests.Output | Where-Object { $_ -match '\\d+ passed' })) { throw 'pytest did not report any passed tests.' }
                '''
            }
        }

        stage('Build Docker Image') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Build runtime image', script: '''
                    . "$env:WORKSPACE/ci/lib.ps1"
                    $build = Invoke-Native -FilePath 'docker' -ArgumentList @(
                        'build', '--progress=plain', '--target', 'runtime',
                        '--build-arg', "APP_VERSION=$env:IMAGE_TAG",
                        '--label', "org.opencontainers.image.revision=$env:GIT_COMMIT_FULL",
                        '--label', "org.opencontainers.image.version=$env:IMAGE_TAG",
                        '--label', 'org.opencontainers.image.source=https://github.com/Niranjan-guru/healthcare-devops',
                        '-t', $env:IMAGE, '.')
                    Assert-Success $build "Building $env:IMAGE failed"
                    Write-Host "Built $env:IMAGE"
                '''
            }
        }

        stage('Validate Docker Image') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                powershell label: 'Inspect and run the image', script: '''
                    . "$env:WORKSPACE/ci/lib.ps1"
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
                '''
            }
        }

        stage('Publish to Docker Hub') {
            environment {
                DOCKERHUB     = credentials('dockerhub-creds')      // DOCKERHUB_USR / DOCKERHUB_PSW (masked)
                DOCKER_CONFIG = "${env.CI_TMP}\\docker-config"      // isolated, ACL-restricted, deleted in post
            }
            stages {
                stage('Authenticate with Docker Hub') {
                    options { timeout(time: 3, unit: 'MINUTES') }
                    steps {
                        powershell label: 'docker login (isolated config)', script: '''
                            . "$env:WORKSPACE/ci/lib.ps1"
                            New-Item -ItemType Directory -Force -Path $env:DOCKER_CONFIG | Out-Null
                            Protect-PrivatePath -Path $env:DOCKER_CONFIG -Directory
                            if ($env:DOCKERHUB_USR -cne 'niranjanbalaguru') { throw "Credential 'dockerhub-creds' does not hold the expected Docker Hub username." }
                            $login = Invoke-Native -FilePath 'docker' -ArgumentList @('login', '--username', $env:DOCKERHUB_USR, '--password-stdin') -InputText $env:DOCKERHUB_PSW
                            Assert-Success $login "Docker Hub authentication failed - check that credential 'dockerhub-creds' holds a valid Read/Write access token"
                            if (-not (Test-Path -LiteralPath (Join-Path $env:DOCKER_CONFIG 'config.json'))) { throw 'docker login did not use the isolated DOCKER_CONFIG.' }
                            Write-Host 'Authenticated to Docker Hub using an isolated, temporary Docker config.'
                        '''
                    }
                }
                stage('Push Docker Image') {
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'docker push', script: '''
                            . "$env:WORKSPACE/ci/lib.ps1"
                            $push = Invoke-Native -FilePath 'docker' -ArgumentList @('push', $env:IMAGE)
                            Assert-Success $push "Pushing $env:IMAGE failed"
                            $digest = $null
                            foreach ($line in $push.Output) { if ($line -match 'digest:\\s+(sha256:[0-9a-f]{64})') { $digest = $Matches[1] } }
                            if (-not $digest) { throw 'Could not read the pushed image digest from docker push output.' }
                            Write-Utf8NoBomLf -Path (Join-Path $env:CI_TMP 'pushed-digest.txt') -Text $digest
                            Write-Host "Pushed $env:IMAGE ($digest)"
                        '''
                    }
                }
                stage('Verify Published Image') {
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Verify registry digest, then publish latest', script: '''
                            . "$env:WORKSPACE/ci/lib.ps1"
                            $expected = [IO.File]::ReadAllText((Join-Path $env:CI_TMP 'pushed-digest.txt')).Trim()
                            $remote = Get-DockerHubDigest -Repository $env:IMAGE_REPO -Tag $env:IMAGE_TAG
                            Write-Host "Docker Hub $($env:IMAGE): $remote"
                            if ($remote -ne $expected) { throw "Docker Hub digest $remote does not match pushed digest $expected." }

                            # Only after the versioned tag is verified, move 'latest' to it.
                            $latest = "$($env:IMAGE_REPO):latest"
                            Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('tag', $env:IMAGE, $latest)) 'docker tag latest failed'
                            Assert-Success (Invoke-Native -FilePath 'docker' -ArgumentList @('push', $latest)) 'Pushing latest failed'
                            $remoteLatest = Get-DockerHubDigest -Repository $env:IMAGE_REPO -Tag 'latest'
                            if ($remoteLatest -ne $expected) { throw "Docker Hub 'latest' digest $remoteLatest does not match $expected." }
                            Write-Host "Verified: $env:IMAGE and latest resolve to $expected on Docker Hub."

                            $logout = Invoke-Native -FilePath 'docker' -ArgumentList @('logout') -Quiet
                            Assert-Success $logout 'docker logout failed'
                            Remove-Item -LiteralPath $env:DOCKER_CONFIG -Recurse -Force
                            Write-Host 'Logged out and removed the temporary Docker config.'
                        '''
                    }
                }
            }
        }

        stage('Deploy to EC2 K3s') {
            environment {
                // EC2_SSH = temp key file path, EC2_SSH_USR = ec2-user (Jenkins removes the file afterwards)
                EC2_SSH = credentials('aws-ec2-ssh')
            }
            stages {
                stage('Verify EC2 SSH Connectivity') {
                    options { timeout(time: 3, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Secure key, pin host key, authenticate, verify instance', script: '''
                            . "$env:WORKSPACE/ci/lib.ps1"
                            $who = [Security.Principal.WindowsIdentity]::GetCurrent()
                            Write-Host "Jenkins agent account: $($who.Name) [$($who.User.Value)]"

                            Write-Section 'Securing the temporary private key file'
                            Protect-PrivatePath -Path $env:EC2_SSH
                            $icacls = Invoke-Native -FilePath 'icacls.exe' -ArgumentList @($env:EC2_SSH) -Quiet
                            Assert-Success $icacls 'icacls could not read the key ACL'
                            $icacls.Output | ForEach-Object { Write-Host "  icacls: $_" }
                            $fp = Invoke-Native -FilePath 'ssh-keygen.exe' -ArgumentList @('-l', '-E', 'sha256', '-f', $env:EC2_SSH) -Quiet
                            Assert-Success $fp 'OpenSSH could not load the private key (format or permissions)'
                            Write-Host "Key accepted by ssh-keygen: $((($fp.Output -join ' ') -split '\\s+' | Where-Object { $_ -like 'SHA256:*' }) | Select-Object -First 1)"

                            Write-Section 'Verifying EC2 host key'
                            Initialize-Ec2KnownHosts

                            Write-Section 'Testing SSH authentication'
                            $probe = Invoke-Ssh -RemoteCommand 'echo ssh-auth-ok'
                            if ($probe.ExitCode -ne 0 -or -not ($probe.Output -contains 'ssh-auth-ok')) {
                                throw "SSH authentication to $(Get-SshTarget) failed (exit code $($probe.ExitCode))."
                            }
                            Write-Host "SSH authentication to $(Get-SshTarget) succeeded."

                            Write-Section 'Confirming EC2 instance identity'
                            New-DeploymentBundle -Destination (Join-Path $env:CI_TMP 'bundle') -Image $env:IMAGE
                            $verify = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files @('verify-host.sh') `
                                -EntryScript 'verify-host.sh' -ScriptArguments @($env:EC2_INSTANCE_ID, $env:EC2_PRIVATE_IP)
                            Assert-Success $verify 'EC2 instance identity verification failed'
                        '''
                    }
                }
                stage('Deploy to Kubernetes') {
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Apply manifests with the exact build image', script: '''
                            . "$env:WORKSPACE/ci/lib.ps1"
                            Initialize-SshSession
                            $bundle = Join-Path $env:CI_TMP 'bundle'
                            $result = Invoke-RemoteBundle -LocalDir $bundle `
                                -Files @('deploy.sh', 'namespace.yaml', 'service.yaml', 'deployment.yaml') -EntryScript 'deploy.sh' `
                                -ScriptArguments @('apply', $env:IMAGE, $env:IMAGE_TAG, $env:BUILD_NUMBER, $env:GIT_COMMIT_SHORT)
                            Assert-Success $result 'Kubernetes deployment failed'
                        '''
                    }
                }
                stage('Verify Kubernetes Rollout') {
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Rollout, pods, probes, version, endpoints', script: '''
                            . "$env:WORKSPACE/ci/lib.ps1"
                            Initialize-SshSession
                            $bundle = Join-Path $env:CI_TMP 'bundle'
                            $result = Invoke-RemoteBundle -LocalDir $bundle `
                                -Files @('deploy.sh', 'namespace.yaml', 'service.yaml', 'deployment.yaml') -EntryScript 'deploy.sh' `
                                -ScriptArguments @('verify', $env:IMAGE, $env:IMAGE_TAG, $env:BUILD_NUMBER, $env:GIT_COMMIT_SHORT)
                            Assert-Success $result 'Kubernetes rollout verification failed'
                        '''
                    }
                }
                stage('Application Smoke Tests') {
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        powershell label: 'HTTP smoke tests via NodePort on the EC2 host', script: '''
                            . "$env:WORKSPACE/ci/lib.ps1"
                            Initialize-SshSession
                            $result = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files @('smoke-test.sh') `
                                -EntryScript 'smoke-test.sh' -ScriptArguments @($env:IMAGE_TAG, $env:BUILD_NUMBER)
                            Assert-Success $result 'Application smoke tests failed'
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            powershell label: 'Cleanup', script: '''
                if (-not (Test-Path -LiteralPath "$env:WORKSPACE/ci/lib.ps1")) {
                    Write-Host 'Checkout did not complete; nothing was created that needs cleanup.'
                    exit 0
                }
                . "$env:WORKSPACE/ci/lib.ps1"
                $problems = @()

                foreach ($name in @("healthcare-validate-$env:BUILD_NUMBER", "healthcare-test-$env:BUILD_NUMBER")) {
                    $found = Invoke-Native -FilePath 'docker' -ArgumentList @('ps', '-a', '-q', '--filter', "name=^$name$") -Quiet
                    if ($found.Output -join '') {
                        $rm = Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $name) -Quiet
                        if ($rm.ExitCode -ne 0) { $problems += "could not remove container $name" }
                    }
                }

                # Remove build-specific local tags; layers stay cached through ':latest'.
                foreach ($image in @($env:TEST_IMAGE, $env:IMAGE)) {
                    if (-not $image) { continue }
                    $exists = Invoke-Native -FilePath 'docker' -ArgumentList @('image', 'inspect', $image) -Quiet
                    if ($exists.ExitCode -eq 0) {
                        $rmi = Invoke-Native -FilePath 'docker' -ArgumentList @('image', 'rm', $image) -Quiet
                        if ($rmi.ExitCode -ne 0) { $problems += "could not remove local image tag $image" }
                    }
                }

                # Temporary Docker config (credentials), known_hosts and rendered bundle.
                if ($env:CI_TMP -and (Test-Path -LiteralPath $env:CI_TMP)) {
                    Remove-Item -LiteralPath $env:CI_TMP -Recurse -Force -ErrorAction Continue
                    if (Test-Path -LiteralPath $env:CI_TMP) { $problems += "temporary directory $env:CI_TMP still exists" }
                }

                # Jenkins removes credential files when their binding ends; confirm none remain.
                $secretFiles = "$env:WORKSPACE@tmp/secretFiles"
                if (Test-Path -LiteralPath $secretFiles) {
                    $left = @(Get-ChildItem -LiteralPath $secretFiles -Recurse -File -Force)
                    if ($left.Count -gt 0) { $problems += "$($left.Count) credential file(s) remain under secretFiles" }
                }

                if ($problems.Count -gt 0) { throw "Cleanup problems: $($problems -join '; ')" }
                Write-Host 'Cleanup complete: no temporary credentials, containers or build-specific files left behind.'
            '''
        }
        success {
            echo "SUCCESS: ${env.IMAGE} built, published, deployed to K3s and verified."
        }
        failure {
            echo 'FAILURE: see the first failed stage above for the diagnostic message.'
        }
    }
}
