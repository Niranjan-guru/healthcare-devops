// Activity 9 - Secure DevOps (DevSecOps) pipeline, job Healthcare-DevSecOps.
//
// Security controls integrated into the delivery pipeline:
//   secrets (Gitleaks + synthetic-secret self-test), SAST (Semgrep),
//   dependencies (pip-audit), Dockerfile + Kubernetes configuration (Trivy),
//   container image vulnerabilities (Trivy), SBOM (Trivy CycloneDX),
//   DAST (OWASP ZAP baseline + API scan against a disposable container).
// The release gate (ci/security/evaluate_policy.py + security-policy.yaml)
// decides PASS/FAIL from the actual findings. Scanner crashes are
// TOOL-ERRORs and fail the build; they are never treated as clean scans.
//
// Only when the gate passes may the scanned image be published as a
// verified, immutable tag sec-<build>-<commit> (optional stage).

pipeline {
    agent any

    parameters {
        booleanParam(name: 'PUBLISH_VERIFIED_IMAGE', defaultValue: true,
            description: 'After the security gate passes, push the scanned image as niranjanbalaguru/healthcare-app:sec-<build>-<commit>.')
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 75, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '25'))
    }

    environment {
        IMAGE_REPO = 'niranjanbalaguru/healthcare-app'
    }

    stages {
        stage('Checkout') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                script {
                    def scmVars = checkout scm
                    def commit = scmVars.GIT_COMMIT
                    if (!(commit ==~ /[0-9a-f]{40}/)) { error("Checkout did not return a valid commit SHA: ${commit}") }
                    env.GIT_COMMIT_FULL  = commit
                    env.GIT_COMMIT_SHORT = commit.substring(0, 7)
                    env.IMAGE_TAG  = "sec-${env.BUILD_NUMBER}-${env.GIT_COMMIT_SHORT}"
                    env.IMAGE      = "${env.IMAGE_REPO}:${env.IMAGE_TAG}"
                    env.TEST_IMAGE = "healthcare-app-test:${env.IMAGE_TAG}"
                    env.CI_TMP     = "${env.WORKSPACE}@tmp\\ci-${env.BUILD_NUMBER}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.GIT_COMMIT_SHORT}"
                }
                powershell label: 'Verify commit, private temp dir, scanner images, source export', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Initialize-Build
                    if (Test-Path -LiteralPath (Get-ReportsDir)) { Remove-Item -LiteralPath (Get-ReportsDir) -Recurse -Force }
                    Initialize-SecurityTools
                '''
            }
        }

        stage('Source Validation') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                powershell label: 'Validate repository contents', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Test-SourceTree
                    foreach ($f in 'ci/security.ps1', 'ci/security/evaluate_policy.py', 'ci/security/security-policy.yaml',
                                   'ci/security/tools.Dockerfile', 'ci/security/openapi.yaml') {
                        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "Required security file missing: $f" }
                    }
                    Write-Host 'Security tooling and policy files present.'
                '''
            }
        }

        stage('Secret Detection') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Gitleaks (history) + synthetic secret self-test', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Invoke-SecretScan
                '''
            }
        }

        stage('Static Application Security Testing') {
            options { timeout(time: 15, unit: 'MINUTES') }
            steps {
                powershell label: 'Semgrep', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Invoke-Sast
                '''
            }
        }

        stage('Dependency Vulnerability Scan') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'pip-audit', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Invoke-DependencyScan
                '''
            }
        }

        stage('Application Tests') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'pytest (unit, security headers, manifest hardening)', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Invoke-ApplicationTests -JUnitPath "$env:WORKSPACE/reports/junit-devsecops.xml"
                '''
            }
            post { always { junit allowEmptyResults: true, testResults: 'reports/junit-devsecops.xml' } }
        }

        stage('Dockerfile Security Scan') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Trivy config (Dockerfile)', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Invoke-DockerfileScan
                '''
            }
        }

        stage('Docker Image Build') {
            options { timeout(time: 15, unit: 'MINUTES') }
            steps {
                powershell label: 'Build and validate the runtime image', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Build-RuntimeImage
                    Test-RuntimeImage
                '''
            }
        }

        stage('Container Vulnerability Scan') {
            options { timeout(time: 20, unit: 'MINUTES') }
            steps {
                powershell label: 'Trivy image (exact immutable tag)', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Invoke-ImageScan
                '''
            }
        }

        stage('SBOM Generation') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Trivy CycloneDX SBOM', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    New-ImageSbom
                '''
            }
        }

        stage('Kubernetes Manifest Scan') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Trivy config (k8s manifests)', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Invoke-K8sManifestScan
                '''
            }
        }

        stage('DAST') {
            options { timeout(time: 20, unit: 'MINUTES') }
            steps {
                powershell label: 'OWASP ZAP baseline + API scan (disposable isolated target)', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Invoke-Dast
                '''
            }
        }

        stage('Security Policy Evaluation') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                powershell label: 'Release gate', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Invoke-SecurityPolicy
                '''
            }
        }

        stage('Artifact Archival') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                powershell label: 'Verify reports contain no secrets', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Test-ReportsForSecrets
                '''
                archiveArtifacts artifacts: 'reports/**', fingerprint: true
                script { env.REPORTS_ARCHIVED = 'true' }
            }
        }

        stage('Optional Secure Deployment') {
            when { expression { params.PUBLISH_VERIFIED_IMAGE } }
            environment {
                DOCKERHUB     = credentials('dockerhub-creds')
                DOCKER_CONFIG = "${env.CI_TMP}\\docker-config"
            }
            options { timeout(time: 15, unit: 'MINUTES') }
            steps {
                powershell label: 'Publish the gate-approved image as an immutable verified tag', script: '''
                    . "$env:WORKSPACE/ci/security.ps1"
                    Connect-DockerHub
                    try {
                        Publish-Image
                        Confirm-PublishedImage
                    } finally {
                        Disconnect-DockerHub
                    }
                    Write-Host "Verified image published: $env:IMAGE ($env:IMAGE_DIGEST). It passed every security gate for commit $env:GIT_COMMIT_FULL."
                '''
            }
        }

        stage('Final Security Report') {
            steps {
                powershell label: 'Print the security report', script: '''
                    Get-Content -Raw "$env:WORKSPACE/reports/security-report.md" | Write-Host
                '''
            }
        }
    }

    post {
        always {
            script {
                // On failure, still archive the evidence - but only after the
                // secret check passes, so artifacts never carry secret values.
                if (env.REPORTS_ARCHIVED != 'true' && fileExists('reports')) {
                    powershell label: 'Verify reports contain no secrets', script: '''
                        . "$env:WORKSPACE/ci/security.ps1"
                        Test-ReportsForSecrets
                    '''
                    archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true, fingerprint: true
                }
            }
            powershell label: 'Cleanup', script: '''
                if (-not (Test-Path -LiteralPath "$env:WORKSPACE/ci/security.ps1")) {
                    Write-Host 'Checkout did not complete; nothing was created that needs cleanup.'
                    exit 0
                }
                . "$env:WORKSPACE/ci/security.ps1"
                foreach ($n in @("healthcare-dast-target-$env:BUILD_NUMBER")) { Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $n) -Quiet | Out-Null }
                Invoke-Native -FilePath 'docker' -ArgumentList @('network', 'rm', "healthcare-dast-$env:BUILD_NUMBER") -Quiet | Out-Null
                if (Test-Path -LiteralPath "$env:WORKSPACE/reports") { Remove-Item -LiteralPath "$env:WORKSPACE/reports" -Recurse -Force }
                Invoke-BuildCleanup
            '''
        }
        success { echo "SUCCESS: ${env.IMAGE} passed the security gate. Reports and SBOM archived." }
        failure { echo 'FAILURE: see the failed stage and security-report.md in the build artifacts.' }
    }
}
