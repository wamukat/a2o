"""Python service reference product."""

from .appointments import Appointment, next_open_slot, summarize_appointments

__all__ = ["Appointment", "next_open_slot", "summarize_appointments"]
