import os
from datetime import datetime, timezone
from flask import Flask,jsonify,request

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "1.0.0")

doctors = [
    {"id": 1, "name": "Dr.Arun Kumar", "specialty": "Cardiology"},
    {"id": 2, "name": "Dr.Priya Sharma", "specialty": "Dermatology"},
    {"id": 3, "name": "Dr.Rahul Mehta", "specialty": "Neurology"}
]

appointments = []

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
    return jsonify(appointments), 200


@app.route("/api/appointments", methods=["POST"])
def create_appointment():
    data = request.get_json(silent=True) or {}

    doctor_id = data.get("doctor_id")
    patient_name = data.get("patient_name")
    appointment_date = data.get("appointment_date")

    if not doctor_id or not patient_name or not appointment_date:
        return jsonify({
            "error": "doctor_id, patient_name and appointment_date are required"
        }), 400

    doctor = next(
        (d for d in doctors if d["id"] == doctor_id),
        None
    )

    if doctor is None:
        return jsonify({"error": "Doctor not found"}), 404

    appointment = {
        "id": len(appointments) + 1,
        "doctor": doctor["name"],
        "patient_name": patient_name,
        "appointment_date": appointment_date,
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