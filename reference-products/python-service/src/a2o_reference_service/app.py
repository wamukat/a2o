import json
from http.server import BaseHTTPRequestHandler, HTTPServer

from .appointments import SEED_APPOINTMENTS, next_open_slot, summarize_appointments


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/health":
            self._json({"ok": True, "service": "python-service"})
            return
        if self.path == "/appointments":
            items = [
                appointment.__dict__ | {"starts_at": appointment.starts_at.isoformat()}
                for appointment in SEED_APPOINTMENTS
            ]
            self._json(
                {
                    "items": items,
                    "summary": summarize_appointments(SEED_APPOINTMENTS),
                }
            )
            return
        if self.path == "/next-open-slot":
            appointment = next_open_slot(SEED_APPOINTMENTS)
            self._json(
                {
                    "item": None
                    if appointment is None
                    else appointment.__dict__ | {"starts_at": appointment.starts_at.isoformat()}
                }
            )
            return
        self._json({"error": "not_found"}, status=404)

    def log_message(self, format: str, *args: object) -> None:
        return

    def _json(self, payload: object, status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    server = HTTPServer(("127.0.0.1", 4030), Handler)
    print("python-service listening on http://127.0.0.1:4030")
    server.serve_forever()


if __name__ == "__main__":
    main()
