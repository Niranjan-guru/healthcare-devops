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
                    env.TEST_IMAGE = "healthcare-app-test:cicd-${env.IMAGE_TAG}"
                    env.CI_TMP     = "${env.WORKSPACE}@tmp\\ci-${env.BUILD_NUMBER}"
                    env.LOCK_HOLDER = "Healthcare-CI-CD-${env.BUILD_NUMBER}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.GIT_COMMIT_SHORT}"
                }
                powershell label: 'Verify commit and prepare private temp dir', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    Initialize-Build
                '''
            }
        }

        stage('Validate Source') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                powershell label: 'Validate repository contents', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    Test-SourceTree
                '''
            }
        }

        stage('Run Application Tests') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Build test image and run pytest', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    New-Item -ItemType Directory -Force -Path "$env:WORKSPACE/reports" | Out-Null
                    Invoke-ApplicationTests -JUnitPath "$env:WORKSPACE/reports/junit-cicd.xml"
                '''
            }
            post {
                always { junit allowEmptyResults: true, testResults: 'reports/junit-cicd.xml' }
            }
        }

        stage('Build Docker Image') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                powershell label: 'Build runtime image', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    Build-RuntimeImage
                '''
            }
        }

        stage('Validate Docker Image') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                powershell label: 'Inspect and run the image', script: '''
                    . "$env:WORKSPACE/ci/stages.ps1"
                    Test-RuntimeImage
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
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Connect-DockerHub
                        '''
                    }
                }
                stage('Push Docker Image') {
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'docker push', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Publish-Image
                        '''
                    }
                }
                stage('Verify Published Image') {
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Verify registry digest, then publish latest', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Confirm-PublishedImage -TagLatest
                            Disconnect-DockerHub
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
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Secure key, pin host key, authenticate, verify instance, take deploy lock', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            $bundle = Join-Path $env:CI_TMP 'bundle'
                            New-DeploymentBundle -Destination $bundle -Image $env:IMAGE
                            Confirm-Ec2Connection -BundleDir $bundle
                            Write-Section 'Acquiring namespace deploy lock'
                            $lock = Invoke-RemoteBundle -LocalDir $bundle -Files (Get-BundleFiles lock) -EntryScript 'ns-lock.sh' `
                                -ScriptArguments @('acquire', $env:LOCK_HOLDER)
                            Assert-Success $lock 'Could not acquire the namespace deploy lock'
                        '''
                        script { env.LOCK_ACQUIRED = 'true' }
                    }
                }
                stage('Deploy to Kubernetes') {
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Apply manifests with the exact build image', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $result = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles rolling) `
                                -EntryScript 'deploy.sh' `
                                -ScriptArguments @('apply', $env:IMAGE, $env:IMAGE_TAG, $env:BUILD_NUMBER, $env:GIT_COMMIT_SHORT)
                            Assert-Success $result 'Kubernetes deployment failed'
                        '''
                    }
                }
                stage('Verify Kubernetes Rollout') {
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        powershell label: 'Rollout, pods, probes, version, endpoints', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $result = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles rolling) `
                                -EntryScript 'deploy.sh' `
                                -ScriptArguments @('verify', $env:IMAGE, $env:IMAGE_TAG, $env:BUILD_NUMBER, $env:GIT_COMMIT_SHORT)
                            Assert-Success $result 'Kubernetes rollout verification failed'
                        '''
                    }
                }
                stage('Application Smoke Tests') {
                    options { timeout(time: 5, unit: 'MINUTES') }
                    steps {
                        powershell label: 'HTTP smoke tests via the rolling Service on the EC2 host', script: '''
                            . "$env:WORKSPACE/ci/stages.ps1"
                            Initialize-SshSession
                            $result = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles smoke) `
                                -EntryScript 'smoke-test.sh' -ScriptArguments @($env:IMAGE_TAG, $env:BUILD_NUMBER, 'healthcare-rolling-service', 'rolling')
                            Assert-Success $result 'Application smoke tests failed'
                        '''
                    }
                }
            }
            post {
                always {
                    script {
                        if (env.LOCK_ACQUIRED == 'true') {
                            powershell label: 'Release namespace deploy lock', script: '''
                                . "$env:WORKSPACE/ci/stages.ps1"
                                Initialize-SshSession
                                $unlock = Invoke-RemoteBundle -LocalDir (Join-Path $env:CI_TMP 'bundle') -Files (Get-BundleFiles lock) `
                                    -EntryScript 'ns-lock.sh' -ScriptArguments @('release', $env:LOCK_HOLDER)
                                Assert-Success $unlock 'Releasing the namespace deploy lock failed'
                            '''
                        }
                    }
                }
            }
        }
    }

    post {
        always {
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
        success {
            echo "SUCCESS: ${env.IMAGE} built, published, deployed to K3s (rolling environment) and verified."
        }
        failure {
            echo 'FAILURE: see the first failed stage above for the diagnostic message.'
        }
    }
}
