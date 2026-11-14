"""Functional tests for the synthetic healthcare appointment API."""
import pathlib

import pytest

import app as app_module

SYNTHETIC_PATIENT = "Synthetic Test Patient"


@pytest.fixture()
def client():
    app_module.app.config.update(TESTING=True)
    app_module.appointments.clear()
    with app_module.app.test_client() as test_client:
        yield test_client
    app_module.appointments.clear()


def test_root_endpoint_describes_application(client):
    response = client.get("/")
    assert response.status_code == 200
    body = response.get_json()
    assert body["application"] == "Healthcare Appointment management"
    assert body["version"] == app_module.APP_VERSION
    assert set(body["endpoints"]) == {
        "/health", "/version", "/api/deployment", "/api/doctors", "/api/appointments"
    }


def test_health_endpoint_reports_healthy(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "HEALTHY", "version": app_module.APP_VERSION}


def test_version_endpoint_reports_configured_version(client):
    response = client.get("/version")
    assert response.status_code == 200
    assert response.get_json() == {"version": app_module.APP_VERSION}


def test_version_comes_from_environment(monkeypatch):
    import importlib

    monkeypatch.setenv("APP_VERSION", "ci-test-42")
    reloaded = importlib.reload(app_module)
    try:
        assert reloaded.APP_VERSION == "ci-test-42"
        with reloaded.app.test_client() as test_client:
            assert test_client.get("/version").get_json() == {"version": "ci-test-42"}
    finally:
        monkeypatch.delenv("APP_VERSION")
        importlib.reload(app_module)


def test_doctors_endpoint_returns_synthetic_doctors(client):
    response = client.get("/api/doctors")
    assert response.status_code == 200
    doctors = response.get_json()
    assert [d["id"] for d in doctors] == [1, 2, 3]
    assert {d["specialty"] for d in doctors} == {"Cardiology", "Dermatology", "Neurology"}
    for doctor in doctors:
        assert set(doctor) == {"id", "name", "specialty"}
        assert doctor["name"].startswith("Dr.")


def test_appointments_initially_empty(client):
    response = client.get("/api/appointments")
    assert response.status_code == 200
    assert response.get_json() == []


def test_create_valid_synthetic_appointment(client):
    payload = {
        "doctor_id": 2,
        "patient_name": SYNTHETIC_PATIENT,
        "appointment_date": "2030-01-15",
    }
    response = client.post("/api/appointments", json=payload)
    assert response.status_code == 201
    body = response.get_json()
    assert body["message"] == "Appointment created successfully"
    appointment = body["appointment"]
    assert appointment["id"] == 1
    assert appointment["doctor"] == "Dr.Priya Sharma"
    assert appointment["patient_name"] == SYNTHETIC_PATIENT
    assert appointment["appointment_date"] == "2030-01-15"
    assert appointment["status"] == "scheduled"
    assert appointment["created_at"]

    listed = client.get("/api/appointments").get_json()
    assert listed == [appointment]


def test_appointment_ids_increment(client):
    for expected_id in (1, 2):
        response = client.post("/api/appointments", json={
            "doctor_id": 1,
            "patient_name": SYNTHETIC_PATIENT,
            "appointment_date": "2030-02-01",
        })
        assert response.status_code == 201
        assert response.get_json()["appointment"]["id"] == expected_id


@pytest.mark.parametrize("payload", [
    {},
    {"patient_name": SYNTHETIC_PATIENT, "appointment_date": "2030-01-15"},
    {"doctor_id": 1, "appointment_date": "2030-01-15"},
    {"doctor_id": 1, "patient_name": SYNTHETIC_PATIENT},
    {"doctor_id": "1", "patient_name": SYNTHETIC_PATIENT, "appointment_date": "2030-01-15"},
    {"doctor_id": True, "patient_name": SYNTHETIC_PATIENT, "appointment_date": "2030-01-15"},
    {"doctor_id": 0, "patient_name": SYNTHETIC_PATIENT, "appointment_date": "2030-01-15"},
    {"doctor_id": 1, "patient_name": "   ", "appointment_date": "2030-01-15"},
    {"doctor_id": 1, "patient_name": 123, "appointment_date": "2030-01-15"},
    {"doctor_id": 1, "patient_name": "x" * 101, "appointment_date": "2030-01-15"},
    {"doctor_id": 1, "patient_name": SYNTHETIC_PATIENT, "appointment_date": "tomorrow"},
    {"doctor_id": 1, "patient_name": SYNTHETIC_PATIENT, "appointment_date": "2030-02-30"},
    {"doctor_id": 1, "patient_name": SYNTHETIC_PATIENT, "appointment_date": 20300115},
])
def test_invalid_appointment_rejected_with_400(client, payload):
    response = client.post("/api/appointments", json=payload)
    assert response.status_code == 400
    assert "error" in response.get_json()
    assert client.get("/api/appointments").get_json() == []


def test_non_json_body_rejected_with_400(client):
    response = client.post("/api/appointments", data="not json", content_type="text/plain")
    assert response.status_code == 400


def test_json_array_body_rejected_with_400(client):
    response = client.post("/api/appointments", json=[1, 2, 3])
    assert response.status_code == 400


def test_unknown_doctor_returns_404(client):
    response = client.post("/api/appointments", json={
        "doctor_id": 999,
        "patient_name": SYNTHETIC_PATIENT,
        "appointment_date": "2030-01-15",
    })
    assert response.status_code == 404
    assert response.get_json() == {"error": "Doctor not found"}


