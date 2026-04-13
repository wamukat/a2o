#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


A3_ENGINE_DIR = Path(__file__).resolve().parents[2]
ROOT_DIR = A3_ENGINE_DIR.parent
CLI = [sys.executable, str(A3_ENGINE_DIR / "tools" / "kanban" / "cli.py"), "--backend", "soloboard"]
BOOTSTRAP = A3_ENGINE_DIR / "tools" / "kanban" / "bootstrap_soloboard.py"
BOOTSTRAP_CONFIG = ROOT_DIR / "scripts" / "a3-projects" / "portal" / "inject" / "soloboard-bootstrap.json"


def run_cli(*args: str) -> object:
    completed = subprocess.run(
        [*CLI, *args],
        cwd=ROOT_DIR,
        check=True,
        capture_output=True,
        text=True,
    )
    stdout = completed.stdout.strip()
    return json.loads(stdout) if stdout else None


def main() -> int:
    base_url = os.environ.get("SOLOBOARD_BASE_URL", "http://127.0.0.1:3460")
    common = ("--base-url", base_url)

    subprocess.run(
        [sys.executable, str(BOOTSTRAP), "--config", str(BOOTSTRAP_CONFIG), "--base-url", base_url],
        cwd=ROOT_DIR,
        check=True,
    )

    parent = run_cli(*common, "task-create", "--project", "Portal", "--title", "Smoke parent", "--description", "smoke parent", "--status", "To do")
    child = run_cli(*common, "task-create", "--project", "Portal", "--title", "Smoke child", "--description", "smoke child", "--status", "To do")

    parent_ref = str(parent["ref"])
    child_ref = str(child["ref"])

    run_cli(*common, "task-comment-create", "--task", child_ref, "--comment", "smoke comment")
    run_cli(*common, "label-ensure", "--project", "Portal", "--title", "smoke-tag", "--hex-color", "#555555")
    run_cli(*common, "task-label-add", "--task", child_ref, "--label", "smoke-tag")
    run_cli(*common, "task-update", "--task", child_ref, "--title", "Smoke child updated", "--done", "true")
    run_cli(*common, "task-transition", "--task", child_ref, "--status", "Inspection")
    run_cli(*common, "task-relation-create", "--task", child_ref, "--other-task", parent_ref, "--relation-kind", "parenttask")

    detail = run_cli(*common, "task-get", "--task", child_ref)
    relations = run_cli(*common, "task-relation-list", "--task", child_ref)
    comments = run_cli(*common, "task-comment-list", "--task", child_ref)
    listing = run_cli(*common, "task-list", "--project", "Portal", "--status", "Inspection", "--limit", "20")

    if not any(item.get("id") == int(parent["id"]) for item in relations.get("parenttask", [])):
        raise RuntimeError("parent relation was not observed in smoke")
    if not comments or not any(item.get("comment") == "smoke comment" for item in comments):
        raise RuntimeError("comment was not observed in smoke")
    if not any(item.get("ref") == child_ref for item in listing):
        raise RuntimeError("task-list did not include smoke child")

    run_cli(*common, "task-relation-delete", "--task", child_ref, "--other-task", parent_ref, "--relation-kind", "parenttask")
    run_cli(*common, "task-label-remove", "--task", child_ref, "--label", "smoke-tag")

    final_detail = run_cli(*common, "task-get", "--task", child_ref)
    final_relations = run_cli(*common, "task-relation-list", "--task", child_ref)
    final_labels = run_cli(*common, "task-label-list", "--task", child_ref)

    if final_relations:
        raise RuntimeError("relation delete was not observed in smoke")
    if final_labels:
        raise RuntimeError("label delete was not observed in smoke")

    summary = {
        "parent": parent_ref,
        "child": child_ref,
        "detail": {
            "status": detail.get("status"),
            "done": detail.get("done"),
        },
        "final_detail": {
            "status": final_detail.get("status"),
            "done": final_detail.get("done"),
        },
        "comments": len(comments),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
