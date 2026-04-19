#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from datetime import datetime, timezone

DEFAULT_PROJECT_TITLE = "A2O"
DEFAULT_AUTOMATION_TRIGGER_LABEL = "trigger:auto-implement"
DEFAULT_LOCK_RETRY_COUNT = 8
DEFAULT_LOCK_RETRY_DELAY_SECONDS = 0.25
RELATION_KIND_CHOICES = [
    "subtask",
    "parenttask",
    "related",
    "duplicateof",
    "duplicates",
    "blocking",
    "blocked",
]
RELATION_KIND_TO_LABEL = {
    "subtask": "is a parent of",
    "parenttask": "is a child of",
    "blocking": "blocks",
    "blocked": "is blocked by",
    "related": "relates to",
    "duplicates": "duplicates",
    "duplicateof": "is duplicated by",
}
LABEL_TO_RELATION_KIND = {label: kind for kind, label in RELATION_KIND_TO_LABEL.items()}
DEFAULT_TRACE_LOG_PATH = Path(".work/kanban/trace.log")
SUPPORTED_BACKENDS = ("soloboard",)


@dataclass(frozen=True)
class BackendContext:
    kind: str
    base_url: str
    token: str


def trace_enabled() -> bool:
    value = str(os.environ.get("KANBAN_TRACE_ENABLED", "1")).strip().lower()
    return value not in {"0", "false", "off", "no"}


def trace_log_path() -> Path:
    raw = str(os.environ.get("KANBAN_TRACE_LOG", "")).strip()
    if raw:
        return Path(raw)
    return DEFAULT_TRACE_LOG_PATH


