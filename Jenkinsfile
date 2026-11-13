
pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
    }

    environment {
        IMAGE_REPO = 'niranjanbalaguru/healthcare-app'
        EC2_HOST   = '18.234.149.150'
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
                    if (!(Test-Path "app/app.py")) {
                        throw "Application source is missing"
                    }

                    if (!(Test-Path "Dockerfile")) {
                        throw "Dockerfile is missing"
                    }

                    if (!(Test-Path "k8s/deployment.yaml")) {
                        throw "Kubernetes Deployment manifest is missing"
                    }

                    python -m py_compile app/app.py
                    Write-Host "Source validation passed"
                '''
            }
        }

        stage('Build Docker Image') {
            steps {
                script {
                    env.IMAGE_TAG = "build-${env.BUILD_NUMBER}"
                }

                powershell '''
                    $image = "$($env:IMAGE_REPO):$($env:IMAGE_TAG)"

                    docker build --build-arg APP_VERSION=$env:IMAGE_TAG -t $image .
                    if ($LASTEXITCODE -ne 0) {
                        throw "Docker image build failed"
                    }

                    Write-Host "Built image: $image"
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
                        $env:DOCKERHUB_TOKEN |
                            docker login --username $env:DOCKERHUB_USER --password-stdin

                        if ($LASTEXITCODE -ne 0) {
                            throw "Docker Hub login failed"
                        }

                        $image = "$($env:IMAGE_REPO):$($env:IMAGE_TAG)"
                        docker push $image

                        if ($LASTEXITCODE -ne 0) {
                            throw "Docker image push failed"
                        }

                        docker logout
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
                        $sshOptions = @(
                            "-i", $env:SSH_KEY,
                            "-o", "StrictHostKeyChecking=accept-new"
                        )

                        ssh @sshOptions "$($env:SSH_USER)@$($env:EC2_HOST)" `
                            "mkdir -p $($env:REMOTE_DIR)"

                        if ($LASTEXITCODE -ne 0) {
                            throw "Could not create remote manifest directory"
                        }

                        scp @sshOptions `
                            "k8s/namespace.yaml" `
                            "k8s/deployment.yaml" `
                            "k8s/service.yaml" `
                            "$($env:SSH_USER)@$($env:EC2_HOST):$($env:REMOTE_DIR)/"

                        if ($LASTEXITCODE -ne 0) {
                            throw "Manifest transfer failed"
                        }

                        $image = "$($env:IMAGE_REPO):$($env:IMAGE_TAG)"

                        $remoteCommand = "sudo kubectl apply -f $($env:REMOTE_DIR)/namespace.yaml && sudo kubectl apply -f $($env:REMOTE_DIR)/deployment.yaml && sudo kubectl apply -f $($env:REMOTE_DIR)/service.yaml && sudo kubectl set image deployment/healthcare-deployment healthcare-app=$image -n healthcare && sudo kubectl set env deployment/healthcare-deployment APP_VERSION=$image -n healthcare && sudo kubectl rollout status deployment/healthcare-deployment -n healthcare --timeout=180s && sudo kubectl get pods -n healthcare -o wide && sudo kubectl get svc -n healthcare"

                        ssh @sshOptions `
                            "$($env:SSH_USER)@$($env:EC2_HOST)" `
                            $remoteCommand

                        if ($LASTEXITCODE -ne 0) {
                            throw "Kubernetes deployment or rollout verification failed"
                        }
                    '''
                }
            }
        }
    }

    post {
        success {
            echo 'CI/CD pipeline completed successfully.'
        }

        failure {
            echo 'CI/CD pipeline failed. Check the failed stage in the Jenkins console.'
        }
    }
}