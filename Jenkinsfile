pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
    }

    environment {
        IMAGE_REPO = 'niranjanbalaguru/healthcare-app'
        IMAGE_TAG  = "build-${env.BUILD_NUMBER}"
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
                        if (!(Test-Path -Path $file -PathType Leaf)) {
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
                powershell '''
                    # Use "Continue" for native CLI commands so stderr progress output does not throw false exceptions
                    $ErrorActionPreference = "Continue"

                    $image  = "$($env:IMAGE_REPO):$($env:IMAGE_TAG)"
                    $latest = "$($env:IMAGE_REPO):latest"

                    Write-Host "Building Docker image: $image"

                    docker build --build-arg "APP_VERSION=$($env:IMAGE_TAG)" -t $image -t $latest .
                    if ($LASTEXITCODE -ne 0) {
                        throw "Docker image build failed with exit code $LASTEXITCODE."
                    }

                    Write-Host "Docker image built successfully."
                '''
            }
        }

        stage('Login & Push to Docker Hub') {
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

                        $user  = $env:DOCKERHUB_USER.Trim()
                        $token = $env:DOCKERHUB_TOKEN.Trim()
                        $image  = "$($env:IMAGE_REPO):$($env:IMAGE_TAG)"
                        $latest = "$($env:IMAGE_REPO):latest"

                        # 1. Verify credential integrity (safe diagnostic output)
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($token)
                        $sha   = [System.Security.Cryptography.SHA256]::Create()
                        try {
                            $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "")
                            Write-Host "Docker Hub User: $user | Token Length: $($token.Length) | SHA256 Prefix: $($hash.Substring(0, 12))"
                        }
                        finally {
                            $sha.Dispose()
                        }

                        # 2. Authenticate to Docker Hub using stdin to avoid CLI password exposure
                        Write-Host "Authenticating with Docker Hub..."
                        $token | docker login -u $user --password-stdin
                        if ($LASTEXITCODE -ne 0) {
                            throw "Docker Hub authentication failed. Ensure 'dockerhub-creds' holds your Docker Hub username (not email) and a Read/Write Access Token."
                        }

                        # 3. Push versioned tag and latest tag to Docker Hub so Kubernetes can pull it
                        Write-Host "Pushing image: $image"
                        docker push $image
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to push $image to Docker Hub."
                        }

                        Write-Host "Pushing image: $latest"
                        docker push $latest
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to push $latest to Docker Hub."
                        }

                        docker logout | Out-Null
                        Write-Host "Docker image pushed to Docker Hub successfully."
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
                        $ErrorActionPreference = "Continue"

                        # 1. Fix Windows OpenSSH private key permissions (prevents "UNPROTECTED PRIVATE KEY FILE" failure)
                        icacls "$env:SSH_KEY" /inheritance:r | Out-Null
                        icacls "$env:SSH_KEY" /grant:r "$($env:USERNAME):(R)" | Out-Null

                        $sshOptions = @(
                            "-i", "$env:SSH_KEY",
                            "-o", "StrictHostKeyChecking=no",
                            "-o", "UserKnownHostsFile=/dev/null",
                            "-o", "BatchMode=yes",
                            "-o", "ConnectTimeout=15"
                        )

                        $remote = "$($env:SSH_USER)@$($env:EC2_HOST)"

                        Write-Host "1. Checking SSH connectivity to EC2 ($remote)..."
                        ssh @sshOptions $remote "echo 'SSH connection verified'"
                        if ($LASTEXITCODE -ne 0) {
                            throw "SSH connection to EC2 ($remote) failed."
                        }

                        Write-Host "2. Preparing remote manifest directory ($($env:REMOTE_DIR))..."
                        ssh @sshOptions $remote "rm -rf $($env:REMOTE_DIR) && mkdir -p $($env:REMOTE_DIR)"
                        if ($LASTEXITCODE -ne 0) {
                            throw "Could not create remote manifest directory."
                        }

                        Write-Host "3. Transferring Kubernetes manifests via SCP..."
                        scp @sshOptions "k8s/namespace.yaml" "k8s/deployment.yaml" "k8s/service.yaml" "${remote}:$($env:REMOTE_DIR)/"
                        if ($LASTEXITCODE -ne 0) {
                            throw "Kubernetes manifest transfer failed."
                        }

                        $image   = "$($env:IMAGE_REPO):$($env:IMAGE_TAG)"
                        $version = $env:IMAGE_TAG

                        # 4. Execute deployment on EC2 (Auto-detects kubeconfig for standard K8s, K3s, or sudo setups)
                        $remoteScript = @"
set -e

# Automatically detect the right kubectl command/config on EC2
if kubectl cluster-info >/dev/null 2>&1; then
    KCMD="kubectl"
elif [ -f `$HOME/.kube/config ]; then
    KCMD="sudo --preserve-env=HOME kubectl --kubeconfig=`$HOME/.kube/config"
elif sudo test -f /etc/rancher/k3s/k3s.yaml; then
    KCMD="sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml"
elif sudo test -f /etc/kubernetes/admin.conf; then
    KCMD="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
else
    KCMD="sudo kubectl"
fi

echo "Using Kubernetes CLI: `$KCMD"

`$KCMD apply -f $($env:REMOTE_DIR)/namespace.yaml
`$KCMD apply -f $($env:REMOTE_DIR)/deployment.yaml
`$KCMD apply -f $($env:REMOTE_DIR)/service.yaml

`$KCMD set image deployment/healthcare-deployment healthcare-app=$image -n healthcare
`$KCMD set env deployment/healthcare-deployment APP_VERSION=$version -n healthcare

`$KCMD rollout status deployment/healthcare-deployment -n healthcare --timeout=180s
`$KCMD get pods -n healthcare -o wide
`$KCMD get svc -n healthcare
"@

                        # Strip Windows CRLF line endings before sending over SSH to Linux bash
                        $cleanRemoteScript = $remoteScript.Replace("`r`n", "`n")

                        Write-Host "4. Applying manifests and rolling out image: $image"
                        ssh @sshOptions $remote $cleanRemoteScript
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
        always {
            powershell '''
                $ErrorActionPreference = "Continue"
                if ($env:IMAGE_REPO -and $env:IMAGE_TAG) {
                    docker rmi "$($env:IMAGE_REPO):$($env:IMAGE_TAG)" 2>$null | Out-Null
                }
            '''
            echo 'Pipeline execution finished.'
        }
        success {
            echo 'SUCCESS: Healthcare CI/CD pipeline completed.'
        }
        failure {
            echo 'FAILURE: Healthcare CI/CD pipeline failed. Inspect the failed stage.'
        }
    }
}