def trace_log(event: str, **payload: Any) -> None:
    if not trace_enabled():
        return
    path = trace_log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    {
                        "ts": datetime.now(timezone.utc).isoformat(timespec="microseconds"),
                        "pid": os.getpid(),
                        "event": event,
                        "payload": payload,
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
    except OSError:
        return


def resolve_backend_kind(cli_value: str | None) -> str:
    value = str(cli_value or os.environ.get("KANBAN_BACKEND") or "soloboard").strip().lower()
    if value not in SUPPORTED_BACKENDS:
        raise RuntimeError(f"Unsupported kanban backend: {value}. Supported: {', '.join(SUPPORTED_BACKENDS)}")
    return value


def resolve_base_url(cli_value: str | None, *, backend_kind: str = "soloboard") -> str:
    if backend_kind != "soloboard":
        raise RuntimeError(f"Unsupported kanban backend: {backend_kind}")
    return (
        cli_value
        or os.environ.get("SOLOBOARD_BASE_URL")
        or "http://localhost:3000"
    ).rstrip("/")


def resolve_token(cli_value: str | None, *, backend_kind: str = "soloboard") -> str:
    if backend_kind != "soloboard":
        raise RuntimeError(f"Unsupported kanban backend: {backend_kind}")
    return cli_value or os.environ.get("SOLOBOARD_API_TOKEN") or ""


def resolve_backend_context(*, backend: str | None, base_url: str | None, token: str | None) -> BackendContext:
    backend_kind = resolve_backend_kind(backend)
    return BackendContext(
        kind=backend_kind,
        base_url=resolve_base_url(base_url, backend_kind=backend_kind),
        token=resolve_token(token, backend_kind=backend_kind),
    )


def api_request(
    base_url: str,
    token: str,
    method: str,
    path: str,
    *,
    payload: dict[str, Any] | None = None,
) -> Any:
    return rest_request(base_url, token, method, path, payload=payload)


def rest_request(
    base_url: str,
    token: str,
    method: str,
    path: str,
    *,
    payload: dict[str, Any] | None = None,
) -> Any:
    request_started_at = time.time()
    url = f"{base_url.rstrip('/')}{path}"
    headers = {
        "Accept": "application/json",
        "User-Agent": "mypage-prototype-kanban-cli/1.0",
    }
    body: bytes | None = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode("utf-8")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    trace_log("rest.request.start", method=method, path=path)
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            status = int(getattr(response, "status", 200))
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        message = raw.decode("utf-8", errors="replace")
        trace_log(
            "rest.request.error",
            method=method,
            path=path,
            status=int(exc.code),
            elapsed_ms=round((time.time() - request_started_at) * 1000, 3),
            error=message,
        )
        raise RuntimeError(message or f"HTTP {exc.code} {path}") from exc
    except Exception as exc:
        trace_log(
            "rest.request.exception",
            method=method,
            path=path,
            elapsed_ms=round((time.time() - request_started_at) * 1000, 3),
            error=repr(exc),
        )
        raise
    if not raw:
        trace_log(
            "rest.request.finish",
            method=method,
            path=path,
            status=status,
            elapsed_ms=round((time.time() - request_started_at) * 1000, 3),
        )
        return None
    try:
        decoded = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Unexpected non-JSON response from REST API: {path}") from exc
    trace_log(
        "rest.request.finish",
        method=method,
        path=path,
        status=status,
        elapsed_ms=round((time.time() - request_started_at) * 1000, 3),
    )
    return decoded


def load_text_arg(value: str | None, file_path: str | None) -> str | None:
    if value is not None:
        return value
    if file_path is not None:
        if file_path == "-":
            return sys.stdin.read()
        return Path(file_path).read_text(encoding="utf-8")
    return None


def ensure_safe_text_arg(*, option_name: str, value: str | None, file_path: str | None) -> None:
    # This CLI is A3's adapter layer, not SoloBoard's public CLI. Accept
    # multiline text here so callers are not forced to encode transport details.
    return None


def parse_task_reference(reference: str | None) -> tuple[str | None, int | None]:
    raw = str(reference or "").strip()
    if not raw:
        return None, None
    match = re.fullmatch(r"(.+?)#(\d+)", raw)
    if not match:
        return None, None
    return match.group(1).strip(), int(match.group(2))


def canonical_human_task_ref(project_title: str, task_ref: str) -> str:
    ref = str(task_ref or "").strip()
    project = canonical_project_ref_title(project_title)
    if not ref:
        raise RuntimeError("Task ref must not be empty.")
    if not project:
        raise RuntimeError("Project title must not be empty.")
    if ref.startswith("#"):
        return f"{project}{ref}"
    match = re.fullmatch(r"(.+?)#(\d+)", ref)
    if match:
        return f"{match.group(1).strip()}#{match.group(2)}"
    raise RuntimeError(f"Unsupported task ref: {task_ref}")


def canonical_project_ref_title(project_title: str | None) -> str:
    project = str(project_title or "").strip()
    if project.endswith(" Staging"):
        return project[: -len(" Staging")].strip()
    return project


def task_index(task: dict[str, Any]) -> int | None:
    _, index = parse_task_reference(task.get("reference"))
    if index is not None:
        return index
    raw_index = task.get("index")
    return int(raw_index) if raw_index not in (None, "") else None


def short_task_ref(task: dict[str, Any]) -> str:
    reference = str(task.get("reference") or "").strip()
    _, index = parse_task_reference(reference)
    if index is not None:
        return f"#{index}"
    identifier = str(task.get("identifier") or "").strip()
    if identifier:
        return identifier
    return f"#{int(task['id'])}"


def canonical_human_task_ref_for_task(task: dict[str, Any], *, project_title: str) -> str:
    reference = str(task.get("reference") or "").strip()
    if reference:
        project, index = parse_task_reference(reference)
        if project and index is not None:
            return f"{project}#{index}"
    return canonical_human_task_ref(project_title, short_task_ref(task))


def normalize_task_summary(task: dict[str, Any], *, project_title: str) -> dict[str, Any]:
    return {
        "ref": canonical_human_task_ref_for_task(task, project_title=project_title),
        "short_ref": short_task_ref(task),
        "project": project_title,
        "id": int(task["id"]),
        "identifier": short_task_ref(task),
        "index": task_index(task),
        "title": task.get("title"),
        "description": task.get("description") or "",
        "status": task.get("status"),
        "done": bool(task.get("done", False)),
        "priority": int(task.get("priority") or 0),
        "reference": task.get("reference") or "",
        "date_modification": int(task.get("date_modification") or 0) if str(task.get("date_modification") or "").strip() else 0,
    }


def normalize_task_detail(task: dict[str, Any], *, project_title: str) -> dict[str, Any]:
    normalized = dict(task)
    normalized["ref"] = canonical_human_task_ref_for_task(task, project_title=project_title)
    normalized["short_ref"] = short_task_ref(task)
    normalized["project"] = project_title
    normalized["identifier"] = short_task_ref(task)
    normalized["index"] = task_index(task)
    normalized["done"] = bool(task.get("done", False))
    return normalized


def summarize_description(description: str, *, limit: int = 160) -> str:
    single_line = " ".join(line.strip() for line in description.splitlines() if line.strip())
    if len(single_line) <= limit:
        return single_line
    return single_line[: limit - 3].rstrip() + "..."


def normalize_task_snapshot(
    base_url: str,
    token: str,
    task: dict[str, Any],
    *,
    project_title: str,
    project_titles_by_id: dict[int, str],
) -> dict[str, Any]:
    task_id = int(task["id"])
    trace_log("task_snapshot.normalize.start", task_id=task_id, reference=str(task.get("reference") or ""))
    related_ref_cache: dict[int, str] = {}

    def resolve_related_task_ref(item: dict[str, Any]) -> str | None:
        task_id = int(item.get("id") or 0)
        if task_id <= 0:
            return None
        cached = related_ref_cache.get(task_id)
        if cached:
            return cached

        related_reference = str(item.get("reference") or "").strip()
        if related_reference:
            related_ref_cache[task_id] = related_reference
            return related_reference

        related_task = get_task(base_url, token, task_id)
        related_reference = str(related_task.get("reference") or "").strip()
        if related_reference:
            related_ref_cache[task_id] = related_reference
            return related_reference

        fallback = canonical_human_task_ref(
            project_titles_by_id.get(int(item.get("project_id") or 0), str(item.get("project_title") or project_title)),
            f"#{task_id}",
        )
        related_ref_cache[task_id] = fallback
        return fallback

    related_tasks = relation_tasks_payload(base_url, token, task_id=task_id)
    # Snapshot normalization already needs the detail endpoint for tags; reuse it
    # as the source of truth for bodyMarkdown instead of trusting list payloads.
    detailed_task = get_task(base_url, token, task_id)
    description = str(detailed_task.get("description") or detailed_task.get("bodyMarkdown") or task.get("description") or "")
    tags = detailed_task.get("tags") if isinstance(detailed_task, dict) else None
    if not isinstance(tags, list):
        raise RuntimeError("Unexpected SoloBoard task tags response.")
    label_titles = tuple(
        sorted(
            normalize_label(tag)["title"]
            for tag in tags
        )
    )
    blocked_refs = tuple(
        ref
        for item in related_tasks.get("blocked", [])
        if (ref := resolve_related_task_ref(item))
    )
    parent_refs = [
        ref
        for item in related_tasks.get("parenttask", [])
        if (ref := resolve_related_task_ref(item))
    ]
    normalized = {
        **normalize_task_summary(task, project_title=project_title),
        "description": description,
        "description_summary": summarize_description(description),
        "labels": list(label_titles),
        "blocking_task_refs": list(sorted(set(blocked_refs))),
        "parent_refs": parent_refs,
        "parent_ref": parent_refs[0] if parent_refs else None,
    }
    trace_log(
        "task_snapshot.normalize.finish",
        task_id=task_id,
        ref=normalized["ref"],
        blocking_count=len(normalized["blocking_task_refs"]),
        parent_count=len(parent_refs),
        label_count=len(label_titles),
    )
    return normalized


def normalize_task_watch_summary(task: dict[str, Any], *, project_title: str) -> dict[str, Any]:
    return {
        "id": int(task["id"]),
        "ref": canonical_human_task_ref_for_task(task, project_title=project_title),
        "title": task.get("title") or "",
        "status": task.get("status"),
    }


def normalize_label(label: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": int(label.get("id")) if str(label.get("id") or "").strip() else label.get("id"),
        "title": label.get("name") or label.get("title"),
        "description": label.get("description") or "",
        "hex_color": label.get("color") or label.get("hex_color") or "",
    }


def normalize_task_comment(task_id: int, comment: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": int(comment.get("id")) if str(comment.get("id") or "").strip() else comment.get("id"),
        "task_id": task_id,
        "comment": comment.get("comment") or comment.get("bodyMarkdown") or "",
        "created": comment.get("created") or comment.get("date_creation"),
        "updated": comment.get("updated") or comment.get("date_modification") or comment.get("date_creation") or comment.get("createdAt"),
        "author": {
            "id": int(comment.get("user_id")) if str(comment.get("user_id") or "").strip() else comment.get("user_id"),
            "username": comment.get("username"),
            "name": comment.get("name"),
        },
    }


def parse_iso_datetime_to_epoch(value: str | None) -> int:
    raw = str(value or "").strip()
    if not raw:
        return 0
    try:
        return int(datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def soloboard_find_lane_name(board_shell: dict[str, Any], lane_id: int) -> str | None:
    for lane in board_shell.get("lanes") or []:
        if int(lane.get("id") or 0) == lane_id:
            return str(lane.get("name") or "")
    return None


def soloboard_find_lane_id(board_shell: dict[str, Any], lane_name: str) -> int:
    normalized = lane_name.strip().lower()
    for lane in board_shell.get("lanes") or []:
        if str(lane.get("name") or "").strip().lower() == normalized:
            return int(lane.get("id") or 0)
    available = ", ".join(str(lane.get("name") or "") for lane in board_shell.get("lanes") or [])
    raise RuntimeError(f"Lane not found: {lane_name}. Available: {available}")


def soloboard_resolved(ticket: dict[str, Any]) -> bool:
    if "isResolved" not in ticket:
        raise RuntimeError("SoloBoard ticket response is missing isResolved.")
    return bool(ticket["isResolved"])


def soloboard_normalize_ticket(ticket: dict[str, Any], *, board_title: str, board_shell: dict[str, Any] | None = None) -> dict[str, Any]:
    lane_id = int(ticket.get("laneId") or 0)
    status = soloboard_find_lane_name(board_shell or {"lanes": []}, lane_id) if board_shell else None
    return {
        "id": int(ticket["id"]),
        "project_id": int(ticket.get("boardId") or 0),
        "column_id": lane_id,
        "bucket_id": lane_id,
        "priority": int(ticket.get("priority") or 0),
        "done": soloboard_resolved(ticket),
        "status": status,
        "title": ticket.get("title") or "",
        "description": ticket.get("bodyMarkdown") or "",
        "reference": ticket.get("ref") or canonical_human_task_ref(board_title, f"#{int(ticket['id'])}"),
        "identifier": ticket.get("shortRef") or f"#{int(ticket['id'])}",
        "index": int(ticket["id"]),
        "position": int(ticket.get("position") or 0),
        "project": board_title,
        "date_modification": parse_iso_datetime_to_epoch(ticket.get("updatedAt")),
    }


def get_projects(base_url: str, token: str) -> list[dict[str, Any]]:
    response = rest_request(base_url, token, "GET", "/api/boards")
    projects = response.get("boards") if isinstance(response, dict) else None
    if not isinstance(projects, list):
        raise RuntimeError("Unexpected boards response.")
    return projects


def create_project(base_url: str, token: str, *, title: str) -> dict[str, Any]:
    response = rest_request(base_url, token, "POST", "/api/boards", payload={"name": title})
    board = response.get("board") if isinstance(response, dict) else None
    if not isinstance(board, dict):
        raise RuntimeError(f"Board creation was not observed: {title}")
    return board


def list_labels(base_url: str, token: str, *, project_id: int) -> list[dict[str, Any]]:
    response = rest_request(base_url, token, "GET", f"/api/boards/{project_id}/tags")
    labels = response.get("tags") if isinstance(response, dict) else None
    if not isinstance(labels, list):
        raise RuntimeError("Unexpected tags response.")
    return labels


def create_label(base_url: str, token: str, *, project_id: int, title: str, description: str = "", hex_color: str = "") -> dict[str, Any]:
    _ = description
    created = rest_request(
        base_url,
        token,
        "POST",
        f"/api/boards/{project_id}/tags",
        payload={"name": title, "color": hex_color or "#888888"},
    )
    if not isinstance(created, dict):
        raise RuntimeError(f"Tag creation was not observed: {title}")
    return created


def delete_label(base_url: str, token: str, *, project_id: int, label_id: int | None, title: str | None) -> None:
    labels = list_labels(base_url, token, project_id=project_id)
    if label_id is not None:
        exact = [label for label in labels if int(label.get("id") or 0) == int(label_id)]
    else:
        if not title:
            raise RuntimeError("--label-id or --title is required.")
        exact = [label for label in labels if (label.get("name") or label.get("title") or "") == title]
    if len(exact) == 0:
        return
    if len(exact) > 1:
        raise RuntimeError("Tag title is ambiguous: " + ", ".join(f"{label['id']}:{label['name']}" for label in exact))
    resolved_id = int(exact[0]["id"])
    rest_request(base_url, token, "DELETE", f"/api/tags/{resolved_id}")
    remaining = list_labels(base_url, token, project_id=project_id)
    if any(int(label.get("id") or 0) == resolved_id for label in remaining):
        raise RuntimeError(f"Tag deletion was not observed: {resolved_id}")


def get_api_info(base_url: str, token: str) -> dict[str, Any]:
    return {"comment_creation_available": True}


def ensure_task_comments_enabled(base_url: str, token: str) -> None:
    _ = (base_url, token)


def resolve_project_id(
    base_url: str,
    token: str,
    *,
    project_id: int | None,
    project_title: str | None,
    default_project_title: str | None = None,
) -> int:
    if project_id is not None:
        return project_id
    if project_title is None:
        project_title = default_project_title
    if not project_title:
        raise RuntimeError("--project-id or --project is required.")
    exact = []
    partial = []
    for project in get_projects(base_url, token):
        title = str(project.get("name") or project.get("title") or "")
        if title == project_title:
            exact.append(project)
        elif project_title.lower() in title.lower():
            partial.append(project)
    if len(exact) == 1:
        return int(exact[0]["id"])
    if not exact and len(partial) == 1:
        return int(partial[0]["id"])
    if exact or partial:
        candidates = exact or partial
        raise RuntimeError(
            "Project name is ambiguous: "
            + ", ".join(f"{project['id']}:{project.get('name') or project.get('title')}" for project in candidates)
        )
    raise RuntimeError(f"Project not found: {project_title}")


def resolve_project_title(base_url: str, token: str, *, project_id: int) -> str:
    for project in get_projects(base_url, token):
        if int(project.get("id", 0)) == project_id:
            return str(project.get("name") or project.get("title") or project_id)
    raise RuntimeError(f"Project not found: {project_id}")


def get_columns(base_url: str, token: str, project_id: int) -> list[dict[str, Any]]:
    response = rest_request(base_url, token, "GET", f"/api/boards/{project_id}/lanes")
    columns = response.get("lanes") if isinstance(response, dict) else None
    if not isinstance(columns, list):
        raise RuntimeError("Unexpected lanes response.")
    return [
        {"id": int(column["id"]), "title": column.get("name"), "position": int(column.get("position") or 0)}
        for column in sorted(columns, key=lambda column: int(column.get("position") or 0))
    ]


def get_task(base_url: str, token: str, task_id: int) -> dict[str, Any]:
    task = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}")
    if not isinstance(task, dict):
        raise RuntimeError(f"Task not found: {task_id}")
    board_title = resolve_project_title(base_url, token, project_id=int(task.get("boardId") or 0))
    board_shell = rest_request(base_url, token, "GET", f"/api/boards/{int(task.get('boardId') or 0)}")
    normalized = soloboard_normalize_ticket(task, board_title=board_title, board_shell=board_shell)
    normalized["bodyMarkdown"] = task.get("bodyMarkdown") or ""
    normalized["tags"] = task.get("tags") or []
    normalized["comments"] = task.get("comments") or []
    normalized["blockerIds"] = task.get("blockerIds") or []
    normalized["parentTicketId"] = task.get("parentTicketId")
    return normalized


def list_task_comments(base_url: str, token: str, task_id: int) -> list[dict[str, Any]]:
    response = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}/comments")
    comments = response.get("comments") if isinstance(response, dict) else None
    if not isinstance(comments, list):
        raise RuntimeError("Unexpected task comments response.")
    return comments


