
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
        stage('Docker credential Fingerprint Test') {
            steps{
                withCredentials([
                    usernamePassword(
                        credentialsId: 'dockerhub-creds',
                        usernameVariable: 'DOCKERHUB_USER',
                        passwordVariable: 'DOCKERHUB_TOKEN'
                    )
                ]){
                    powershell '''
                        $token = $env:DOCKERHUB_TOKEN.Trim()

                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($token)
                        $sha = [System.Security.Cryptography.SHA256]::Create()

                        try{
                            $hash = [BitConverter]::ToString(
                                $sha.ComputeHash($bytes)
                            ).Replace("-","")

                            Write-Host "Jenkins username: $env:DOCKERHUB_USER"
                            Write-Host "Jenkins token length: $($token.Length)"
                            Write-Host "Jenkins token fingerprint: $($hash.Substring(0,12))"
                        }
                        finally{
                            $sha.Dispose()
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
