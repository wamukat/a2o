#!/usr/bin/env bash
set -eu

source "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
git update-ref refs/heads/a2o/dev-sample-live HEAD

KANBAN=(go run ./agent-go/cmd/a3 kanban cli --backend kanbalone --base-url "$A2O_DEV_SAMPLE_KANBAN_URL")

project_id="$("${KANBAN[@]}" project-list | ruby -rjson -e 'name = ENV.fetch("A2O_DEV_SAMPLE_PROJECT"); item = JSON.parse(STDIN.read).find { |project| project.fetch("name", project["title"]) == name || project["title"] == name }; puts item && item.fetch("id")')"
if [ -z "$project_id" ]; then
  "${KANBAN[@]}" project-create --title "$A2O_DEV_SAMPLE_PROJECT" >/dev/null
  project_id="$("${KANBAN[@]}" project-list | ruby -rjson -e 'name = ENV.fetch("A2O_DEV_SAMPLE_PROJECT"); item = JSON.parse(STDIN.read).find { |project| project.fetch("name", project["title"]) == name || project["title"] == name }; puts item && item.fetch("id")')"
fi

ruby -rjson -rnet/http -ruri - "$A2O_DEV_SAMPLE_KANBAN_URL" "$project_id" <<'RUBY'
base_url = ARGV.fetch(0).sub(%r{/+\z}, "")
board_id = ARGV.fetch(1)
board = JSON.parse(Net::HTTP.get(URI("#{base_url}/api/boards/#{board_id}")))
lanes = board.fetch("lanes", [])
unless lanes.any? { |lane| lane["name"] == "Done" }
  lane = lanes.find { |candidate| candidate["name"] == "done" }
  if lane
    uri = URI("#{base_url}/api/lanes/#{lane.fetch("id")}")
    request = Net::HTTP::Patch.new(uri)
    request["content-type"] = "application/json"
    request.body = JSON.dump({ "name" => "Done" })
    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
  end
end
RUBY

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
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title repo:docs --hex-color '#0369a1' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title trigger:auto-implement --hex-color '#2563eb' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title trigger:investigate --hex-color '#f59e0b' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title a2o:decomposed --hex-color '#0891b2' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title trigger:auto-parent --hex-color '#7c3aed' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title a2o:draft-child --hex-color '#8b5cf6' >/dev/null
"${KANBAN[@]}" label-ensure --project "$A2O_DEV_SAMPLE_PROJECT" --title blocked --hex-color '#dc2626' >/dev/null

echo "dev_sample_project=$A2O_DEV_SAMPLE_PROJECT"
echo "dev_sample_kanbalone_url=$A2O_DEV_SAMPLE_KANBAN_URL"