def create_task_comment(base_url: str, token: str, task_id: int, comment: str) -> dict[str, Any]:
    created = rest_request(
        base_url,
        token,
        "POST",
        f"/api/tickets/{task_id}/comments",
        payload={"bodyMarkdown": comment},
    )
    if not isinstance(created, dict):
        raise RuntimeError("Unexpected task comment creation response.")
    return created


def list_task_labels(base_url: str, token: str, task_id: int) -> list[dict[str, Any]]:
    task = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}")
    tags = task.get("tags") if isinstance(task, dict) else None
    if not isinstance(tags, list):
        raise RuntimeError("Unexpected task tags response.")
    return [normalize_label(tag) for tag in tags]


def resolve_label_id(base_url: str, token: str, *, label_id: int | None, title: str | None) -> int | str:
    _ = (base_url, token)
    if label_id is not None:
        return label_id
    if not title:
        raise RuntimeError("--label-id or --title/--label is required.")
    return title


def ensure_label(
    base_url: str,
    token: str,
    *,
    project_id: int,
    title: str,
    description: str = "",
    hex_color: str = "",
) -> dict[str, Any]:
    exact = [label for label in list_labels(base_url, token, project_id=project_id) if (label.get("name") or "") == title]
    if len(exact) == 1:
        return exact[0]
    if len(exact) > 1:
        raise RuntimeError("Tag title is ambiguous: " + ", ".join(f"{label['id']}:{label['name']}" for label in exact))
    return create_label(base_url, token, project_id=project_id, title=title, description=description, hex_color=hex_color)


def tag_name_for_ref(base_url: str, token: str, *, task_id: int, label_ref: int | str) -> str:
    if isinstance(label_ref, str):
        return label_ref
    task = get_task(base_url, token, task_id)
    project_id = int(task["project_id"])
    labels = list_labels(base_url, token, project_id=project_id)
    matched = [label for label in labels if int(label.get("id") or 0) == int(label_ref)]
    if len(matched) != 1:
        raise RuntimeError(f"Tag not found: {label_ref}")
    return str(matched[0].get("name") or matched[0].get("title") or "")


def set_task_tags(base_url: str, token: str, *, task_id: int, names: list[str]) -> bool:
    task = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}")
    if not isinstance(task, dict):
        raise RuntimeError(f"Task not found: {task_id}")
    board_id = int(task.get("boardId") or 0)
    available = list_labels(base_url, token, project_id=board_id)
    tag_ids: list[int] = []
    for name in names:
        matched = [label for label in available if (label.get("name") or label.get("title") or "") == name]
        if len(matched) != 1:
            raise RuntimeError(f"Tag not found for task assignment: {name}")
        tag_ids.append(int(matched[0]["id"]))
    updated = rest_request(base_url, token, "PATCH", f"/api/tickets/{task_id}", payload={"tagIds": tag_ids})
    return isinstance(updated, dict)


def retry_observed_task_labels(
    base_url: str,
    token: str,
    *,
    task_id: int,
    predicate,
    attempts: int = 5,
    delay_seconds: float = 0.1,
) -> list[dict[str, Any]]:
    observed: list[dict[str, Any]] = []
    for attempt in range(attempts):
        observed = list_task_labels(base_url, token, task_id)
        if predicate(observed):
            return observed
        if attempt + 1 < attempts:
            time.sleep(delay_seconds)
    return observed


def stable_task_label_titles(base_url: str, token: str, *, task_id: int) -> set[str]:
    labels = retry_observed_task_labels(
        base_url,
        token,
        task_id=task_id,
        predicate=lambda _labels: True,
        attempts=5,
        delay_seconds=0.1,
    )
    return {str(label.get("title") or "") for label in labels if str(label.get("title") or "")}


def add_task_label(base_url: str, token: str, task_id: int, label_ref: int | str) -> dict[str, Any]:
    current = stable_task_label_titles(base_url, token, task_id=task_id)
    current.add(tag_name_for_ref(base_url, token, task_id=task_id, label_ref=label_ref))
    if not set_task_tags(base_url, token, task_id=task_id, names=sorted(current)):
        raise RuntimeError(f"Task tag assignment failed. task={task_id} label={label_ref}")
    return {"result": True}


def remove_task_label(base_url: str, token: str, task_id: int, label_ref: int | str) -> dict[str, Any]:
    current = stable_task_label_titles(base_url, token, task_id=task_id)
    current.discard(tag_name_for_ref(base_url, token, task_id=task_id, label_ref=label_ref))
    if not set_task_tags(base_url, token, task_id=task_id, names=sorted(current)):
        raise RuntimeError(f"Task tag deletion failed. task={task_id} label={label_ref}")
    return {"result": True}


