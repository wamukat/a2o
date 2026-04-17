import contextlib
import io
import json
import os
import sys
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import Mock, patch


TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from kanban import kanban_cli


@contextmanager
def patched_env(values: dict[str, str | None]):
    original = {key: os.environ.get(key) for key in values}
    try:
        for key, value in values.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        yield
    finally:
        for key, value in original.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


class SoloBoardCliTest(unittest.TestCase):
    def test_resolve_backend_rejects_non_soloboard(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "Unsupported kanban backend"):
            kanban_cli.resolve_backend_kind("unsupported-backend")

    def test_resolve_base_url_uses_soloboard_default(self) -> None:
        with patched_env({"SOLOBOARD_BASE_URL": None, "KANBAN_BACKEND": None}):
            self.assertEqual("http://localhost:3000", kanban_cli.resolve_base_url(None))

    def test_resolve_base_url_uses_soloboard_env(self) -> None:
        with patched_env({"SOLOBOARD_BASE_URL": "http://localhost:3460/"}):
            self.assertEqual("http://localhost:3460", kanban_cli.resolve_base_url(None))

    def test_resolve_token_allows_empty_soloboard_token(self) -> None:
        with patched_env({"SOLOBOARD_API_TOKEN": None}):
            self.assertEqual("", kanban_cli.resolve_token(None))

    def test_rest_request_sends_patch_payload(self) -> None:
        response = Mock()
        response.status = 200
        response.read.return_value = json.dumps({"id": 1, "title": "Updated"}).encode("utf-8")
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)

        with patch("urllib.request.urlopen", return_value=response) as mock_urlopen:
            result = kanban_cli.rest_request(
                "http://localhost:3460",
                "",
                "PATCH",
                "/api/tickets/1",
                payload={"title": "Updated"},
            )

        self.assertEqual({"id": 1, "title": "Updated"}, result)
        request = mock_urlopen.call_args.args[0]
        self.assertEqual("PATCH", request.get_method())
        self.assertEqual("application/json", request.headers["Content-type"])

    def test_task_ref_resolution_uses_soloboard_index(self) -> None:
        self.assertEqual(
            123,
            kanban_cli.resolve_task_id_from_ref(
                "http://localhost:3460",
                "",
                task_id=None,
                task_ref="A2O#123",
                project_id=None,
                project_title="A2O",
            ),
        )
        self.assertEqual(
            123,
            kanban_cli.resolve_task_id_from_ref(
                "http://localhost:3460",
                "",
                task_id=None,
                task_ref="#123",
                project_id=None,
                project_title="A2O",
            ),
        )

    def test_parser_backend_choice_is_soloboard_only(self) -> None:
        parser = kanban_cli.build_parser()
        args = parser.parse_args(["--backend", "soloboard", "task-get", "--task", "A2O#1"])
        self.assertEqual("soloboard", args.backend)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            parser.parse_args(["--backend", "unsupported-backend", "task-get", "--task", "A2O#1"])

    def test_parser_accepts_task_reorder_without_priority(self) -> None:
        parser = kanban_cli.build_parser()
        args = parser.parse_args(["task-reorder", "--task-id", "10", "--status", "To do", "--position", "0"])

        self.assertEqual(kanban_cli.cmd_task_reorder, args.func)
        self.assertEqual(10, args.task_id)
        self.assertEqual("To do", args.status)
        self.assertEqual(0, args.position)
        self.assertFalse(hasattr(args, "priority"))

    def test_build_reordered_ticket_items_moves_task_by_position(self) -> None:
        items = kanban_cli.build_reordered_ticket_items(
            [
                {"id": 1, "laneId": 10, "position": 0},
                {"id": 2, "laneId": 10, "position": 1},
                {"id": 3, "laneId": 20, "position": 0},
            ],
            task_id=2,
            target_lane_id=20,
            target_position=0,
            lane_ids=[10, 20],
        )

        self.assertEqual(
            [
                {"ticketId": 1, "laneId": 10, "position": 0},
                {"ticketId": 2, "laneId": 20, "position": 0},
                {"ticketId": 3, "laneId": 20, "position": 1},
            ],
            items,
        )

    def test_trace_log_writes_timestamped_jsonl(self) -> None:
        path = Path(".work/kanban/test-trace.log")
        if path.exists():
            path.unlink()
        with patched_env({"KANBAN_TRACE_LOG": str(path), "KANBAN_TRACE_ENABLED": "1"}):
            kanban_cli.trace_log("unit.test", value=1)

        line = path.read_text(encoding="utf-8").strip()
        payload = json.loads(line)
        self.assertEqual("unit.test", payload["event"])
        self.assertIn("ts", payload)
        self.assertEqual({"value": 1}, payload["payload"])
        path.unlink()

    def test_safe_text_arg_allows_multiline_adapter_input(self) -> None:
        kanban_cli.ensure_safe_text_arg(
            option_name="--description",
            value="line 1\nline 2",
            file_path=None,
        )


if __name__ == "__main__":
    unittest.main()
