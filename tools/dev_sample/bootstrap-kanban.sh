#!/usr/bin/env bash
set -eu

source "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
git update-ref refs/heads/a2o/dev-sample-live HEAD

KANBAN=(python3 tools/kanban/kanban_cli.py --backend kanbalone --base-url "$A2O_DEV_SAMPLE_KANBAN_URL")

project_id="$("${KANBAN[@]}" project-list | ruby -rjson -e 'name = ENV.fetch("A2O_DEV_SAMPLE_PROJECT"); item = JSON.parse(STDIN.read).find { |project| project.fetch("name", project["title"]) == name || project["title"] == name }; puts item && item.fetch("id")')"
if [ -z "$project_id" ]; then
  "${KANBAN[@]}" project-create --title "$A2O_DEV_SAMPLE_PROJECT" >/dev/null
  project_id="$("${KANBAN[@]}" project-list | ruby -rjson -e 'name = ENV.fetch("A2O_DEV_SAMPLE_PROJECT"); item = JSON.parse(STDIN.read).find { |project| project.fetch("name", project["title"]) == name || project["title"] == name }; puts item && item.fetch("id")')"
fi

python3 - "$A2O_DEV_SAMPLE_KANBAN_URL" "$project_id" <<'PY'
import json
import sys
import urllib.request

base_url, board_id = sys.argv[1].rstrip("/"), sys.argv[2]
board = json.load(urllib.request.urlopen(f"{base_url}/api/boards/{board_id}"))
lanes = board.get("lanes") or []
has_done = any((lane.get("name") or "") == "Done" for lane in lanes)
if not has_done:
    for lane in lanes:
        if (lane.get("name") or "") == "done":
            request = urllib.request.Request(
                f"{base_url}/api/lanes/{lane['id']}",
                data=json.dumps({"name": "Done"}).encode(),
                headers={"content-type": "application/json"},
                method="PATCH",
            )
            urllib.request.urlopen(request).read()
            break
PY

"${KANBAN[@]}" project-ensure-buckets \
  --project "$A2O_DEV_SAMPLE_PROJECT" \
  --bucket Backlog \
  --bucket "To do" \
  --bucket "In progress" \
  --bucket "In review" \
  --bucket Inspection \
  --bucket Merging \
  --bucket todo \
  --bucket doing \
  --bucket Done >/dev/null

"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title repo:app --hex-color '#4b7f52' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title repo:lib --hex-color '#0f766e' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title trigger:auto-implement --hex-color '#2563eb' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title trigger:investigate --hex-color '#f59e0b' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title a2o:decomposed --hex-color '#0891b2' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title trigger:auto-parent --hex-color '#7c3aed' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title a2o:draft-child --hex-color '#8b5cf6' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title blocked --hex-color '#dc2626' >/dev/null

echo "dev_sample_project=$A2O_DEV_SAMPLE_PROJECT"
echo "dev_sample_kanbalone_url=$A2O_DEV_SAMPLE_KANBAN_URL"
