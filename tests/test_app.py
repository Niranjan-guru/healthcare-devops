"""Functional tests for the synthetic healthcare appointment API."""
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
        "/health", "/version", "/api/doctors", "/api/appointments"
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