def enrich_task(task: dict[str, Any]) -> dict[str, Any]:
    if "boardId" in task:
        return {
            "id": int(task["id"]),
            "project_id": int(task.get("boardId") or 0),
            "column_id": int(task.get("laneId") or 0),
            "priority": int(task.get("priority") or 0),
            "done": soloboard_resolved(task),
            "reference": task.get("ref") or "",
            "title": task.get("title") or "",
            "description": task.get("bodyMarkdown") or "",
            "date_modification": parse_iso_datetime_to_epoch(task.get("updatedAt")),
        }
    normalized = dict(task)
    normalized["id"] = int(task["id"])
    normalized["project_id"] = int(task["project_id"])
    normalized["column_id"] = int(task.get("column_id") or 0)
    normalized["priority"] = int(task.get("priority") or 0)
    normalized["done"] = str(task.get("is_active", "1")) == "0"
    return normalized


def find_column_by_id(columns: list[dict[str, Any]], column_id: int) -> dict[str, Any] | None:
    for column in columns:
        if int(column.get("id") or 0) == column_id:
            return column
    return None


def iterate_kanban_tasks(
    base_url: str,
    token: str,
    project_id: int,
    *,
    search: str | None = None,
    include_closed: bool = False,
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    board_shell = rest_request(base_url, token, "GET", f"/api/boards/{project_id}")
    board_title = str(board_shell.get("board", {}).get("name") or project_id)
    columns = get_columns(base_url, token, project_id)
    query: list[str] = []
    if search:
        query.append(f"q={urllib.parse.quote(search)}")
    if not include_closed:
        query.append("resolved=false")
    path = f"/api/boards/{project_id}/tickets"
    if query:
        path += "?" + "&".join(query)
    response = rest_request(base_url, token, "GET", path)
    tasks = response.get("tickets") if isinstance(response, dict) else None
    if not isinstance(tasks, list):
        raise RuntimeError("Unexpected tasks response.")
    enriched = []
    for task in tasks:
        item = soloboard_normalize_ticket(task, board_title=board_title, board_shell=board_shell)
        enriched.append(item)
    enriched.sort(key=lambda task: (task_index(task) if task_index(task) is not None else 10**9, int(task["id"])))
    return {"id": project_id, "view_kind": "soloboard"}, columns, enriched


def relation_tasks_payload(base_url: str, token: str, *, task_id: int) -> dict[str, list[dict[str, Any]]]:
    response = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}/relations")
    if not isinstance(response, dict):
        raise RuntimeError("Unexpected task relations response.")
    related: dict[str, list[dict[str, Any]]] = {}
    parent = response.get("parent")
    if isinstance(parent, dict):
        related["parenttask"] = [dict(parent)]
    children = response.get("children")
    if isinstance(children, list) and children:
        related["subtask"] = [dict(item) for item in children]
    blockers = response.get("blockers")
    if isinstance(blockers, list) and blockers:
        related["blocked"] = [dict(item) for item in blockers]
    blocked_by = response.get("blockedBy")
    if isinstance(blocked_by, list) and blocked_by:
        related["blocking"] = [dict(item) for item in blocked_by]
    return related


def get_task_with_status(base_url: str, token: str, task_id: int) -> dict[str, Any]:
    task = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}")
    if not isinstance(task, dict):
        raise RuntimeError(f"Task not found: {task_id}")
    board_id = int(task.get("boardId") or 0)
    board_shell = rest_request(base_url, token, "GET", f"/api/boards/{board_id}")
    board_title = str(board_shell.get("board", {}).get("name") or board_id)
    normalized = normalize_task_detail(
        soloboard_normalize_ticket(task, board_title=board_title, board_shell=board_shell),
        project_title=board_title,
    )
    normalized["related_tasks"] = relation_tasks_payload(base_url, token, task_id=task_id)
    normalized["comments"] = task.get("comments") or []
    normalized["tags"] = task.get("tags") or []
    return normalized


def resolve_task_id_from_ref(
    base_url: str,
    token: str,
    *,
    task_id: int | None,
    task_ref: str | None,
    project_id: int | None,
    project_title: str | None,
    default_project_title: str | None = DEFAULT_PROJECT_TITLE,
) -> int:
    if task_id is not None:
        return task_id
    if task_ref is None:
        raise RuntimeError("--task or --task-id is required.")
    raw = task_ref.strip()
    if raw.isdigit():
        return int(raw)
    if raw.startswith("#"):
        return int(raw[1:])
    _, parsed_index = parse_task_reference(raw)
    if parsed_index is not None:
        return parsed_index
    raise RuntimeError(f"Task not found: {task_ref}")


def find_bucket_by_name(buckets: list[dict[str, Any]], name: str) -> dict[str, Any]:
    normalized = name.strip().lower()
    for bucket in buckets:
        if (bucket.get("title") or "").strip().lower() == normalized:
            return bucket
    raise RuntimeError(
        "Bucket not found: " + name + ". Available: " + ", ".join(str(bucket.get("title") or "") for bucket in buckets)
    )


def update_task(base_url: str, token: str, task_id: int, changes: dict[str, Any]) -> dict[str, Any]:
    payload: dict[str, Any] = {}
    if "title" in changes:
        payload["title"] = changes["title"]
    if "description" in changes:
        payload["bodyMarkdown"] = changes["description"]
    if "priority" in changes:
        payload["priority"] = changes["priority"]
    if "done" in changes:
        payload["isResolved"] = bool(changes["done"])
    updated = rest_request(base_url, token, "PATCH", f"/api/tickets/{task_id}", payload=payload)
    if not isinstance(updated, dict):
        raise RuntimeError(f"Task update failed: {task_id}")
    board_title = resolve_project_title(base_url, token, project_id=int(updated.get("boardId") or 0))
    board_shell = rest_request(base_url, token, "GET", f"/api/boards/{int(updated.get('boardId') or 0)}")
    return soloboard_normalize_ticket(updated, board_title=board_title, board_shell=board_shell)


def create_relation(
    base_url: str,
    token: str,
    *,
    task_id: int,
    other_task_id: int,
    relation_kind: str,
) -> dict[str, Any]:
    if relation_kind == "subtask":
        updated = rest_request(base_url, token, "PATCH", f"/api/tickets/{other_task_id}", payload={"parentTicketId": task_id})
        return {"id": int(updated.get("id") or other_task_id)}
    if relation_kind == "parenttask":
        updated = rest_request(base_url, token, "PATCH", f"/api/tickets/{task_id}", payload={"parentTicketId": other_task_id})
        return {"id": int(updated.get("id") or task_id)}
    if relation_kind == "blocked":
        task = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}")
        blocker_ids = sorted({int(item) for item in (task.get("blockerIds") or [])} | {other_task_id})
        updated = rest_request(base_url, token, "PATCH", f"/api/tickets/{task_id}", payload={"blockerIds": blocker_ids})
        return {"id": int(updated.get("id") or task_id)}
    raise RuntimeError(f"Unsupported relation kind for SoloBoard: {relation_kind}")


def delete_relation(
    base_url: str,
    token: str,
    *,
    task_id: int,
    other_task_id: int,
    relation_kind: str,
) -> dict[str, Any]:
    if relation_kind == "subtask":
        updated = rest_request(base_url, token, "PATCH", f"/api/tickets/{other_task_id}", payload={"parentTicketId": None})
        if int(updated.get("parentTicketId") or 0) == task_id:
            raise RuntimeError("SoloBoard API did not clear parentTicketId; parent/subtask relation delete is not yet reliable.")
        return {"result": bool(updated)}
    if relation_kind == "parenttask":
        updated = rest_request(base_url, token, "PATCH", f"/api/tickets/{task_id}", payload={"parentTicketId": None})
        if int(updated.get("parentTicketId") or 0) == other_task_id:
            raise RuntimeError("SoloBoard API did not clear parentTicketId; parent/subtask relation delete is not yet reliable.")
        return {"result": bool(updated)}
    if relation_kind == "blocked":
        task = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}")
        blocker_ids = [int(item) for item in (task.get("blockerIds") or []) if int(item) != other_task_id]
        updated = rest_request(base_url, token, "PATCH", f"/api/tickets/{task_id}", payload={"blockerIds": blocker_ids})
        return {"result": bool(updated)}
    raise RuntimeError(f"Unsupported relation kind for SoloBoard: {relation_kind}")