# ---- Activity 9: security hardening (DAST / SAST findings) -------------------

@pytest.mark.parametrize("path", ["/", "/health", "/version", "/api/deployment", "/api/doctors", "/api/appointments"])
def test_security_headers_present(client, path):
    response = client.get(path)
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["Content-Security-Policy"] == "default-src 'none'; frame-ancestors 'none'"
    assert response.headers["X-Frame-Options"] == "DENY"
    assert response.headers["Referrer-Policy"] == "no-referrer"
    assert response.headers["Cache-Control"] == "no-store"


def test_unknown_route_returns_json_404_without_reflection(client):
    response = client.get("/does-not-exist/<script>alert(1)</script>")
    assert response.status_code == 404
    assert response.mimetype == "application/json"
    assert response.get_json() == {"error": "Not Found", "status": 404}
    assert b"<script>" not in response.data
    assert response.headers["X-Content-Type-Options"] == "nosniff"


def test_wrong_method_returns_json_405(client):
    response = client.delete("/api/doctors")
    assert response.status_code == 405
    assert response.mimetype == "application/json"
    assert response.get_json()["status"] == 405


def test_unexpected_errors_do_not_leak_details(client, monkeypatch):
    def boom():
        raise RuntimeError("internal secret detail")

    monkeypatch.setitem(app_module.app.view_functions, "get_doctors", boom)
    app_module.app.config.update(PROPAGATE_EXCEPTIONS=False)
    try:
        response = client.get("/api/doctors")
    finally:
        app_module.app.config.update(PROPAGATE_EXCEPTIONS=None)
    assert response.status_code == 500
    assert response.get_json() == {"error": "Internal Server Error", "status": 500}
    assert b"internal secret detail" not in response.data


# ---- Frontend and deployment banner -------------------------------------------

BROWSER_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"


def test_browser_gets_html_frontend(client):
    response = client.get("/", headers={"Accept": BROWSER_ACCEPT})
    assert response.status_code == 200
    assert response.mimetype == "text/html"
    page = response.get_data(as_text=True)
    assert "Healthcare Appointment Desk" in page
    assert "synthetic data only" in page
    assert "/static/js/app.js" in page and "/static/css/app.css" in page


def test_html_csp_allows_only_same_origin_and_no_inline(client):
    csp = client.get("/", headers={"Accept": BROWSER_ACCEPT}).headers["Content-Security-Policy"]
    assert "script-src 'self'" in csp and "style-src 'self'" in csp
    assert "frame-ancestors 'none'" in csp
    assert "unsafe-inline" not in csp and "unsafe-eval" not in csp and "*" not in csp


@pytest.mark.parametrize("accept", [None, "application/json", "*/*"])
def test_api_clients_still_get_json_metadata(client, accept):
    headers = {"Accept": accept} if accept else {}
    response = client.get("/", headers=headers)
    assert response.mimetype == "application/json"
    assert "/api/deployment" in response.get_json()["endpoints"]
    assert response.headers["Content-Security-Policy"] == "default-src 'none'; frame-ancestors 'none'"


def test_deployment_endpoint_reports_environment_version_and_pod(client):
    response = client.get("/api/deployment")
    assert response.status_code == 200
    body = response.get_json()
    assert body["version"] == app_module.APP_VERSION
    assert body["environment"] == app_module.DEPLOY_ENVIRONMENT
    assert body["pod"]
    assert body["served_at"].endswith("+00:00")


def test_deployment_environment_comes_from_kubernetes_label_env(monkeypatch):
    import importlib

    monkeypatch.setenv("DEPLOY_ENVIRONMENT", "green")
    monkeypatch.setenv("POD_NAME", "healthcare-green-abc12")
    reloaded = importlib.reload(app_module)
    try:
        with reloaded.app.test_client() as test_client:
            body = test_client.get("/api/deployment").get_json()
        assert body["environment"] == "green" and body["pod"] == "healthcare-green-abc12"
    finally:
        monkeypatch.delenv("DEPLOY_ENVIRONMENT")
        monkeypatch.delenv("POD_NAME")
        importlib.reload(app_module)


@pytest.mark.parametrize("path, mimetype", [("/static/js/app.js", "text/javascript"), ("/static/css/app.css", "text/css")])
def test_static_assets_served(client, path, mimetype):
    response = client.get(path)
    assert response.status_code == 200
    assert response.mimetype == mimetype
    response.close()


def test_frontend_never_renders_data_with_innerhtml():
    # Patient names are user input: the UI must only use textContent.
    script = (pathlib.Path(app_module.__file__).parent / "static" / "js" / "app.js").read_text(encoding="utf-8")
    assert "innerHTML" not in script and "outerHTML" not in script and "insertAdjacentHTML" not in script
    assert "eval(" not in script


@pytest.mark.parametrize("env, word", [("blue", "Blue"), ("green", "Green"), ("rolling", "Rolling")])
def test_page_says_which_environment_it_is_on(monkeypatch, env, word):
    import importlib

    monkeypatch.setenv("DEPLOY_ENVIRONMENT", env)
    reloaded = importlib.reload(app_module)
    try:
        with reloaded.app.test_client() as test_client:
            page = test_client.get("/", headers={"Accept": BROWSER_ACCEPT}).get_data(as_text=True)
        assert f'You are on <strong id="env-word">{word}</strong> environment' in page
        assert f'data-env="{env}"' in page
    finally:
        monkeypatch.delenv("DEPLOY_ENVIRONMENT")
        importlib.reload(app_module)
