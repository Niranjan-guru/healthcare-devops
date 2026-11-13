"""Simulated healthcare appointment management service.

Academic demonstration application for a DevOps CI/CD project.
All data is synthetic and held in memory only; this is not production
healthcare software and must never be used with real patient data.
"""
import os
import threading
from datetime import date, datetime, timezone

from flask import Flask, jsonify, request

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "1.0.0")

MAX_PATIENT_NAME_LENGTH = 100

doctors = [
    {"id": 1, "name": "Dr.Arun Kumar", "specialty": "Cardiology"},
    {"id": 2, "name": "Dr.Priya Sharma", "specialty": "Dermatology"},
    {"id": 3, "name": "Dr.Rahul Mehta", "specialty": "Neurology"}
]

appointments = []
_appointments_lock = threading.Lock()


@app.route("/", methods=["GET"])
def home():
    return jsonify({
        "application": "Healthcare Appointment management",
        "version": APP_VERSION,
        "message": "Healthcare application is on run",
        "endpoints": [
            "/health",
            "/version",
            "/api/doctors",
            "/api/appointments"
        ]
    })


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "HEALTHY",
        "version": APP_VERSION
    }), 200


@app.route("/version", methods=["GET"])
def version():
    return jsonify({"version": APP_VERSION}), 200


@app.route("/api/doctors", methods=["GET"])
def get_doctors():
    return jsonify(doctors), 200


@app.route("/api/appointments", methods=["GET"])
def get_appointments():
    with _appointments_lock:
        return jsonify(list(appointments)), 200


def _validate_appointment(data):
    """Return an error message for an invalid payload, or None if valid."""
    doctor_id = data.get("doctor_id")
    patient_name = data.get("patient_name")
    appointment_date = data.get("appointment_date")

    if doctor_id is None or patient_name is None or appointment_date is None:
        return "doctor_id, patient_name and appointment_date are required"

    # bool is a subclass of int, so reject it explicitly.
    if not isinstance(doctor_id, int) or isinstance(doctor_id, bool) or doctor_id < 1:
        return "doctor_id must be a positive integer"

    if not isinstance(patient_name, str) or not patient_name.strip():
        return "patient_name must be a non-empty string"

    if len(patient_name.strip()) > MAX_PATIENT_NAME_LENGTH:
        return f"patient_name must be at most {MAX_PATIENT_NAME_LENGTH} characters"

    if not isinstance(appointment_date, str):
        return "appointment_date must be a string in YYYY-MM-DD format"
    try:
        date.fromisoformat(appointment_date)
    except ValueError:
        return "appointment_date must be a valid date in YYYY-MM-DD format"
    if len(appointment_date) != 10:
        return "appointment_date must be a valid date in YYYY-MM-DD format"

    return None


@app.route("/api/appointments", methods=["POST"])
def create_appointment():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Request body must be a JSON object"}), 400

    error = _validate_appointment(data)
    if error:
        return jsonify({"error": error}), 400

    doctor_id = data["doctor_id"]
    doctor = next((d for d in doctors if d["id"] == doctor_id), None)
    if doctor is None:
        return jsonify({"error": "Doctor not found"}), 404

    with _appointments_lock:
        appointment = {
            "id": len(appointments) + 1,
            "doctor": doctor["name"],
            "patient_name": data["patient_name"].strip(),
            "appointment_date": data["appointment_date"],
            "status": "scheduled",
            "created_at": datetime.now(timezone.utc).isoformat()
        }
        appointments.append(appointment)

    return jsonify({
        "message": "Appointment created successfully",
        "appointment": appointment
    }), 201


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
