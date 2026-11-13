
pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
    }

    environment {
        IMAGE_REPO = 'niranjanbalaguru/healthcare-app'
        EC2_HOST   = '184.73.3.54'
        REMOTE_DIR = '/tmp/healthcare-k8s'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Validate Source') {
            steps {
                powershell '''
                    $ErrorActionPreference = "Stop"

                    $requiredFiles = @(
                        "app/app.py",
                        "app/requirements.txt",
                        "Dockerfile",
                        "k8s/namespace.yaml",
                        "k8s/deployment.yaml",
                        "k8s/service.yaml"
                    )

                    foreach ($file in $requiredFiles) {
                        if (!(Test-Path $file)) {
                            throw "Required file missing: $file"
                        }
                        Write-Host "Verified: $file"
                    }

                    Write-Host "Source validation passed."
                '''
            }
        }

        stage('Build Docker Image') {
            steps {
                script {
                    env.IMAGE_TAG = "build-${env.BUILD_NUMBER}"
                }

                powershell '''
                    $ErrorActionPreference = "Stop"

                    $image = "$($env:IMAGE_REPO):$($env:IMAGE_TAG)"

                    Write-Host "Building Docker image: $image"

                    docker build `
                        --build-arg "APP_VERSION=$env:IMAGE_TAG" `
                        -t $image .

                    if ($LASTEXITCODE -ne 0) {
                        throw "Docker image build failed."
                    }

                    Write-Host "Docker image built successfully."
                '''
            }
        }

        
stage('Push to Docker Hub') {
    steps {
        withCredentials([
            usernamePassword(
                credentialsId: 'dockerhub-creds',
                usernameVariable: 'DOCKERHUB_USER',
                passwordVariable: 'DOCKERHUB_TOKEN'
            )
        ]) {
            powershell '''
                $ErrorActionPreference = "Continue"

                # Create a separate Docker configuration for this build.
                $dockerConfig = Join-Path $env:WORKSPACE ".docker-auth-$env:BUILD_NUMBER"

                New-Item -ItemType Directory -Force -Path $dockerConfig | Out-Null

                $env:DOCKER_CONFIG = $dockerConfig

                try {
                    Write-Host "Using isolated Docker configuration."
                    Write-Host "Docker username: $env:DOCKERHUB_USER"

                    if ([string]::IsNullOrWhiteSpace($env:DOCKERHUB_TOKEN)) {
                        throw "Jenkins Docker Hub token is empty."
                    }

                    # Authenticate using Jenkins credentials.
                    $token = $env:DOCKERHUB_TOKEN.Trim()

                    $token | docker login `
                        --username $env:DOCKERHUB_USER `
                        --password-stdin

                    if ($LASTEXITCODE -ne 0) {
                        throw "Docker Hub authentication failed."
                    }

                    Write-Host "Docker Hub authentication successful."

                    # Push the image.
                    $image = "$($env:IMAGE_REPO):$($env:IMAGE_TAG)"

                    Write-Host "Pushing image: $image"

                    docker push $image

                    if ($LASTEXITCODE -ne 0) {
                        throw "Docker image push failed."
                    }

                    Write-Host "Docker image pushed successfully."
                }
                finally {
                    # Remove temporary registry credentials.
                    docker logout 2>$null | Out-Null

                    Remove-Item -Path $dockerConfig `
                        -Recurse -Force -ErrorAction SilentlyContinue

                    Write-Host "Temporary Docker credentials cleaned up."
                }
            '''
        }
    }
}
        stage('Deploy to Kubernetes') {
            steps {
                withCredentials([
                    sshUserPrivateKey(
                        credentialsId: 'aws-ec2-ssh',
                        keyFileVariable: 'SSH_KEY',
                        usernameVariable: 'SSH_USER'
                    )
                ]) {
                    powershell '''
                        $ErrorActionPreference = "Stop"

                        $sshOptions = @(
                            "-i", $env:SSH_KEY,
                            "-o", "StrictHostKeyChecking=accept-new",
                            "-o", "BatchMode=yes"
                        )

                        $remote = "$($env:SSH_USER)@$($env:EC2_HOST)"

                        Write-Host "Checking SSH connectivity to EC2..."

                        ssh @sshOptions $remote "echo SSH connection successful"

                        if ($LASTEXITCODE -ne 0) {
                            throw "SSH connection to EC2 failed."
                        }

                        ssh @sshOptions $remote "mkdir -p $($env:REMOTE_DIR)"

                        if ($LASTEXITCODE -ne 0) {
                            throw "Could not create remote manifest directory."
                        }

                        Write-Host "Transferring Kubernetes manifests..."

                        scp @sshOptions `
                            "k8s/namespace.yaml" `
                            "k8s/deployment.yaml" `
                            "k8s/service.yaml" `
                            "${remote}:$($env:REMOTE_DIR)/"

                        if ($LASTEXITCODE -ne 0) {
                            throw "Kubernetes manifest transfer failed."
                        }

                        $image = "$($env:IMAGE_REPO):$($env:IMAGE_TAG)"
                        $version = $env:IMAGE_TAG

                        $remoteCommand = "sudo kubectl apply -f $($env:REMOTE_DIR)/namespace.yaml && sudo kubectl apply -f $($env:REMOTE_DIR)/deployment.yaml && sudo kubectl apply -f $($env:REMOTE_DIR)/service.yaml && sudo kubectl set image deployment/healthcare-deployment healthcare-app=$image -n healthcare && sudo kubectl set env deployment/healthcare-deployment APP_VERSION=$version -n healthcare && sudo kubectl rollout status deployment/healthcare-deployment -n healthcare --timeout=180s && sudo kubectl get pods -n healthcare -o wide && sudo kubectl get svc -n healthcare"

                        Write-Host "Deploying image: $image"

                        ssh @sshOptions $remote $remoteCommand

                        if ($LASTEXITCODE -ne 0) {
                            throw "Kubernetes deployment or rollout verification failed."
                        }

                        Write-Host "Kubernetes deployment completed successfully."
                    '''
                }
            }
        }
    }

    post {
        success {
            echo 'SUCCESS: Healthcare CI/CD pipeline completed.'
        }

        failure {
            echo 'FAILURE: Healthcare CI/CD pipeline failed. Inspect the failed stage.'
        }

        always {
            echo 'Pipeline execution finished.'
        }
    }
}