def move_task_to_bucket(
    base_url: str,
    token: str,
    *,
    project_id: int,
    view_id: int,
    bucket_id: int,
    task_id: int,
) -> dict[str, Any]:
    updated = rest_request(base_url, token, "PATCH", f"/api/tickets/{task_id}", payload={"laneId": bucket_id})
    return {"result": bool(updated)}


def transition_task_status(
    base_url: str,
    token: str,
    *,
    task_id: int,
    status: str,
    sync_done_state: bool = False,
) -> dict[str, Any]:
    task = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}")
    if not isinstance(task, dict):
        raise RuntimeError(f"Task not found: {task_id}")
    payload: dict[str, Any] = {"laneName": status}
    target_is_done = status.strip().lower() == "done"
    task_is_done = soloboard_resolved(task)
    if sync_done_state and target_is_done:
        payload["isResolved"] = True
    elif not target_is_done and (sync_done_state or task_is_done):
        payload["isResolved"] = False
    transitioned = rest_request(base_url, token, "PATCH", f"/api/tickets/{task_id}/transition", payload=payload)
    board_id = int(transitioned.get("boardId") or 0)
    board_shell = rest_request(base_url, token, "GET", f"/api/boards/{board_id}")
    board_title = str(board_shell.get("board", {}).get("name") or board_id)
    normalized = soloboard_normalize_ticket(transitioned, board_title=board_title, board_shell=board_shell)
    normalized["related_tasks"] = relation_tasks_payload(base_url, token, task_id=task_id)
    return normalized


def build_reordered_ticket_items(
    tickets: list[dict[str, Any]],
    *,
    task_id: int,
    target_lane_id: int,
    target_position: int,
    lane_ids: list[int],
) -> list[dict[str, int]]:
    if target_position < 0:
        raise RuntimeError("--position must be zero or greater.")
    ticket_by_id = {int(ticket.get("id") or 0): ticket for ticket in tickets}
    target = ticket_by_id.get(task_id)
    if target is None:
        raise RuntimeError(f"Task is not reorderable in the active board ticket list: {task_id}")
    lane_order = list(dict.fromkeys([*lane_ids, *[int(ticket.get("laneId") or 0) for ticket in tickets], target_lane_id]))
    grouped: dict[int, list[dict[str, Any]]] = {lane_id: [] for lane_id in lane_order}
    for ticket in sorted(tickets, key=lambda item: (int(item.get("position") or 0), int(item.get("id") or 0))):
        current_id = int(ticket.get("id") or 0)
        if current_id == task_id:
            continue
        lane_id = int(ticket.get("laneId") or 0)
        grouped.setdefault(lane_id, []).append(ticket)
    target_group = grouped.setdefault(target_lane_id, [])
    bounded_position = min(target_position, len(target_group))
    target_group.insert(bounded_position, {**target, "laneId": target_lane_id})

    items: list[dict[str, int]] = []
    for lane_id in lane_order:
        for position, ticket in enumerate(grouped.get(lane_id, [])):
            items.append(
                {
                    "ticketId": int(ticket["id"]),
                    "laneId": lane_id,
                    "position": position,
                }
            )
    return items


def reorder_task(
    base_url: str,
    token: str,
    *,
    task_id: int,
    target_lane_id: int,
    target_position: int,
) -> dict[str, Any]:
    task = rest_request(base_url, token, "GET", f"/api/tickets/{task_id}")
    if not isinstance(task, dict):
        raise RuntimeError(f"Task not found: {task_id}")
    board_id = int(task.get("boardId") or 0)
    board_shell = rest_request(base_url, token, "GET", f"/api/boards/{board_id}")
    if not isinstance(board_shell, dict):
        raise RuntimeError(f"Board not found: {board_id}")
    summaries_response = rest_request(base_url, token, "GET", f"/api/boards/{board_id}/tickets")
    tickets = summaries_response.get("tickets") if isinstance(summaries_response, dict) else None
    if not isinstance(tickets, list):
        raise RuntimeError("Unexpected tasks response.")
    lane_ids = [int(lane.get("id") or 0) for lane in board_shell.get("lanes") or []]
    if target_lane_id not in lane_ids:
        raise RuntimeError(f"Lane does not belong to board: {target_lane_id}")
    items = build_reordered_ticket_items(
        tickets,
        task_id=task_id,
        target_lane_id=target_lane_id,
        target_position=target_position,
        lane_ids=lane_ids,
    )
    reordered = rest_request(
        base_url,
        token,
        "POST",
        f"/api/boards/{board_id}/tickets/reorder",
        payload={"items": items},
    )
    updated_tickets = reordered.get("tickets") if isinstance(reordered, dict) else None
    if not isinstance(updated_tickets, list):
        raise RuntimeError("Unexpected task reorder response.")
    updated = next((ticket for ticket in updated_tickets if int(ticket.get("id") or 0) == task_id), None)
    if updated is None:
        raise RuntimeError(f"Reordered task was not returned: {task_id}")
    board_title = str(board_shell.get("board", {}).get("name") or board_id)
    return soloboard_normalize_ticket(updated, board_title=board_title, board_shell=board_shell)


