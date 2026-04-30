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


class KanbaloneCliTest(unittest.TestCase):
    def test_normalize_task_watch_summary_preserves_parent_ref(self) -> None:
        task = {
            "id": 52,
            "ref": "A2O#52",
            "title": "Child task",
            "status": "To do",
        }

        with patch.object(
            kanban_cli,
            "relation_tasks_payload",
            return_value={"parenttask": [{"id": 51, "ref": "A2O#51"}]},
        ), patch.object(kanban_cli, "list_task_label_reasons", return_value=[]):
            normalized = kanban_cli.normalize_task_watch_summary(
                "http://localhost:3000",
                "",
                task,
                project_title="A2O",
            )

        self.assertEqual("A2O#51", normalized["parent_ref"])

    def test_normalize_task_watch_summary_preserves_archived_flag(self) -> None:
        task = {
            "id": 52,
            "ref": "A2O#52",
            "title": "Archived task",
            "status": "To do",
            "is_archived": True,
        }

        with (
            patch.object(kanban_cli, "relation_tasks_payload", return_value={"parenttask": []}),
            patch.object(kanban_cli, "list_task_label_reasons", return_value=[]),
        ):
            normalized = kanban_cli.normalize_task_watch_summary(
                "http://localhost:3000",
                "",
                task,
                project_title="A2O",
            )

        self.assertTrue(normalized["is_archived"])

    def test_task_watch_summary_list_excludes_archived_tasks(self) -> None:
        args = SimpleNamespace(
            backend="kanbalone",
            base_url="http://localhost:3460",
            token="",
            project_id=None,
            project="A2O",
            task_ids=[51, 52],
            tasks=[],
            ignore_missing=False,
        )

        def fake_get_task(_base_url, _token, task_id):
            return {
                "id": task_id,
                "project_id": 2,
                "column_id": 9,
                "ref": f"A2O#{task_id}",
                "reference": f"A2O#{task_id}",
                "title": "Archived" if task_id == 52 else "Active",
                "done": False,
                "is_archived": task_id == 52,
            }

        with (
            patch.object(kanban_cli, "get_task", side_effect=fake_get_task),
            patch.object(kanban_cli, "resolve_project_id", return_value=2),
            patch.object(kanban_cli, "resolve_project_title", return_value="A2O"),
            patch.object(kanban_cli, "get_columns", return_value=[{"id": 9, "title": "To do"}]),
            patch.object(kanban_cli, "relation_tasks_payload", return_value={"parenttask": []}),
            patch.object(kanban_cli, "list_task_label_reasons", return_value=[]),
            contextlib.redirect_stdout(io.StringIO()) as stdout,
        ):
            self.assertEqual(0, kanban_cli.cmd_task_watch_summary_list(args))

        payload = json.loads(stdout.getvalue())
        self.assertEqual(["A2O#51"], [item["ref"] for item in payload])

    def test_resolve_backend_rejects_unsupported_backend(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "Unsupported kanban backend"):
            kanban_cli.resolve_backend_kind("unsupported-backend")

    def test_resolve_backend_rejects_removed_soloboard_backend(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "migration_required=true replacement_backend=kanbalone"):
            kanban_cli.resolve_backend_kind("soloboard")

    def test_resolve_backend_defaults_to_kanbalone(self) -> None:
        with patched_env({"KANBAN_BACKEND": None}):
            self.assertEqual("kanbalone", kanban_cli.resolve_backend_kind(None))

    def test_resolve_base_url_uses_kanbalone_default(self) -> None:
        with patched_env({"KANBALONE_BASE_URL": None, "SOLOBOARD_BASE_URL": None, "KANBAN_BACKEND": None}):
            self.assertEqual("http://localhost:3000", kanban_cli.resolve_base_url(None))

    def test_resolve_base_url_uses_kanbalone_env(self) -> None:
        with patched_env({"KANBALONE_BASE_URL": "http://localhost:3470/", "SOLOBOARD_BASE_URL": "http://localhost:3460/"}):
            self.assertEqual("http://localhost:3470", kanban_cli.resolve_base_url(None))

    def test_resolve_base_url_rejects_soloboard_env_fallback(self) -> None:
        with patched_env({"KANBALONE_BASE_URL": None, "SOLOBOARD_BASE_URL": "http://localhost:3460/"}):
            with self.assertRaisesRegex(RuntimeError, "migration_required=true replacement_env=KANBALONE_BASE_URL"):
                kanban_cli.resolve_base_url(None)

    def test_resolve_token_allows_empty_kanbalone_token(self) -> None:
        with patched_env({"KANBALONE_API_TOKEN": None, "SOLOBOARD_API_TOKEN": None}):
            self.assertEqual("", kanban_cli.resolve_token(None))

    def test_resolve_token_uses_kanbalone_env(self) -> None:
        with patched_env({"KANBALONE_API_TOKEN": "public-token", "SOLOBOARD_API_TOKEN": "legacy-token"}):
            self.assertEqual("public-token", kanban_cli.resolve_token(None))

    def test_resolve_token_rejects_soloboard_env_fallback(self) -> None:
        with patched_env({"KANBALONE_API_TOKEN": None, "SOLOBOARD_API_TOKEN": "legacy-token"}):
            with self.assertRaisesRegex(RuntimeError, "migration_required=true replacement_env=KANBALONE_API_TOKEN"):
                kanban_cli.resolve_token(None)

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

    def test_add_task_label_uses_reasoned_tag_api_when_reason_is_present(self) -> None:
        with (
            patch.object(kanban_cli, "resolve_tag", return_value={"id": 12, "name": "blocked"}),
            patch.object(kanban_cli, "rest_request", return_value={"id": 12, "name": "blocked", "reason": "blocked by test"}) as request,
        ):
            result = kanban_cli.add_task_label(
                "http://localhost:3460",
                "",
                42,
                "blocked",
                reason="blocked by test",
                details={"resumeCondition": "clear blocker"},
            )

        self.assertEqual("blocked by test", result["reason"])
        request.assert_called_once_with(
            "http://localhost:3460",
            "",
            "POST",
            "/api/tickets/42/tags/12",
            payload={"reason": "blocked by test", "details": {"resumeCondition": "clear blocker"}},
        )

    def test_add_task_label_falls_back_to_tag_ids_when_reasoned_tag_api_is_absent(self) -> None:
        with (
            patch.object(kanban_cli, "resolve_tag", return_value={"id": 12, "name": "blocked"}),
            patch.object(kanban_cli, "rest_request", side_effect=RuntimeError(json.dumps({"statusCode": 404}))),
            patch.object(kanban_cli, "stable_task_label_titles", return_value=set()),
            patch.object(kanban_cli, "tag_name_for_ref", return_value="blocked"),
            patch.object(kanban_cli, "set_task_tags", return_value=True) as set_tags,
        ):
            result = kanban_cli.add_task_label(
                "http://localhost:3460",
                "",
                42,
                "blocked",
                reason="blocked by test",
            )

        self.assertFalse(result["reason_supported"])
        set_tags.assert_called_once_with("http://localhost:3460", "", task_id=42, names=["blocked"])

    def test_list_task_label_reasons_falls_back_to_plain_labels_when_api_is_absent(self) -> None:
        with (
            patch.object(kanban_cli, "rest_request", side_effect=RuntimeError(json.dumps({"statusCode": 404}))),
            patch.object(kanban_cli, "list_task_labels", return_value=[{"id": 12, "title": "blocked"}]),
        ):
            result = kanban_cli.list_task_label_reasons("http://localhost:3460", "", 42)

        self.assertEqual(
            [{"id": 12, "title": "blocked", "reason": None, "details": None, "reason_comment_id": None, "attached_at": None}],
            result,
        )

    def test_list_task_label_reasons_normalizes_nested_kanbalone_tag_shape(self) -> None:
        with patch.object(
            kanban_cli,
            "rest_request",
            return_value={
                "tags": [
                    {
                        "tag": {"id": 12, "name": "blocked", "color": "#cc3f3f"},
                        "reason": "blocked by test",
                        "details": {"resumeCondition": "clear blocker"},
                        "reasonCommentId": None,
                        "attachedAt": "2026-04-27T00:00:00Z",
                    }
                ]
            },
        ):
            result = kanban_cli.list_task_label_reasons("http://localhost:3460", "", 42)

        self.assertEqual(
            [
                {
                    "id": 12,
                    "title": "blocked",
                    "description": "",
                    "hex_color": "#cc3f3f",
                    "reason": "blocked by test",
                    "details": {"resumeCondition": "clear blocker"},
                    "reason_comment_id": None,
                    "attached_at": "2026-04-27T00:00:00Z",
                }
            ],
            result,
        )

    def test_task_get_includes_label_reason_metadata(self) -> None:
        args = SimpleNamespace(
            backend="kanbalone",
            base_url="http://localhost:3460",
            token="",
            task_id=42,
            task=None,
            project_id=None,
            project="A2O",
        )

        with (
            patch.object(
                kanban_cli,
                "get_task_with_status",
                return_value={
                    "id": 42,
                    "project_id": 2,
                    "reference": "A2O#42",
                    "identifier": "#42",
                    "index": 42,
                    "title": "Blocked task",
                    "done": False,
                },
            ),
            patch.object(kanban_cli, "resolve_project_title", return_value="A2O"),
            patch.object(
                kanban_cli,
                "list_task_label_reasons",
                return_value=[
                    {
                        "id": 12,
                        "title": "blocked",
                        "description": "",
                        "hex_color": "#cc3f3f",
                        "reason": "blocked by test",
                        "details": {"run_ref": "run-1"},
                        "reason_comment_id": None,
                        "attached_at": None,
                    }
                ],
            ),
            contextlib.redirect_stdout(io.StringIO()) as stdout,
        ):
            self.assertEqual(0, kanban_cli.cmd_task_get(args))

        payload = json.loads(stdout.getvalue())
        self.assertEqual("blocked by test", payload["label_reasons"][0]["reason"])

    def test_create_task_event_writes_structured_event_when_supported(self) -> None:
        with patch.object(
            kanban_cli,
            "rest_request",
            return_value={
                "id": 7,
                "ticketId": 42,
                "source": "a2o",
                "kind": "task_started",
                "title": "Task started",
                "summary": "Started implementation.",
                "severity": "info",
                "data": {"run_ref": "run-1"},
                "createdAt": "2026-04-27T00:00:00Z",
            },
        ) as request:
            result = kanban_cli.create_task_event(
                "http://localhost:3460",
                "",
                42,
                source="a2o",
                kind="task_started",
                title="Task started",
                summary="Started implementation.",
                data={"run_ref": "run-1"},
            )

        self.assertEqual("task_started", result["kind"])
        self.assertEqual({"run_ref": "run-1"}, result["data"])
        request.assert_called_once_with(
            "http://localhost:3460",
            "",
            "POST",
            "/api/tickets/42/events",
            payload={
                "source": "a2o",
                "kind": "task_started",
                "title": "Task started",
                "summary": "Started implementation.",
                "severity": "info",
                "data": {"run_ref": "run-1"},
            },
        )

    def test_create_task_event_falls_back_to_comment_when_api_is_absent(self) -> None:
        with (
            patch.object(kanban_cli, "rest_request", side_effect=RuntimeError(json.dumps({"statusCode": 404}))),
            patch.object(kanban_cli, "create_task_comment", return_value={"id": 9, "bodyMarkdown": "Started implementation."}),
        ):
            result = kanban_cli.create_task_event(
                "http://localhost:3460",
                "",
                42,
                source="a2o",
                kind="task_started",
                title="Task started",
                summary="Started implementation.",
                fallback_comment="Started implementation.",
            )

        self.assertEqual("comment", result["fallback"])
        self.assertEqual("Started implementation.", result["comment"]["comment"])

    def test_list_task_events_returns_empty_list_when_api_is_absent(self) -> None:
        with patch.object(kanban_cli, "rest_request", side_effect=RuntimeError(json.dumps({"statusCode": 404}))):
            self.assertEqual([], kanban_cli.list_task_events("http://localhost:3460", "", 42))

    def test_parser_accepts_reasoned_label_and_event_commands(self) -> None:
        parser = kanban_cli.build_parser()
        label_args = parser.parse_args(
            [
                "task-label-add",
                "--task-id",
                "42",
                "--label",
                "blocked",
                "--reason",
                "blocked by test",
                "--details-json",
                '{"resumeCondition":"clear blocker"}',
            ]
        )
        event_args = parser.parse_args(
            [
                "task-event-create",
                "--task-id",
                "42",
                "--source",
                "a2o",
                "--kind",
                "task_started",
                "--title",
                "Task started",
                "--summary",
                "Started implementation.",
            ]
        )

        self.assertEqual(kanban_cli.cmd_task_label_add, label_args.func)
        self.assertEqual(kanban_cli.cmd_task_event_create, event_args.func)

    def test_task_ref_resolution_uses_kanbalone_short_ref_index(self) -> None:
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

    def test_parser_accepts_removed_soloboard_backend_for_migration_diagnostic(self) -> None:
        parser = kanban_cli.build_parser()
        args = parser.parse_args(["--backend", "kanbalone", "task-get", "--task", "A2O#1"])
        self.assertEqual("kanbalone", args.backend)
        args = parser.parse_args(["--backend", "soloboard", "task-get", "--task", "A2O#1"])
        self.assertEqual("soloboard", args.backend)

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
                self.assertEqual(2, payload["priority"])
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
                backend="kanbalone",
                base_url="http://localhost:3460",
                token="",
                project_id=None,
                project="Sample",
                title="Multiline task",
                description=None,
                description_file=description_path,
                status=None,
                priority=None,
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

    def test_task_create_preserves_explicit_priority_override(self) -> None:
        board_shell = {
            "board": {"id": 42, "name": "Sample"},
            "lanes": [{"id": 7, "name": "To do", "position": 0}],
        }

        def fake_rest_request(_base_url, _token, method, path, *, payload=None):
            if method == "GET" and path == "/api/boards":
                return {"boards": [{"id": 42, "name": "Sample"}]}
            if method == "GET" and path == "/api/boards/42":
                return board_shell
            if method == "POST" and path == "/api/boards/42/tickets":
                self.assertEqual(4, payload["priority"])
                return {
                    "id": 102,
                    "boardId": 42,
                    "laneId": 7,
                    "title": payload["title"],
                    "isResolved": False,
                    "position": 0,
                    "ref": "Sample#102",
                    "shortRef": "#102",
                }
            raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(
            backend="kanbalone",
            base_url="http://localhost:3460",
            token="",
            project_id=None,
            project="Sample",
            title="Explicit priority task",
            description="body",
            description_file=None,
            status=None,
            priority=4,
        )
        stdout = io.StringIO()
        with patch.object(kanban_cli, "rest_request", side_effect=fake_rest_request), contextlib.redirect_stdout(stdout):
            self.assertEqual(0, kanban_cli.cmd_task_create(args))

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
                "backend": "kanbalone",
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

    def test_task_update_preserves_description_output_when_done_refresh_omits_body(self) -> None:
        replacement = "Updated with done\n\n- keep me"
        get_task_calls = 0

        def fake_resolve_task_id(*_args, **_kwargs):
            return 101

        def fake_get_task(_base_url, _token, task_id):
            nonlocal get_task_calls
            get_task_calls += 1
            self.assertEqual(101, task_id)
            body = "Existing" if get_task_calls == 1 else ""
            return {
                "id": 101,
                "project_id": 42,
                "column_id": 7,
                "priority": 0,
                "done": get_task_calls > 1,
                "reference": "Sample#101",
                "identifier": "#101",
                "index": 101,
                "title": "Task",
                "description": body,
            }

        def fake_update_task(_base_url, _token, task_id, changes):
            self.assertEqual({"description": replacement, "done": True}, changes)
            return {
                "id": task_id,
                "project_id": 42,
                "description": replacement,
            }

        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as replace_file:
            replace_file.write(replacement)
            replace_path = replace_file.name
        try:
            args = SimpleNamespace(
                backend="kanbalone",
                base_url="http://localhost:3460",
                token="",
                task="Sample#101",
                task_id=None,
                project_id=None,
                project="Sample",
                title=None,
                description=None,
                description_file=replace_path,
                append_description=None,
                append_description_file=None,
                reference=None,
                done=True,
                priority=None,
            )
            stdout = io.StringIO()
            with (
                patch.object(kanban_cli, "resolve_task_id_from_ref", side_effect=fake_resolve_task_id),
                patch.object(kanban_cli, "get_task", side_effect=fake_get_task),
                patch.object(kanban_cli, "update_task", side_effect=fake_update_task),
                patch.object(kanban_cli, "resolve_project_title", return_value="Sample"),
                contextlib.redirect_stdout(stdout),
            ):
                self.assertEqual(0, kanban_cli.cmd_task_update(args))
        finally:
            os.unlink(replace_path)

        payload = json.loads(stdout.getvalue())
        self.assertEqual(replacement, payload["description"])
        self.assertTrue(payload["done"])

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
            patch.object(
                kanban_cli,
                "list_task_label_reasons",
                return_value=[
                    {
                        "id": 2,
                        "title": "blocked",
                        "description": "",
                        "hex_color": "#cc3f3f",
                        "reason": "blocked by test",
                        "details": {"run_ref": "run-1"},
                        "reason_comment_id": None,
                        "attached_at": "2026-04-27T00:00:00Z",
                    }
                ],
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
        self.assertEqual("detail", snapshot["description_source"])
        self.assertEqual(["trigger:auto-implement"], snapshot["labels"])
        self.assertEqual("blocked by test", snapshot["label_reasons"][0]["reason"])

    def test_task_snapshot_falls_back_to_list_description_when_detail_omits_body(self) -> None:
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
                    "description": "",
                    "tags": [{"id": 1, "name": "trigger:auto-implement"}],
                },
            ),
            patch.object(kanban_cli, "list_task_label_reasons", return_value=[]),
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
                    "description": "list body",
                    "status": "To do",
                },
                project_title="Sample",
                project_titles_by_id={42: "Sample"},
            )

        self.assertEqual("list body", snapshot["description"])
        self.assertEqual("list", snapshot["description_source"])
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

    def test_relation_tasks_payload_includes_related_relations(self) -> None:
        def fake_rest_request(_base_url, _token, method, path, *, payload=None):
            self.assertEqual("GET", method)
            self.assertEqual("/api/tickets/101/relations", path)
            return {
                "parent": None,
                "children": [],
                "blockers": [],
                "blockedBy": [],
                "related": [{"id": 202, "ref": "Sample#202"}],
            }

        with patch.object(kanban_cli, "rest_request", side_effect=fake_rest_request):
            payload = kanban_cli.relation_tasks_payload("http://localhost:3460", "", task_id=101)

        self.assertEqual([{"id": 202, "ref": "Sample#202"}], payload["related"])

    def test_create_related_relation_updates_related_ids(self) -> None:
        patch_payloads: list[dict[str, object]] = []

        def fake_rest_request(_base_url, _token, method, path, *, payload=None):
            if method == "GET" and path == "/api/tickets/101":
                return {"id": 101, "relatedIds": [201]}
            if method == "PATCH" and path == "/api/tickets/101":
                patch_payloads.append(payload)
                return {"id": 101, "relatedIds": payload["relatedIds"]}
            raise AssertionError(f"unexpected request: {method} {path}")

        with patch.object(kanban_cli, "rest_request", side_effect=fake_rest_request):
            result = kanban_cli.create_relation(
                "http://localhost:3460",
                "",
                task_id=101,
                other_task_id=202,
                relation_kind="related",
            )

        self.assertEqual({"id": 101}, result)
        self.assertEqual([{"relatedIds": [201, 202]}], patch_payloads)

    def test_delete_related_relation_updates_related_ids(self) -> None:
        patch_payloads: list[dict[str, object]] = []

        def fake_rest_request(_base_url, _token, method, path, *, payload=None):
            if method == "GET" and path == "/api/tickets/101":
                return {"id": 101, "relatedIds": [201, 202]}
            if method == "PATCH" and path == "/api/tickets/101":
                patch_payloads.append(payload)
                return {"id": 101, "relatedIds": payload["relatedIds"]}
            raise AssertionError(f"unexpected request: {method} {path}")

        with patch.object(kanban_cli, "rest_request", side_effect=fake_rest_request):
            result = kanban_cli.delete_relation(
                "http://localhost:3460",
                "",
                task_id=101,
                other_task_id=202,
                relation_kind="related",
            )

        self.assertEqual({"result": True}, result)
        self.assertEqual([{"relatedIds": [201]}], patch_payloads)


if __name__ == "__main__":
    unittest.main()
