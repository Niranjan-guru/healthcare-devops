"""Static validation of the Kubernetes manifests and their security settings."""
from pathlib import Path

import pytest
import yaml

K8S_DIR = Path(__file__).resolve().parent.parent / "k8s"


def load(name):
    with open(K8S_DIR / name, encoding="utf-8") as handle:
        documents = [doc for doc in yaml.safe_load_all(handle) if doc]
    assert len(documents) == 1, f"{name} must contain exactly one document"
    return documents[0]


@pytest.fixture(scope="module")
def deployment():
    return load("deployment.yaml")


@pytest.fixture(scope="module")
def container(deployment):
    containers = deployment["spec"]["template"]["spec"]["containers"]
    assert len(containers) == 1
    return containers[0]


def test_namespace_manifest():
    namespace = load("namespace.yaml")
    assert namespace["kind"] == "Namespace"
    assert namespace["metadata"]["name"] == "healthcare"


def test_deployment_identity_and_strategy(deployment):
    assert deployment["kind"] == "Deployment"
    assert deployment["metadata"]["name"] == "healthcare-deployment"
    assert deployment["metadata"]["namespace"] == "healthcare"
    spec = deployment["spec"]
    assert spec["replicas"] == 2
    assert spec["strategy"]["type"] == "RollingUpdate"
    assert spec["selector"]["matchLabels"] == {"app": "healthcare"}
    assert spec["template"]["metadata"]["labels"]["app"] == "healthcare"


def test_container_image_and_port(container):
    assert container["name"] == "healthcare-app"
    # The pipeline replaces this tag with the exact build tag at deploy time.
    assert container["image"].startswith("niranjanbalaguru/healthcare-app:")
    assert {"containerPort": 5000, "name": "http", "protocol": "TCP"} in container["ports"]


@pytest.mark.parametrize("probe", ["readinessProbe", "livenessProbe"])
def test_probes_target_health_endpoint(container, probe):
    http_get = container[probe]["httpGet"]
    assert http_get["path"] == "/health"
    assert http_get["port"] == "http"


def test_resource_requests_and_limits(container):
    resources = container["resources"]
    for section in ("requests", "limits"):
        assert {"cpu", "memory"} <= set(resources[section])


def test_container_security_context(container):
    security = container["securityContext"]
    assert security["runAsNonRoot"] is True
    assert security["runAsUser"] == 10001
    assert security["allowPrivilegeEscalation"] is False
    assert security["capabilities"]["drop"] == ["ALL"]


def test_service_manifest():
    service = load("service.yaml")
    assert service["kind"] == "Service"
    assert service["metadata"]["name"] == "healthcare-service"
    assert service["metadata"]["namespace"] == "healthcare"
    assert service["spec"]["type"] == "NodePort"
    assert service["spec"]["selector"] == {"app": "healthcare"}
    port = service["spec"]["ports"][0]
    assert port["targetPort"] == 5000
    assert port["nodePort"] == 30060