def print_json(payload: Any) -> int:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_project_ensure_buckets(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    project_id = resolve_project_id(base_url, token, project_id=args.project_id, project_title=args.project)
    board_shell = rest_request(base_url, token, "GET", f"/api/boards/{project_id}")
    lanes = board_shell.get("lanes") if isinstance(board_shell, dict) else None
    if not isinstance(lanes, list):
        raise RuntimeError("Unexpected lanes response.")
    existing_by_name = {str(lane.get("name") or "").strip().lower(): lane for lane in lanes}
    ordered_lane_ids: list[int] = []
    for bucket_name in args.bucket:
        lane = existing_by_name.get(bucket_name.strip().lower())
        if lane is None:
            lane = rest_request(base_url, token, "POST", f"/api/boards/{project_id}/lanes", payload={"name": bucket_name})
        ordered_lane_ids.append(int(lane["id"]))
    reordered = rest_request(
        base_url,
        token,
        "POST",
        f"/api/boards/{project_id}/lanes/reorder",
        payload={"laneIds": ordered_lane_ids},
    )
    return print_json(
        {
            "project_id": project_id,
            "view_id": project_id,
            "bucket_names": args.bucket,
            "bucket_ids_by_name": {lane["name"]: int(lane["id"]) for lane in reordered.get("lanes", [])},
            "default_bucket_id": ordered_lane_ids[0],
            "done_bucket_id": ordered_lane_ids[-1],
        }
    )


def cmd_project_list(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    projects = get_projects(base_url, token)
    if args.search:
        query = args.search.lower()
        projects = [project for project in projects if query in str(project.get("name") or project.get("title") or "").lower()]
    return print_json(
        [
            {
                "id": int(project["id"]),
                "title": project.get("name") or project.get("title"),
                "is_archived": False,
            }
            for project in projects
        ]
    )


def cmd_project_create(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    created = create_project(base_url, token, title=args.title)
    return print_json(
        {
            "id": int(created["id"]),
            "title": created.get("name") or created.get("title"),
            "is_archived": False,
        }
    )


def cmd_label_list(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    project_id = resolve_project_id(base_url, token, project_id=args.project_id, project_title=args.project)
    labels = list_labels(base_url, token, project_id=project_id)
    if args.search:
        query = args.search.lower()
        labels = [label for label in labels if query in str(label.get("name") or "").lower()]
    return print_json([normalize_label(label) for label in labels])


def cmd_label_ensure(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    project_id = resolve_project_id(base_url, token, project_id=args.project_id, project_title=args.project)
    ensured = ensure_label(
        base_url,
        token,
        project_id=project_id,
        title=args.title,
        description=args.description or "",
        hex_color=args.hex_color or "",
    )
    return print_json(normalize_label(ensured))


def cmd_label_delete(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    project_id = resolve_project_id(base_url, token, project_id=args.project_id, project_title=args.project)
    delete_label(base_url, token, project_id=project_id, label_id=args.label_id, title=args.title)
    return print_json([normalize_label(label) for label in list_labels(base_url, token, project_id=project_id)])


def cmd_task_list(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    project_id = resolve_project_id(base_url, token, project_id=args.project_id, project_title=args.project)
    _, buckets, tasks = iterate_kanban_tasks(base_url, token, project_id, search=args.search)
    project_title = resolve_project_title(base_url, token, project_id=project_id)
    if args.status:
        target_bucket = find_bucket_by_name(buckets, args.status)
        tasks = [task for task in tasks if int(task.get("bucket_id") or 0) == int(target_bucket["id"])]
    if args.limit:
        tasks = tasks[: args.limit]
    return print_json([normalize_task_summary(task, project_title=project_title) for task in tasks])


def cmd_task_snapshot_list(args: argparse.Namespace) -> int:
    trace_log(
        "task_snapshot_list.start",
        project=args.project,
        project_id=args.project_id,
        search=args.search,
        status=args.status,
        limit=args.limit,
        include_closed=bool(getattr(args, "include_closed", False)),
    )
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    project_id = resolve_project_id(base_url, token, project_id=args.project_id, project_title=args.project)
    _, buckets, tasks = iterate_kanban_tasks(
        base_url,
        token,
        project_id,
        search=args.search,
        include_closed=bool(getattr(args, "include_closed", False)),
    )
    project_title = resolve_project_title(base_url, token, project_id=project_id)
    project_titles_by_id = {
        int(project["id"]): str(project.get("name") or project.get("title") or "").strip()
        for project in get_projects(base_url, token)
        if int(project.get("id") or 0) > 0 and str(project.get("name") or project.get("title") or "").strip()
    }
    if args.status:
        target_bucket = find_bucket_by_name(buckets, args.status)
        tasks = [task for task in tasks if int(task.get("bucket_id") or 0) == int(target_bucket["id"])]
    if args.limit:
        tasks = tasks[: args.limit]
    snapshots = [
        normalize_task_snapshot(
            base_url,
            token,
            task,
            project_title=project_title,
            project_titles_by_id=project_titles_by_id,
        )
        for task in tasks
    ]
    trace_log(
        "task_snapshot_list.finish",
        project_id=project_id,
        task_count=len(tasks),
        snapshot_count=len(snapshots),
    )
    return print_json(snapshots)


def cmd_task_watch_summary_list(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_ids = [int(task_id) for task_id in (getattr(args, "task_ids", None) or [])]
    task_refs = [str(task_ref).strip() for task_ref in (getattr(args, "tasks", None) or []) if str(task_ref).strip()]
    if not task_ids and not task_refs:
        return print_json([])

    default_project_title = args.project
    resolved_project_id = args.project_id
    if resolved_project_id is None and default_project_title:
        resolved_project_id = resolve_project_id(base_url, token, project_id=None, project_title=default_project_title)
    if default_project_title is None and resolved_project_id is not None:
        default_project_title = resolve_project_title(base_url, token, project_id=resolved_project_id)

    columns_by_project_id: dict[int, list[dict[str, Any]]] = {}
    project_titles_by_id: dict[int, str] = {}
    normalized_by_id: dict[int, dict[str, Any]] = {}

    def resolve_task_for_summary(*, task_id: int | None = None, task_ref: str | None = None) -> None:
        try:
            resolved_task_id = task_id
            if resolved_task_id is None:
                resolved_task_id = resolve_task_id_from_ref(
                    base_url,
                    token,
                    task_id=None,
                    task_ref=task_ref,
                    project_id=resolved_project_id,
                    project_title=default_project_title,
                )
            assert resolved_task_id is not None
            if resolved_task_id in normalized_by_id:
                return
            task = get_task(base_url, token, resolved_task_id)
        except RuntimeError:
            if getattr(args, "ignore_missing", False):
                return
            raise

        project_id = int(task["project_id"])
        project_title = project_titles_by_id.get(project_id)
        if project_title is None:
            project_title = resolve_project_title(base_url, token, project_id=project_id)
            project_titles_by_id[project_id] = project_title
        columns = columns_by_project_id.get(project_id)
        if columns is None:
            columns = get_columns(base_url, token, project_id)
            columns_by_project_id[project_id] = columns
        column = find_column_by_id(columns, int(task.get("column_id") or 0))
        task["status"] = column.get("title") if column else None
        normalized_by_id[resolved_task_id] = normalize_task_watch_summary(task, project_title=project_title)

    for task_id in task_ids:
        resolve_task_for_summary(task_id=task_id)
    for task_ref in task_refs:
        resolve_task_for_summary(task_ref=task_ref)

    items = sorted(normalized_by_id.values(), key=lambda item: item["ref"])
    return print_json(items)


def cmd_task_find(args: argparse.Namespace) -> int:
    args.search = args.query
    return cmd_task_list(args)


def cmd_task_get(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    task = get_task_with_status(base_url, token, task_id)
    project_title = resolve_project_title(base_url, token, project_id=int(task["project_id"]))
    return print_json(normalize_task_detail(task, project_title=project_title))


def cmd_task_relation_list(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    related = relation_tasks_payload(base_url, token, task_id=task_id)
    return print_json(related)


def cmd_task_create(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    project_id = resolve_project_id(base_url, token, project_id=args.project_id, project_title=args.project)
    ensure_safe_text_arg(option_name="--description", value=args.description, file_path=args.description_file)
    description = load_text_arg(args.description, args.description_file) or ""
    board_shell = rest_request(base_url, token, "GET", f"/api/boards/{project_id}")
    lanes = board_shell.get("lanes") if isinstance(board_shell, dict) else None
    if not isinstance(lanes, list) or not lanes:
        raise RuntimeError("SoloBoard board must have at least one lane.")
    lane_name = args.status or "To do"
    matched = [lane for lane in lanes if str(lane.get("name") or "").strip().lower() == lane_name.strip().lower()]
    lane = matched[0] if matched else lanes[0]
    created = rest_request(
        base_url,
        token,
        "POST",
        f"/api/boards/{project_id}/tickets",
        payload={
            "laneId": int(lane["id"]),
            "title": args.title,
            "bodyMarkdown": description,
        },
    )
    if isinstance(created, dict) and not created.get("bodyMarkdown"):
        created = {**created, "bodyMarkdown": description}
    board_title = str(board_shell.get("board", {}).get("name") or project_id)
    return print_json(normalize_task_detail(soloboard_normalize_ticket(created, board_title=board_title, board_shell=board_shell), project_title=board_title))


def cmd_task_comment_list(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    ensure_task_comments_enabled(base_url, token)
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    comments = list_task_comments(base_url, token, task_id)
    return print_json([normalize_task_comment(task_id, comment) for comment in comments])


def cmd_task_comment_create(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    ensure_task_comments_enabled(base_url, token)
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    ensure_safe_text_arg(option_name="--comment", value=args.comment, file_path=args.comment_file)
    comment = load_text_arg(args.comment, args.comment_file)
    if comment is None:
        raise RuntimeError("--comment or --comment-file is required.")
    created = create_task_comment(base_url, token, task_id, comment)
    created_id = created.get("id")
    comments = list_task_comments(base_url, token, task_id)
    observed = next((item for item in comments if int(item.get("id") or 0) == int(created_id)), None)
    if observed is None:
        raise RuntimeError(
            "Comment creation was not observed via task-comment-list."
            f" task={task_id} comment_id={created_id}"
        )
    return print_json(normalize_task_comment(task_id, observed))


def cmd_task_label_list(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    return print_json(list_task_labels(base_url, token, task_id))


def cmd_task_label_add(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    resolved_label_id = resolve_label_id(base_url, token, label_id=args.label_id, title=args.title)
    add_task_label(base_url, token, task_id, resolved_label_id)
    expected_title = tag_name_for_ref(base_url, token, task_id=task_id, label_ref=resolved_label_id)
    observed = retry_observed_task_labels(
        base_url,
        token,
        task_id=task_id,
        predicate=lambda labels: any((label.get("title") or "") == expected_title for label in labels),
    )
    if not any((label.get("title") or "") == expected_title for label in observed):
        raise RuntimeError(f"Task label assignment was not observed. task={task_id} label={expected_title}")
    return print_json(observed)


def cmd_task_label_remove(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    resolved_label_id = resolve_label_id(base_url, token, label_id=args.label_id, title=args.title)
    expected_title = tag_name_for_ref(base_url, token, task_id=task_id, label_ref=resolved_label_id)
    remove_task_label(base_url, token, task_id, resolved_label_id)
    observed = retry_observed_task_labels(
        base_url,
        token,
        task_id=task_id,
        predicate=lambda labels: all((label.get("title") or "") != expected_title for label in labels),
    )
    if any((label.get("title") or "") == expected_title for label in observed):
        raise RuntimeError(f"Task label deletion was not observed. task={task_id} label={expected_title}")
    return print_json(observed)


def cmd_task_update(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    task = get_task(base_url, token, task_id)
    changes: dict[str, Any] = {}
    if args.title is not None:
        changes["title"] = args.title
    ensure_safe_text_arg(option_name="--description", value=args.description, file_path=args.description_file)
    ensure_safe_text_arg(
        option_name="--append-description",
        value=args.append_description,
        file_path=args.append_description_file,
    )
    set_description = load_text_arg(args.description, args.description_file)
    append_description = load_text_arg(args.append_description, args.append_description_file)
    if set_description is not None:
        changes["description"] = set_description
    elif append_description is not None:
        existing = task.get("description") or ""
        separator = "\n" if existing and not existing.endswith("\n") else ""
        changes["description"] = f"{existing}{separator}{append_description}"
    if args.priority is not None:
        changes["priority"] = args.priority
    reference = getattr(args, "reference", None)
    if reference is not None:
        changes["reference"] = reference
    if args.done is not None:
        changes["done"] = args.done
    updated = update_task(base_url, token, task_id, changes)
    if args.done is not None:
        updated = get_task(base_url, token, task_id)
    project_title = resolve_project_title(base_url, token, project_id=int(updated["project_id"]))
    return print_json(normalize_task_detail(updated, project_title=project_title))


def cmd_task_transition(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    transitioned = transition_task_status(
        base_url,
        token,
        task_id=task_id,
        status=args.status,
        sync_done_state=bool(getattr(args, "sync_done_state", False)),
    )
    project_title = resolve_project_title(base_url, token, project_id=int(transitioned["project_id"]))
    return print_json(normalize_task_detail(transitioned, project_title=project_title))


def cmd_task_reorder(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    current = get_task(base_url, token, task_id)
    project_id = int(current["project_id"])
    board_shell = rest_request(base_url, token, "GET", f"/api/boards/{project_id}")
    if not isinstance(board_shell, dict):
        raise RuntimeError(f"Board not found: {project_id}")
    target_lane_id = args.lane_id
    if target_lane_id is None:
        target_lane_id = int(current.get("column_id") or 0)
    if args.status is not None:
        target_lane_id = soloboard_find_lane_id(board_shell, args.status)
    reordered = reorder_task(
        base_url,
        token,
        task_id=task_id,
        target_lane_id=target_lane_id,
        target_position=args.position,
    )
    project_title = resolve_project_title(base_url, token, project_id=int(reordered["project_id"]))
    return print_json(normalize_task_detail(reordered, project_title=project_title))


def cmd_task_relation_create(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    other_task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.other_task_id,
        task_ref=args.other_task,
        project_id=args.other_project_id,
        project_title=args.other_project,
        default_project_title=args.project or DEFAULT_PROJECT_TITLE,
    )
    create_relation(
        base_url,
        token,
        task_id=task_id,
        other_task_id=other_task_id,
        relation_kind=args.relation_kind,
    )
    updated_task = get_task_with_status(base_url, token, task_id)
    updated_task["related_tasks"] = relation_tasks_payload(base_url, token, task_id=task_id)
    tasks = (updated_task.get("related_tasks") or {}).get(args.relation_kind) or []
    if not any(int(task.get("id", 0)) == other_task_id for task in tasks):
        raise RuntimeError(
            "Relation creation was not observed via task-get."
            f" task={task_id} other_task={other_task_id} relation_kind={args.relation_kind}"
        )
    return print_json(updated_task)


def cmd_task_relation_delete(args: argparse.Namespace) -> int:
    backend = resolve_backend_context(backend=getattr(args, "backend", None), base_url=args.base_url, token=args.token)
    base_url = backend.base_url
    token = backend.token
    task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.task_id,
        task_ref=args.task,
        project_id=args.project_id,
        project_title=args.project,
    )
    other_task_id = resolve_task_id_from_ref(
        base_url,
        token,
        task_id=args.other_task_id,
        task_ref=args.other_task,
        project_id=args.other_project_id,
        project_title=args.other_project,
        default_project_title=args.project or DEFAULT_PROJECT_TITLE,
    )
    delete_relation(
        base_url,
        token,
        task_id=task_id,
        other_task_id=other_task_id,
        relation_kind=args.relation_kind,
    )
    updated_task = get_task_with_status(base_url, token, task_id)
    tasks = (updated_task.get("related_tasks") or {}).get(args.relation_kind) or []
    if any(int(task.get("id", 0)) == other_task_id for task in tasks):
        raise RuntimeError(
            "Relation deletion was not observed via task-get."
            f" task={task_id} other_task={other_task_id} relation_kind={args.relation_kind}"
        )
    return print_json(updated_task)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Operate the configured kanban backend from the command line.")
    parser.add_argument("--backend", choices=SUPPORTED_BACKENDS)
    parser.add_argument("--base-url")
    parser.add_argument("--token")
    subparsers = parser.add_subparsers(dest="command", required=True)

    project_list = subparsers.add_parser("project-list", help="List kanban projects.")
    project_list.add_argument("--search")
    project_list.set_defaults(func=cmd_project_list)

    project_create = subparsers.add_parser("project-create", help="Create one kanban project.")
    project_create.add_argument("--title", required=True)
    project_create.set_defaults(func=cmd_project_create)

    label_list = subparsers.add_parser("label-list", help="List tags for one project.")
    label_list.add_argument("--project-id", type=int)
    label_list.add_argument("--project")
    label_list.add_argument("--search")
    label_list.set_defaults(func=cmd_label_list)

    label_ensure = subparsers.add_parser("label-ensure", help="Ensure a project tag exists.")
    label_ensure.add_argument("--project-id", type=int)
    label_ensure.add_argument("--project")
    label_ensure.add_argument("--title", required=True)
    label_ensure.add_argument("--description")
    label_ensure.add_argument("--hex-color")
    label_ensure.set_defaults(func=cmd_label_ensure)

    label_delete = subparsers.add_parser("label-delete", help="Delete a project tag.")
    label_delete.add_argument("--project-id", type=int)
    label_delete.add_argument("--project")
    label_delete_group = label_delete.add_mutually_exclusive_group(required=True)
    label_delete_group.add_argument("--label-id", type=int)
    label_delete_group.add_argument("--title", "--label", dest="title")
    label_delete.set_defaults(func=cmd_label_delete)

    project_ensure_buckets = subparsers.add_parser(
        "project-ensure-buckets",
        help="Ensure the specified kanban columns exist in the requested order.",
    )
    project_ensure_buckets.add_argument("--project-id", type=int)
    project_ensure_buckets.add_argument("--project")
    project_ensure_buckets.add_argument("--bucket", action="append", required=True)
    project_ensure_buckets.set_defaults(func=cmd_project_ensure_buckets)

    task_list = subparsers.add_parser("task-list", help="List tasks in a project.")
    task_list.add_argument("--project-id", type=int)
    task_list.add_argument("--project")
    task_list.add_argument("--search")
    task_list.add_argument("--status")
    task_list.add_argument("--limit", type=int)
    task_list.set_defaults(func=cmd_task_list)

    task_snapshot_list = subparsers.add_parser("task-snapshot-list", help="List tasks with labels and relations.")
    task_snapshot_list.add_argument("--project-id", type=int)
    task_snapshot_list.add_argument("--project")
    task_snapshot_list.add_argument("--search")
    task_snapshot_list.add_argument("--status")
    task_snapshot_list.add_argument("--limit", type=int)
    task_snapshot_list.add_argument("--include-closed", action="store_true")
    task_snapshot_list.set_defaults(func=cmd_task_snapshot_list)

    task_watch_summary_list = subparsers.add_parser(
        "task-watch-summary-list",
        help="Load minimal task metadata for watch-summary rendering.",
    )
    task_watch_summary_list.add_argument("--project-id", type=int)
    task_watch_summary_list.add_argument("--project")
    task_watch_summary_list.add_argument("--task-id", dest="task_ids", action="append", type=int)
    task_watch_summary_list.add_argument("--task", dest="tasks", action="append")
    task_watch_summary_list.add_argument("--ignore-missing", action="store_true")
    task_watch_summary_list.set_defaults(func=cmd_task_watch_summary_list)

    task_find = subparsers.add_parser("task-find", help="Find tasks in a project by text.")
    task_find.add_argument("--project-id", type=int)
    task_find.add_argument("--project")
    task_find.add_argument("--query", required=True)
    task_find.add_argument("--status")
    task_find.add_argument("--limit", type=int)
    task_find.set_defaults(func=cmd_task_find)

    task_get = subparsers.add_parser("task-get", help="Get one task.")
    task_get_group = task_get.add_mutually_exclusive_group(required=True)
    task_get_group.add_argument("--task")
    task_get_group.add_argument("--task-id", type=int)
    task_get.add_argument("--project-id", type=int)
    task_get.add_argument("--project")
    task_get.set_defaults(func=cmd_task_get)

    task_relation_list = subparsers.add_parser("task-relation-list", help="List relations for one task.")
    task_relation_list_group = task_relation_list.add_mutually_exclusive_group(required=True)
    task_relation_list_group.add_argument("--task")
    task_relation_list_group.add_argument("--task-id", type=int)
    task_relation_list.add_argument("--project-id", type=int)
    task_relation_list.add_argument("--project")
    task_relation_list.set_defaults(func=cmd_task_relation_list)

    task_comment_list = subparsers.add_parser("task-comment-list", help="List comments for one task.")
    task_comment_list_group = task_comment_list.add_mutually_exclusive_group(required=True)
    task_comment_list_group.add_argument("--task")
    task_comment_list_group.add_argument("--task-id", type=int)
    task_comment_list.add_argument("--project-id", type=int)
    task_comment_list.add_argument("--project")
    task_comment_list.set_defaults(func=cmd_task_comment_list)

    task_comment_create = subparsers.add_parser("task-comment-create", help="Create a comment for one task.")
    task_comment_create_group = task_comment_create.add_mutually_exclusive_group(required=True)
    task_comment_create_group.add_argument("--task")
    task_comment_create_group.add_argument("--task-id", type=int)
    task_comment_create.add_argument("--project-id", type=int)
    task_comment_create.add_argument("--project")
    task_comment_create.add_argument("--comment")
    task_comment_create.add_argument("--comment-file")
    task_comment_create.set_defaults(func=cmd_task_comment_create)

    task_label_list = subparsers.add_parser("task-label-list", help="List tags for one task.")
    task_label_list_group = task_label_list.add_mutually_exclusive_group(required=True)
    task_label_list_group.add_argument("--task")
    task_label_list_group.add_argument("--task-id", type=int)
    task_label_list.add_argument("--project-id", type=int)
    task_label_list.add_argument("--project")
    task_label_list.set_defaults(func=cmd_task_label_list)

    task_label_add = subparsers.add_parser("task-label-add", help="Add a tag to one task.")
    task_label_add_group = task_label_add.add_mutually_exclusive_group(required=True)
    task_label_add_group.add_argument("--task")
    task_label_add_group.add_argument("--task-id", type=int)
    task_label_add.add_argument("--project-id", type=int)
    task_label_add.add_argument("--project")
    task_label_add_label_group = task_label_add.add_mutually_exclusive_group(required=True)
    task_label_add_label_group.add_argument("--label-id", type=int)
    task_label_add_label_group.add_argument("--title", "--label", dest="title")
    task_label_add.set_defaults(func=cmd_task_label_add)

    task_label_remove = subparsers.add_parser("task-label-remove", help="Remove a tag from one task.")
    task_label_remove_group = task_label_remove.add_mutually_exclusive_group(required=True)
    task_label_remove_group.add_argument("--task")
    task_label_remove_group.add_argument("--task-id", type=int)
    task_label_remove.add_argument("--project-id", type=int)
    task_label_remove.add_argument("--project")
    task_label_remove_label_group = task_label_remove.add_mutually_exclusive_group(required=True)
    task_label_remove_label_group.add_argument("--label-id", type=int)
    task_label_remove_label_group.add_argument("--title", "--label", dest="title")
    task_label_remove.set_defaults(func=cmd_task_label_remove)

    task_create = subparsers.add_parser("task-create", help="Create a task.")
    task_create.add_argument("--project-id", type=int)
    task_create.add_argument("--project")
    task_create.add_argument("--title", required=True)
    task_create.add_argument("--description")
    task_create.add_argument("--description-file")
    task_create.add_argument("--reference")
    task_create.add_argument("--status")
    task_create.set_defaults(func=cmd_task_create)

    task_update = subparsers.add_parser("task-update", help="Update an existing task.")
    task_update_group = task_update.add_mutually_exclusive_group(required=True)
    task_update_group.add_argument("--task")
    task_update_group.add_argument("--task-id", type=int)
    task_update.add_argument("--project-id", type=int)
    task_update.add_argument("--project")
    task_update.add_argument("--title")
    task_update.add_argument("--description")
    task_update.add_argument("--description-file")
    task_update.add_argument("--append-description")
    task_update.add_argument("--append-description-file")
    task_update.add_argument("--reference")
    task_update.add_argument(
        "--done",
        type=lambda value: value.lower() == "true",
        help="Set the backend's human-resolved flag directly. This is separate from moving an A2O task to the Done lane.",
    )
    task_update.add_argument("--priority", type=int)
    task_update.set_defaults(func=cmd_task_update)

    task_transition = subparsers.add_parser("task-transition", help="Move a task to a named kanban status column.")
    task_transition_group = task_transition.add_mutually_exclusive_group(required=True)
    task_transition_group.add_argument("--task")
    task_transition_group.add_argument("--task-id", type=int)
    task_transition.add_argument("--project-id", type=int)
    task_transition.add_argument("--project")
    task_transition.add_argument("--status", required=True)
    task_transition.add_argument(
        "--sync-done-state",
        "--sync-completion-state",
        "--complete",
        dest="sync_done_state",
        action="store_true",
        help=(
            "Also synchronize Kanban's human-resolved flag. "
            "A2O normally moves tasks to the Done lane without resolving them; "
            "use this only when a human confirmation should also mark the task resolved."
        ),
    )
    task_transition.set_defaults(func=cmd_task_transition)

    task_reorder = subparsers.add_parser("task-reorder", help="Reorder a task within a kanban lane.")
    task_reorder_group = task_reorder.add_mutually_exclusive_group(required=True)
    task_reorder_group.add_argument("--task")
    task_reorder_group.add_argument("--task-id", type=int)
    task_reorder.add_argument("--project-id", type=int)
    task_reorder.add_argument("--project")
    target_lane_group = task_reorder.add_mutually_exclusive_group()
    target_lane_group.add_argument("--status", help="Target lane name. Defaults to the task's current lane.")
    target_lane_group.add_argument("--lane-id", "--bucket-id", "--column-id", dest="lane_id", type=int)
    task_reorder.add_argument("--position", required=True, type=int, help="Zero-based position inside the target lane.")
    task_reorder.set_defaults(func=cmd_task_reorder)

    task_relation_create = subparsers.add_parser("task-relation-create", help="Create a task relation.")
    task_relation_create_group = task_relation_create.add_mutually_exclusive_group(required=True)
    task_relation_create_group.add_argument("--task")
    task_relation_create_group.add_argument("--task-id", type=int)
    task_relation_create.add_argument("--project-id", type=int)
    task_relation_create.add_argument("--project")
    other_create_group = task_relation_create.add_mutually_exclusive_group(required=True)
    other_create_group.add_argument("--other-task")
    other_create_group.add_argument("--other-task-id", type=int)
    task_relation_create.add_argument("--other-project-id", type=int)
    task_relation_create.add_argument("--other-project")
    task_relation_create.add_argument("--relation-kind", choices=RELATION_KIND_CHOICES, required=True)
    task_relation_create.set_defaults(func=cmd_task_relation_create)

    task_relation_delete = subparsers.add_parser("task-relation-delete", help="Delete a task relation.")
    task_relation_delete_group = task_relation_delete.add_mutually_exclusive_group(required=True)
    task_relation_delete_group.add_argument("--task")
    task_relation_delete_group.add_argument("--task-id", type=int)
    task_relation_delete.add_argument("--project-id", type=int)
    task_relation_delete.add_argument("--project")
    other_delete_group = task_relation_delete.add_mutually_exclusive_group(required=True)
    other_delete_group.add_argument("--other-task")
    other_delete_group.add_argument("--other-task-id", type=int)
    task_relation_delete.add_argument("--other-project-id", type=int)
    task_relation_delete.add_argument("--other-project")
    task_relation_delete.add_argument("--relation-kind", choices=RELATION_KIND_CHOICES, required=True)
    task_relation_delete.set_defaults(func=cmd_task_relation_delete)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except Exception as exc:  # noqa: BLE001
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
