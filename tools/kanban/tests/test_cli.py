import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
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

    def test_task_create_description_file_returns_parseable_json_with_multiline_description(self) -> None:
        description = "## Scope\n\n- line 1\n- line 2\n"
        board_shell = {
            "board": {"id": 42, "name": "Sample"},
            "lanes": [{"id": 7, "name": "To do", "position": 0}],
        }
        calls: list[tuple[str, str, dict[str, object] | None]] = []

        def fake_rest_request(_base_url, _token, method, path, *, payload=None):
            calls.append((method, path, payload))
            if method == "GET" and path == "/api/boards":
                return {"boards": [{"id": 42, "name": "Sample"}]}
            if method == "GET" and path == "/api/boards/42":
                return board_shell
            if method == "POST" and path == "/api/boards/42/tickets":
                self.assertEqual(description, payload["bodyMarkdown"])
                return {
                    "id": 101,
                    "boardId": 42,
                    "laneId": 7,
                    "title": payload["title"],
                    "isResolved": False,
                    "position": 0,
                    "ref": "Sample#101",
                    "shortRef": "#101",
                }
            raise AssertionError(f"unexpected request: {method} {path}")

        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(description)
            description_path = handle.name
        try:
            args = SimpleNamespace(
                backend="soloboard",
                base_url="http://localhost:3460",
                token="",
                project_id=None,
                project="Sample",
                title="Multiline task",
                description=None,
                description_file=description_path,
                status=None,
            )
            stdout = io.StringIO()
            with patch.object(kanban_cli, "rest_request", side_effect=fake_rest_request), contextlib.redirect_stdout(stdout):
                self.assertEqual(0, kanban_cli.cmd_task_create(args))
        finally:
            os.unlink(description_path)

        payload = json.loads(stdout.getvalue())
        self.assertEqual(101, payload["id"])
        self.assertEqual("Sample#101", payload["ref"])
        self.assertEqual(description, payload["description"])
        self.assertEqual(("POST", "/api/boards/42/tickets"), calls[-1][:2])

    def test_update_task_backfills_description_when_backend_omits_body_markdown(self) -> None:
        description = "## Updated\n\n- line 1\n- line 2\n"
        board_shell = {
            "board": {"id": 42, "name": "Sample"},
            "lanes": [{"id": 7, "name": "To do", "position": 0}],
        }

        def fake_rest_request(_base_url, _token, method, path, *, payload=None):
            if method == "PATCH" and path == "/api/tickets/101":
                self.assertEqual(description, payload["bodyMarkdown"])
                return {
                    "id": 101,
                    "boardId": 42,
                    "laneId": 7,
                    "title": "Task",
                    "isResolved": False,
                    "ref": "Sample#101",
                    "shortRef": "#101",
                }
            if method == "GET" and path == "/api/boards":
                return {"boards": [{"id": 42, "name": "Sample"}]}
            if method == "GET" and path == "/api/boards/42":
                return board_shell
            raise AssertionError(f"unexpected request: {method} {path}")

        with patch.object(kanban_cli, "rest_request", side_effect=fake_rest_request):
            updated = kanban_cli.update_task(
                "http://localhost:3460",
                "",
                101,
                {"description": description},
            )

        self.assertEqual(description, updated["description"])

    def test_task_update_description_file_and_append_description_file_preserve_multiline_text(self) -> None:
        existing = "Existing body"
        replacement = "## Replacement\n\n- one\n- two\n"
        appendix = "## Appendix\n\nextra detail"
        updates: list[dict[str, object]] = []

        def fake_resolve_task_id(*_args, **_kwargs):
            return 101

        def fake_get_task(_base_url, _token, task_id):
            self.assertEqual(101, task_id)
            return {
                "id": 101,
                "project_id": 42,
                "column_id": 7,
                "priority": 0,
                "done": False,
                "reference": "Sample#101",
                "identifier": "#101",
                "index": 101,
                "title": "Task",
                "description": existing,
            }

        def fake_update_task(_base_url, _token, task_id, changes):
            self.assertEqual(101, task_id)
            updates.append(changes)
            return {
                "id": 101,
                "project_id": 42,
                "column_id": 7,
                "priority": 0,
                "done": False,
                "reference": "Sample#101",
                "identifier": "#101",
                "index": 101,
                "title": "Task",
                "description": changes["description"],
            }

        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as replace_file:
            replace_file.write(replacement)
            replace_path = replace_file.name
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as append_file:
            append_file.write(appendix)
            append_path = append_file.name
        try:
            base_args = {
                "backend": "soloboard",
                "base_url": "http://localhost:3460",
                "token": "",
                "task": "Sample#101",
                "task_id": None,
                "project_id": None,
                "project": "Sample",
                "title": None,
                "description": None,
                "append_description": None,
                "reference": None,
                "done": None,
                "priority": None,
            }
            with (
                patch.object(kanban_cli, "resolve_task_id_from_ref", side_effect=fake_resolve_task_id),
                patch.object(kanban_cli, "get_task", side_effect=fake_get_task),
                patch.object(kanban_cli, "update_task", side_effect=fake_update_task),
                patch.object(kanban_cli, "resolve_project_title", return_value="Sample"),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                replace_args = SimpleNamespace(
                    **base_args,
                    description_file=replace_path,
                    append_description_file=None,
                )
                self.assertEqual(0, kanban_cli.cmd_task_update(replace_args))

                append_args = SimpleNamespace(
                    **base_args,
                    description_file=None,
                    append_description_file=append_path,
                )
                self.assertEqual(0, kanban_cli.cmd_task_update(append_args))
        finally:
            os.unlink(replace_path)
            os.unlink(append_path)

        self.assertEqual(replacement, updates[0]["description"])
        self.assertEqual(f"{existing}\n{appendix}", updates[1]["description"])

    def test_task_snapshot_uses_full_description_and_summary_from_detail(self) -> None:
        description = "Heading\n\nfirst line\nsecond line"

        with (
            patch.object(kanban_cli, "relation_tasks_payload", return_value={}),
            patch.object(
                kanban_cli,
                "get_task",
                return_value={
                    "id": 101,
                    "project_id": 42,
                    "column_id": 7,
                    "priority": 0,
                    "done": False,
                    "reference": "Sample#101",
                    "identifier": "#101",
                    "index": 101,
                    "title": "Snapshot task",
                    "description": description,
                    "tags": [{"id": 1, "name": "trigger:auto-implement"}],
                },
            ),
        ):
            snapshot = kanban_cli.normalize_task_snapshot(
                "http://localhost:3460",
                "",
                {
                    "id": 101,
                    "project_id": 42,
                    "column_id": 7,
                    "priority": 0,
                    "done": False,
                    "reference": "Sample#101",
                    "identifier": "#101",
                    "index": 101,
                    "title": "Snapshot task",
                    "description": "stale list payload",
                    "status": "To do",
                },
                project_title="Sample",
                project_titles_by_id={42: "Sample"},
            )

        self.assertEqual(description, snapshot["description"])
        self.assertEqual("Heading first line second line", snapshot["description_summary"])
        self.assertEqual(["trigger:auto-implement"], snapshot["labels"])

    def test_task_transition_done_does_not_resolve_without_sync_flag(self) -> None:
        board_shell = {
            "board": {"id": 42, "name": "Sample"},
            "lanes": [{"id": 9, "name": "Done", "position": 6}],
        }
        patch_payloads: list[dict[str, object]] = []

        def fake_rest_request(_base_url, _token, method, path, *, payload=None):
            if method == "GET" and path == "/api/tickets/101":
                return {"id": 101, "boardId": 42, "laneId": 1, "title": "Task", "isResolved": False}
            if method == "PATCH" and path == "/api/tickets/101/transition":
                patch_payloads.append(payload)
                return {
                    "id": 101,
                    "boardId": 42,
                    "laneId": 9,
                    "title": "Task",
                    "isResolved": False,
                    "ref": "Sample#101",
                    "shortRef": "#101",
                }
            if method == "GET" and path == "/api/boards/42":
                return board_shell
            if method == "GET" and path == "/api/tickets/101/relations":
                return {}
            raise AssertionError(f"unexpected request: {method} {path}")

        with patch.object(kanban_cli, "rest_request", side_effect=fake_rest_request):
            result = kanban_cli.transition_task_status(
                "http://localhost:3460",
                "",
                task_id=101,
                status="Done",
                sync_done_state=False,
            )

        self.assertEqual([{"laneName": "Done"}], patch_payloads)
        self.assertEqual("Done", result["status"])
        self.assertFalse(result["done"])


if __name__ == "__main__":
    unittest.main()
