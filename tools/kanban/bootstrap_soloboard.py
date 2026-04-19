#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from kanban import kanban_cli


DEFAULT_A2O_LANES = ["Backlog", "To do", "In progress", "In review", "Inspection", "Merging", "Done"]
DEFAULT_A2O_TAGS = [
    {"name": kanban_cli.DEFAULT_AUTOMATION_TRIGGER_LABEL},
    {"name": "trigger:auto-parent"},
    {"name": "blocked"},
]


def load_config(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return load_config_payload(payload, source=str(path))


def load_config_json(raw: str) -> list[dict[str, Any]]:
    payload = json.loads(raw)
    return load_config_payload(payload, source="--config-json")


def load_config_payload(payload: Any, *, source: str) -> list[dict[str, Any]]:
    boards = payload.get("boards") if isinstance(payload, dict) else None
    if not isinstance(boards, list):
        raise RuntimeError(f"bootstrap config must contain boards array: {source}")
    return boards


def ensure_board(base_url: str, token: str, board_name: str, lane_names: list[str]) -> dict[str, Any]:
    projects = kanban_cli.get_projects(base_url, token)
    exact = [project for project in projects if str(project.get("name") or project.get("title") or "") == board_name]
    if len(exact) == 1:
        return exact[0]
    if len(exact) > 1:
        raise RuntimeError(f"Board name is ambiguous: {board_name}")
    created = kanban_cli.rest_request(
        base_url,
        token,
        "POST",
        "/api/boards",
        payload={"name": board_name, "laneNames": lane_names},
    ).get("board")
    if not isinstance(created, dict):
        raise RuntimeError(f"Board creation was not observed: {board_name}")
    return created


def capture_print_json(callback) -> Any:
    payload_holder: dict[str, Any] = {}
    original_print_json = kanban_cli.print_json

    def fake_print_json(payload: Any) -> int:
        payload_holder["payload"] = payload
        return 0

    kanban_cli.print_json = fake_print_json
    try:
        callback()
    finally:
        kanban_cli.print_json = original_print_json
    return payload_holder["payload"]


def ensure_lanes(base_url: str, token: str, board_id: int, lane_names: list[str]) -> dict[str, Any]:
    args = argparse.Namespace(
        backend="soloboard",
        project_id=board_id,
        project=None,
        bucket=lane_names,
        base_url=base_url,
        token=token,
    )
    return json.loads(json.dumps(capture_print_json(lambda: kanban_cli.cmd_project_ensure_buckets(args))))


def ensure_tags(base_url: str, token: str, board_id: int, tags: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ensured: list[dict[str, Any]] = []
    for tag in tags:
        title = str(tag.get("name") or tag.get("title") or "").strip()
        if not title:
            raise RuntimeError("tag name is required")
        color = str(tag.get("color") or tag.get("hex_color") or "#888888")
        ensured.append(
            kanban_cli.ensure_label(
                base_url,
                token,
                project_id=board_id,
                title=title,
                hex_color=color,
            )
        )
    return [kanban_cli.normalize_label(tag) for tag in ensured]


def board_lanes(spec: dict[str, Any]) -> list[str]:
    lanes = spec.get("lanes")
    if lanes is None:
        return list(DEFAULT_A2O_LANES)
    return [str(lane) for lane in lanes]


def board_tags(spec: dict[str, Any]) -> list[dict[str, Any]]:
    explicit_tags = spec.get("tags") or []
    if not isinstance(explicit_tags, list):
        raise RuntimeError(f"board tags must be an array: {str(spec.get('name') or '').strip()}")
    merged: dict[str, dict[str, Any]] = {}
    for tag in DEFAULT_A2O_TAGS + explicit_tags:
        name = str(tag.get("name") or tag.get("title") or "").strip()
        if not name:
            raise RuntimeError("tag name is required")
        item = dict(tag)
        item["name"] = name
        merged[name] = item
    return list(merged.values())


def main() -> int:
    parser = argparse.ArgumentParser(description="Bootstrap SoloBoard boards, lanes, and tags from a project config.")
    config_group = parser.add_mutually_exclusive_group(required=True)
    config_group.add_argument("--config", type=Path)
    config_group.add_argument("--config-json")
    parser.add_argument("--base-url", default=None)
    parser.add_argument("--token", default=None)
    parser.add_argument("--board", dest="boards", action="append", default=[])
    args = parser.parse_args()

    context = kanban_cli.resolve_backend_context(backend="soloboard", base_url=args.base_url, token=args.token)
    selected = set(args.boards)
    specs = load_config(args.config) if args.config else load_config_json(args.config_json)
    specs_by_name = {str(spec.get("name") or ""): spec for spec in specs}
    if selected:
        unknown = sorted(selected - set(specs_by_name))
        if unknown:
            raise RuntimeError(f"Unknown board spec: {', '.join(unknown)}")
        specs = [specs_by_name[name] for name in specs_by_name if name in selected]

    result: list[dict[str, Any]] = []
    for spec in specs:
        board_name = str(spec.get("name") or "").strip()
        lane_names = board_lanes(spec)
        tags = board_tags(spec)
        if not board_name:
            raise RuntimeError("board name is required")
        if not lane_names:
            raise RuntimeError(f"board lanes are required: {board_name}")

        board = ensure_board(context.base_url, context.token, board_name, lane_names)
        board_id = int(board["id"])
        lanes = ensure_lanes(context.base_url, context.token, board_id, lane_names)
        ensured_tags = ensure_tags(context.base_url, context.token, board_id, tags)
        result.append(
            {
                "board": {"id": board_id, "name": board_name},
                "lanes": lanes["bucket_ids_by_name"],
                "tags": ensured_tags,
            }
        )

    print(json.dumps({"boards": result}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
