from datetime import datetime
import unittest

from a2o_reference_service.appointments import Appointment, next_open_slot, summarize_appointments


class AppointmentTests(unittest.TestCase):
    def test_summary_counts_open_and_booked_slots(self) -> None:
        appointments = [
            Appointment("a", "A", datetime(2026, 5, 1, 9, 0), "booked"),
            Appointment("b", "B", datetime(2026, 5, 1, 10, 0), "open"),
        ]

        self.assertEqual(summarize_appointments(appointments), {"total": 2, "booked": 1, "open": 1})

    def test_next_open_slot_uses_earliest_open_appointment(self) -> None:
        appointments = [
            Appointment("later", "B", datetime(2026, 5, 1, 11, 0), "open"),
            Appointment("earlier", "A", datetime(2026, 5, 1, 10, 0), "open"),
        ]

        self.assertEqual(next_open_slot(appointments).appointment_id, "earlier")


if __name__ == "__main__":
    unittest.main()
