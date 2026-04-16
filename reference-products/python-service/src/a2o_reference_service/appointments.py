from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True)
class Appointment:
    appointment_id: str
    customer: str
    starts_at: datetime
    status: str


SEED_APPOINTMENTS = [
    Appointment("apt-100", "Maple Dental", datetime(2026, 5, 1, 9, 0), "booked"),
    Appointment("apt-101", "River Clinic", datetime(2026, 5, 1, 10, 0), "open"),
    Appointment("apt-102", "Summit Care", datetime(2026, 5, 1, 11, 0), "booked"),
]


def summarize_appointments(appointments: list[Appointment]) -> dict[str, int]:
    summary = {"total": len(appointments), "booked": 0, "open": 0}
    for appointment in appointments:
        if appointment.status == "booked":
            summary["booked"] += 1
        if appointment.status == "open":
            summary["open"] += 1
    return summary


def next_open_slot(appointments: list[Appointment]) -> Appointment | None:
    open_slots = sorted(
        (appointment for appointment in appointments if appointment.status == "open"),
        key=lambda appointment: appointment.starts_at,
    )
    return open_slots[0] if open_slots else None
