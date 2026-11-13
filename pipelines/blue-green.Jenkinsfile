// Activity 8 - Automated Blue-Green deployment, job Healthcare-Blue-Green.
//
// Two Deployments (healthcare-blue, healthcare-green) run side by side in the
// `healthcare` namespace. The production Service `healthcare-service`
// selects app=healthcare,environment=<active>. A release:
//   1. builds and publishes an immutable image  bg-<build>-<commit>
//   2. discovers the active environment from the live Service selector
//   3. deploys the image to the INACTIVE environment
//   4. validates it through the internal preview Service (production untouched)
//   5. switches the production selector, verifies and monitors production
//   6. rolls back automatically if any post-switch check fails
// ACTION=rollback switches production back to the recorded previous
// environment (only if it still runs the recorded, previously verified image).
//
// Shares ci/stages.ps1, ci/lib.ps1 and ci/remote/*.sh with Activity 7.

pipeline {
    agent any

    parameters {
        choice(name: 'ACTION', choices: ['deploy', 'rollback'],
               description: 'deploy = build, test and release to the inactive environment, then switch traffic. rollback = switch production back to the previous environment.')
        string(name: 'REPLICAS', defaultValue: '2', trim: true,
               description: 'Replicas for the candidate environment (1-4). Capacity is checked before deploying.')
        string(name: 'MONITOR_SECONDS', defaultValue: '60', trim: true,
               description: 'Post-switch production monitoring window in seconds (10-600).')
        string(name: 'ROLLBACK_REASON', defaultValue: 'manual-rollback', trim: true,
               description: 'ACTION=rollback only: short reason token, e.g. manual-rollback (letters, digits, . _ -).')
        booleanParam(name: 'SIMULATE_FAILED_VALIDATION', defaultValue: false,
               description: 'NEGATIVE TEST: break the candidate readiness probe to prove a failed validation blocks promotion.')
        booleanParam(name: 'SIMULATE_POST_SWITCH_FAILURE', defaultValue: false,
               description: 'NEGATIVE TEST: make post-switch monitoring fail to prove automatic rollback.')
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    environment {
        IMAGE_REPO      = 'niranjanbalaguru/healthcare-app'
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
                    if (!(params.REPLICAS ==~ /[1-4]/)) { error("REPLICAS must be 1-4, got '${params.REPLICAS}'") }
                    if (!(params.MONITOR_SECONDS ==~ /[0-9]{2,3}/) || params.MONITOR_SECONDS.toInteger() < 10 || params.MONITOR_SECONDS.toInteger() > 600) {
                        error("MONITOR_SECONDS must be 10-600, got '${params.MONITOR_SECONDS}'")
                    }
                    if (!(params.ROLLBACK_REASON ==~ /[A-Za-z0-9._-]{1,60}/)) { error('ROLLBACK_REASON must match [A-Za-z0-9._-]{1,60}') }
                    def scmVars = checkout scm
                    def commit = scmVars.GIT_COMMIT
                    if (!(commit ==~ /[0-9a-f]{40}/)) { error("Checkout did not return a valid commit SHA: ${commit}") }
                    env.GIT_COMMIT_FULL  = commit
                    env.GIT_COMMIT_SHORT = commit.substring(0, 7)
                    // bg- prefix: each Jenkins job has its own build counter, so the
                    // prefix keeps tags from different pipelines from colliding.
                    env.IMAGE_TAG   = "bg-${env.BUILD_NUMBER}-${env.GIT_COMMIT_SHORT}"
                    env.IMAGE       = "${env.IMAGE_REPO}:${env.IMAGE_TAG}"
                    env.TEST_IMAGE  = "healthcare-app-test:${env.IMAGE_TAG}"
                    env.CI_TMP      = "${env.WORKSPACE}@tmp\\ci-${env.BUILD_NUMBER}"
                    env.LOCK_HOLDER = "Healthcare-Blue-Green-${env.BUILD_NUMBER}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.ACTION} ${env.GIT_COMMIT_SHORT}"
                    currentBuild.description = params.ACTION == 'deploy' ? "image ${env.IMAGE_TAG}" : "rollback: ${params.ROLLBACK_REASON}"
                }
                powershell label: 'Verify commit and prepare private temp dir', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    Initialize-Build
                    New-Item -ItemType Directory -Force -Path "$env:WORKSPACE/reports" | Out-Null
                '''
            }
        }

        stage('Source Validation') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                powershell label: 'Validate repository contents', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    Test-SourceTree
                '''
            }
        }

        stage('Application Tests') {
            when { expression { params.ACTION == 'deploy' } }
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Build test image and run pytest', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    Invoke-ApplicationTests -JUnitPath "$env:WORKSPACE/reports/junit-blue-green.xml"
                '''
            }
            post { always { junit allowEmptyResults: true, testResults: 'reports/junit-blue-green.xml' } }
        }

        stage('Build New Docker Image') {
            when { expression { params.ACTION == 'deploy' } }
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Build runtime image', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    Build-RuntimeImage
                '''
            }
        }

        stage('Validate Docker Image') {
            when { expression { params.ACTION == 'deploy' } }
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                powershell label: 'Inspect and run the image', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    Test-RuntimeImage
                '''
            }
        }

        stage('Publish Image') {
            when { expression { params.ACTION == 'deploy' } }
            environment {
                DOCKERHUB     = credentials('dockerhub-creds')
                DOCKER_CONFIG = "${env.CI_TMP}\\docker-config"
            }
            stages {
                stage('Authenticate to Docker Hub') {
                    options { timeout(time: 3, unit: 'MINUTES') }
                    steps {
                        powershell label: 'docker login (isolated config)', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Connect-DockerHub
                        '''
                    }
                }
                stage('Push Versioned Image') {
                    options { timeout(time: 15, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Push immutable tag and verify registry digest', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Publish-Image
                            Confirm-PublishedImage
                            Disconnect-DockerHub
                        '''
                    }
                }
            }
        }

        stage('Blue-Green Release') {
            environment {
                EC2_SSH = credentials('aws-ec2-ssh')
            }
            stages {
                stage('Determine Current Production Environment') {
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Verify EC2, take deploy lock, read live production selector', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            $bundle = Join-Path $env:CI_TMP 'bundle'
                            New-DeploymentBundle -Destination $bundle -Image $env:IMAGE -Replicas ([int]$env:REPLICAS)
                            Confirm-Ec2Connection -BundleDir $bundle
                            if ($env:ACTION -eq 'deploy') {
                                $r = Invoke-RemoteBundle -LocalDir $bundle -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' `
                                    -ScriptArguments @('prepare', $env:LOCK_HOLDER, $env:REPLICAS)
                            } else {
                                $r = Invoke-RemoteBundle -LocalDir $bundle -Files (Get-BundleFiles lock) -EntryScript 'ns-lock.sh' `
                                    -ScriptArguments @('acquire', $env:LOCK_HOLDER)
                            }
                            # The lock may have been taken even if a later check failed.
                            Write-Utf8NoBomLf -Path (Join-Path $env:CI_TMP 'lock-attempted') -Text 'true'
                            Assert-Success $r 'Preparing the blue-green release failed'
                            $state = ($r.Output | Where-Object { $_ -match '^BG_(ACTIVE|TARGET)=[a-z]+$' }) -join "`n"
                            Write-Utf8NoBomLf -Path (Join-Path $env:CI_TMP 'bg-state.txt') -Text $state
                        '''
                        script {
                            if (params.ACTION == 'deploy') {
                                // Plain string parsing: regex Matchers are not serializable under CPS.
                                String active = ''
                                String target = ''
                                for (String line : readFile("${env.CI_TMP}\\bg-state.txt").split('\n')) {
                                    if (line.startsWith('BG_ACTIVE=')) { active = line.substring(10).trim() }
                                    if (line.startsWith('BG_TARGET=')) { target = line.substring(10).trim() }
                                }
                                if (!active || !target) { error('Could not determine the active/target environments') }
                                env.BG_ACTIVE = active
                                env.BG_TARGET = target
                                if (!(env.BG_TARGET in ['blue', 'green']) || env.BG_TARGET == env.BG_ACTIVE) {
                                    error("Invalid target '${env.BG_TARGET}' for active '${env.BG_ACTIVE}'")
                                }
                                echo "Production is currently ${env.BG_ACTIVE}; releasing ${env.IMAGE_TAG} to ${env.BG_TARGET}."
                                currentBuild.description = "${env.IMAGE_TAG}: ${env.BG_ACTIVE} -> ${env.BG_TARGET}"
                            }
                        }
                    }
                }
                stage('Prepare Inactive Environment') {
                    when { expression { params.ACTION == 'deploy' } }
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Render candidate manifest with the exact build image', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            $bundle = Join-Path $env:CI_TMP 'bundle'
                            New-DeploymentBundle -Destination $bundle -Image $env:IMAGE -Replicas ([int]$env:REPLICAS) `
                                -InjectReadinessFault:($env:SIMULATE_FAILED_VALIDATION -eq 'true')
                            $manifest = Join-Path $bundle "deployment-$env:BG_TARGET.yaml"
                            Write-Host "Candidate manifest for healthcare-$($env:BG_TARGET):"
                            Select-String -Path $manifest -Pattern '^\\s*(name: healthcare-|replicas:|image:|environment:|path:|healthcare.pbl/fault)' |
                                ForEach-Object { Write-Host "  $($_.Line.Trim())" }
                        '''
                    }
                }
                stage('Deploy Inactive Environment') {
                    when { expression { params.ACTION == 'deploy' } }
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Apply candidate; point preview Service at it', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $r = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' `
                                -ScriptArguments @('deploy', $env:BG_TARGET, $env:IMAGE, $env:BUILD_NUMBER, $env:GIT_COMMIT_SHORT)
                            Assert-Success $r "Deploying the candidate to $env:BG_TARGET failed"
                        '''
                    }
                }
                stage('Wait for Readiness') {
                    when { expression { params.ACTION == 'deploy' } }
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Bounded rollout wait (candidate is undone if it never becomes Ready)', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $r = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' `
                                -ScriptArguments @('wait', $env:BG_TARGET, $env:IMAGE, $env:REPLICAS)
                            Assert-Success $r "Candidate environment $env:BG_TARGET did not become Ready - promotion blocked"
                        '''
                    }
                }
                stage('Validate Inactive Environment') {
                    when { expression { params.ACTION == 'deploy' } }
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Probe stability, restarts, per-pod version, preview endpoints', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $r = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' `
                                -ScriptArguments @('validate', $env:BG_TARGET, $env:IMAGE, $env:IMAGE_TAG, $env:REPLICAS)
                            Assert-Success $r "Validation of candidate $env:BG_TARGET failed - promotion blocked"
                        '''
                    }
                }
                stage('Run Pre-Switch Smoke Tests') {
                    when { expression { params.ACTION == 'deploy' } }
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Smoke tests through the internal preview Service', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $r = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles smoke) -EntryScript 'smoke-test.sh' `
                                -ScriptArguments @($env:IMAGE_TAG, $env:BUILD_NUMBER, 'healthcare-preview-service')
                            Assert-Success $r "Pre-switch smoke tests against $env:BG_TARGET failed - promotion blocked"
                        '''
                    }
                }
                stage('Switch Production Service') {
                    when { expression { params.ACTION == 'deploy' } }
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        script { env.SWITCH_ATTEMPTED = 'true' }
                        powershell label: 'Patch production selector to the validated environment', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $r = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' `
                                -ScriptArguments @('switch', $env:BG_TARGET, $env:IMAGE, $env:IMAGE_TAG, $env:BUILD_NUMBER, $env:GIT_COMMIT_SHORT, $env:REPLICAS)
                            Assert-Success $r "Switching production to $env:BG_TARGET failed"
                        '''
                    }
                }
                stage('Verify Production Traffic') {
                    when { expression { params.ACTION == 'deploy' } }
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Smoke tests through the production Service', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $r = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles smoke) -EntryScript 'smoke-test.sh' `
                                -ScriptArguments @($env:IMAGE_TAG, $env:BUILD_NUMBER, 'healthcare-service')
                            Assert-Success $r 'Production smoke tests failed after the switch'
                        '''
                    }
                }
                stage('Monitor New Production Version') {
                    when { expression { params.ACTION == 'deploy' } }
                    options { timeout(time: 15, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Bounded post-switch monitoring', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $expected = $env:IMAGE_TAG
                            if ($env:SIMULATE_POST_SWITCH_FAILURE -eq 'true') {
                                Write-Host 'NEGATIVE TEST: monitoring will expect a version production cannot report, to exercise automatic rollback.'
                                $expected = 'simulated-post-switch-failure'
                            }
                            $r = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' `
                                -ScriptArguments @('monitor', $env:BG_TARGET, $expected, $env:MONITOR_SECONDS, $env:REPLICAS)
                            Assert-Success $r 'Post-switch monitoring failed'
                        '''
                    }
                }
                stage('Manual Rollback') {
                    when { expression { params.ACTION == 'rollback' } }
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Switch production back to the recorded previous environment', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $r = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' `
                                -ScriptArguments @('rollback', $env:BUILD_NUMBER, $env:ROLLBACK_REASON)
                            Assert-Success $r 'Manual rollback failed'
                        '''
                    }
                }
                stage('Record Deployment State') {
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Capture final deployment state', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $r = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' `
                                -ScriptArguments @('state')
                            Assert-Success $r 'Reading deployment state failed'
                            $json = ($r.Output | Where-Object { $_ -like 'STATE_JSON *' } | Select-Object -Last 1)
                            if (-not $json) { throw 'Deployment state JSON missing from remote output.' }
                            Write-Utf8NoBomLf -Path "$env:WORKSPACE/reports/deployment-state.json" -Text ($json.Substring(11) + "`n")
                            Write-Utf8NoBomLf -Path "$env:WORKSPACE/reports/deployment-state.txt" -Text (($r.Output -join "`n") + "`n")
                        '''
                    }
                }
            }
            post {
                failure {
                    script {
                        if (env.SWITCH_ATTEMPTED == 'true') {
                            echo 'Post-switch verification failed: rolling production back to the previous environment.'
                            powershell label: 'AUTOMATIC ROLLBACK', script: '''
                                . "$env:WORKSPACE/ci/stages.ps1"
                                Initialize-SshSession
                                $bundle = Join-Path $env:CI_TMP 'bundle'
                                $r = Invoke-RemoteBundle -LocalDir $bundle -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' `
                                    -ScriptArguments @('rollback', $env:BUILD_NUMBER, 'automatic-post-switch-verification-failure')
                                Write-Utf8NoBomLf -Path "$env:WORKSPACE/reports/rollback.log" -Text (($r.Output -join "`n") + "`n")
                                Assert-Success $r 'AUTOMATIC ROLLBACK FAILED - production needs manual attention'
                                $s = Invoke-RemoteBundle -LocalDir $bundle -Files (Get-BundleFiles bluegreen) -EntryScript 'bluegreen.sh' -ScriptArguments @('state')
                                Write-Utf8NoBomLf -Path "$env:WORKSPACE/reports/deployment-state-after-rollback.txt" -Text (($s.Output -join "`n") + "`n")
                            '''
                        }
                    }
                }
                cleanup {
                    script {
                        if (fileExists("${env.CI_TMP}\\lock-attempted")) {
                            powershell label: 'Release namespace deploy lock', script: '''
                                . "$env:WORKSPACE/ci/stages.ps1"
                                Initialize-SshSession
                                $u = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles lock) `
                                    -EntryScript 'ns-lock.sh' -ScriptArguments @('release', $env:LOCK_HOLDER)
                                Assert-Success $u 'Releasing the namespace deploy lock failed'
                            '''
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                if (fileExists('reports')) {
                    archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true, fingerprint: true
                }
            }
            powershell label: 'Cleanup', script: '''
                if (-not (Test-Path -LiteralPath "$env:WORKSPACE/ci/stages.ps1")) {
                    Write-Host 'Checkout did not complete; nothing was created that needs cleanup.'
                    exit 0
                }
                . "$env:WORKSPACE/ci/stages.ps1"
                if (Test-Path -LiteralPath "$env:WORKSPACE/reports") { Remove-Item -LiteralPath "$env:WORKSPACE/reports" -Recurse -Force }
                Invoke-BuildCleanup
            '''
        }
        success { echo "SUCCESS: Healthcare-Blue-Green ${params.ACTION} completed and verified." }
        failure { echo 'FAILURE: see the failed stage; production was either left untouched or rolled back (see AUTOMATIC ROLLBACK output).' }
    }
}
