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
    assert spec["selector"]["matchLabels"] == {"app": "healthcare", "environment": "rolling"}
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


def test_rolling_service_manifest():
    service = load("service.yaml")
    assert service["kind"] == "Service"
    assert service["metadata"]["name"] == "healthcare-rolling-service"
    assert service["metadata"]["namespace"] == "healthcare"
    assert service["spec"]["type"] == "NodePort"
    assert service["spec"]["selector"] == {"app": "healthcare", "environment": "rolling"}
    port = service["spec"]["ports"][0]
    assert port["targetPort"] == 5000
    assert port["nodePort"] == 30061


def test_rolling_deployment_selects_only_rolling_pods(deployment):
    selector = deployment["spec"]["selector"]["matchLabels"]
    assert selector == {"app": "healthcare", "environment": "rolling"}
    assert deployment["spec"]["template"]["metadata"]["labels"] == selector


# ---- Activity 8: blue-green ---------------------------------------------------

ENVIRONMENTS = ("blue", "green")


def bg(name):
    return load(f"blue-green/{name}")


@pytest.mark.parametrize("env", ENVIRONMENTS)
def test_blue_green_deployment_labels_and_selector(env):
    dep = bg(f"deployment-{env}.yaml")
    assert dep["kind"] == "Deployment"
    assert dep["metadata"]["name"] == f"healthcare-{env}"
    assert dep["metadata"]["namespace"] == "healthcare"
    expected = {"app": "healthcare", "environment": env}
    assert dep["spec"]["selector"]["matchLabels"] == expected
    assert dep["spec"]["template"]["metadata"]["labels"] == expected
    assert dep["spec"]["replicas"] == 2
    assert dep["spec"]["strategy"]["type"] == "RollingUpdate"


def test_blue_and_green_pod_specs_are_identical():
    blue = bg("deployment-blue.yaml")["spec"]["template"]["spec"]
    green = bg("deployment-green.yaml")["spec"]["template"]["spec"]
    assert blue == green


def test_blue_green_pod_spec_matches_rolling_pod_spec(deployment):
    # Same image settings, probes, resources and security context everywhere.
    assert bg("deployment-blue.yaml")["spec"]["template"]["spec"] == deployment["spec"]["template"]["spec"]


@pytest.mark.parametrize("env", ENVIRONMENTS)
def test_blue_green_security_context(env):
    container = bg(f"deployment-{env}.yaml")["spec"]["template"]["spec"]["containers"][0]
    security = container["securityContext"]
    assert security["runAsNonRoot"] is True
    assert security["runAsUser"] == 10001
    assert security["allowPrivilegeEscalation"] is False
    assert security["capabilities"]["drop"] == ["ALL"]
    assert container["readinessProbe"]["httpGet"]["path"] == "/health"
    assert container["livenessProbe"]["httpGet"]["path"] == "/health"


def test_production_service_routes_by_environment():
    service = bg("service.yaml")
    assert service["metadata"]["name"] == "healthcare-service"
    assert service["spec"]["type"] == "NodePort"
    assert service["spec"]["ports"][0]["nodePort"] == 30060
    assert service["spec"]["ports"][0]["targetPort"] == 5000
    selector = service["spec"]["selector"]
    assert selector["app"] == "healthcare"
    assert selector["environment"] in ENVIRONMENTS


def test_preview_service_is_internal_only():
    service = bg("service-preview.yaml")
    assert service["metadata"]["name"] == "healthcare-preview-service"
    assert service["spec"]["type"] == "ClusterIP"
    assert "nodePort" not in service["spec"]["ports"][0]
    assert service["spec"]["selector"]["environment"] in ENVIRONMENTS


def test_environment_selectors_are_disjoint(deployment):
    selectors = [deployment["spec"]["selector"]["matchLabels"]] + [
        bg(f"deployment-{env}.yaml")["spec"]["selector"]["matchLabels"] for env in ENVIRONMENTS
    ]
    environments = [sel["environment"] for sel in selectors]
    assert sorted(environments) == ["blue", "green", "rolling"]


# ---- Activity 9: Kubernetes hardening (Trivy KSV findings) ---------------------

ALL_DEPLOYMENTS = ["deployment.yaml", "blue-green/deployment-blue.yaml", "blue-green/deployment-green.yaml"]


@pytest.mark.parametrize("name", ALL_DEPLOYMENTS)
def test_pod_level_hardening(name):
    pod = load(name)["spec"]["template"]["spec"]
    assert pod["automountServiceAccountToken"] is False
    security = pod["securityContext"]
    assert security["runAsNonRoot"] is True
    assert security["runAsUser"] == 10001
    assert security["runAsGroup"] == 10001
    assert security["seccompProfile"] == {"type": "RuntimeDefault"}
    for forbidden in ("hostNetwork", "hostPID", "hostIPC"):
        assert not pod.get(forbidden, False)
    for volume in pod.get("volumes", []):
        assert "hostPath" not in volume


@pytest.mark.parametrize("name", ALL_DEPLOYMENTS)
def test_container_read_only_root_with_tmp_scratch(name):
    pod = load(name)["spec"]["template"]["spec"]
    container = pod["containers"][0]
    security = container["securityContext"]
    assert security["readOnlyRootFilesystem"] is True
    assert security["seccompProfile"] == {"type": "RuntimeDefault"}
    assert not security.get("privileged", False)
    assert {"name": "tmp", "mountPath": "/tmp"} in container["volumeMounts"]
    tmp = next(v for v in pod["volumes"] if v["name"] == "tmp")
    assert tmp["emptyDir"]["medium"] == "Memory"


@pytest.mark.parametrize("name", ALL_DEPLOYMENTS)
def test_frontend_environment_comes_from_downward_api(name):
    env = {e["name"]: e for e in load(name)["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["DEPLOY_ENVIRONMENT"]["valueFrom"]["fieldRef"]["fieldPath"] == "metadata.labels['environment']"
    assert env["POD_NAME"]["valueFrom"]["fieldRef"]["fieldPath"] == "metadata.name"
