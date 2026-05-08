package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

const defaultKanbaloneURL = "http://localhost:3000"

type kanbanCLIConfig struct {
	BaseURL string
	Token   string
}

type kanbaloneHTTPClient struct {
	baseURL string
	token   string
	client  *http.Client
}

type kanbaloneHTTPError struct {
	StatusCode int
	Body       string
	Path       string
}

func (e kanbaloneHTTPError) Error() string {
	if strings.TrimSpace(e.Body) != "" {
		return e.Body
	}
	return fmt.Sprintf("HTTP %d %s", e.StatusCode, e.Path)
}

func kanbaloneNotFound(err error) bool {
	var httpErr kanbaloneHTTPError
	return errors.As(err, &httpErr) && httpErr.StatusCode == http.StatusNotFound
}

func runKanbanCLI(args []string, stdout io.Writer, stderr io.Writer) error {
	config, remaining, err := parseKanbanCLIConfig(args, stderr)
	if err != nil {
		return err
	}
	if len(remaining) == 0 {
		return errors.New("missing kanban cli command")
	}
	client := kanbaloneHTTPClient{
		baseURL: strings.TrimRight(config.BaseURL, "/"),
		token:   config.Token,
		client:  &http.Client{Timeout: 30 * time.Second},
	}
	command := remaining[0]
	commandArgs := remaining[1:]
	var payload any
	switch command {
	case "project-list":
		payload, err = runKanbanCLIProjectList(client, commandArgs, stderr)
	case "project-create":
		payload, err = runKanbanCLIProjectCreate(client, commandArgs, stderr)
	case "project-ensure-buckets":
		payload, err = runKanbanCLIProjectEnsureBuckets(client, commandArgs, stderr)
	case "label-list":
		payload, err = runKanbanCLILabelList(client, commandArgs, stderr)
	case "label-ensure":
		payload, err = runKanbanCLILabelEnsure(client, commandArgs, stderr)
	case "label-delete":
		payload, err = runKanbanCLILabelDelete(client, commandArgs, stderr)
	case "task-list", "task-find":
		payload, err = runKanbanCLITaskList(client, command, commandArgs, stderr)
	case "task-snapshot-list":
		payload, err = runKanbanCLITaskSnapshotList(client, commandArgs, stderr)
	case "task-watch-summary-list":
		payload, err = runKanbanCLITaskWatchSummaryList(client, commandArgs, stderr)
	case "task-get":
		payload, err = runKanbanCLITaskGet(client, commandArgs, stderr)
	case "task-relation-list":
		payload, err = runKanbanCLITaskRelationList(client, commandArgs, stderr)
	case "task-comment-list":
		payload, err = runKanbanCLITaskCommentList(client, commandArgs, stderr)
	case "task-comment-create":
		payload, err = runKanbanCLITaskCommentCreate(client, commandArgs, stderr)
	case "task-event-list":
		payload, err = runKanbanCLITaskEventList(client, commandArgs, stderr)
	case "task-event-create":
		payload, err = runKanbanCLITaskEventCreate(client, commandArgs, stderr)
	case "task-label-list":
		payload, err = runKanbanCLITaskLabelList(client, commandArgs, stderr)
	case "task-label-reason-list":
		payload, err = runKanbanCLITaskLabelReasonList(client, commandArgs, stderr)
	case "task-label-add":
		payload, err = runKanbanCLITaskLabelAdd(client, commandArgs, stderr)
	case "task-label-remove":
		payload, err = runKanbanCLITaskLabelRemove(client, commandArgs, stderr)
	case "task-create":
		payload, err = runKanbanCLITaskCreate(client, commandArgs, stderr)
	case "task-update":
		payload, err = runKanbanCLITaskUpdate(client, commandArgs, stderr)
	case "task-transition":
		payload, err = runKanbanCLITaskTransition(client, commandArgs, stderr)
	case "task-reorder":
		payload, err = runKanbanCLITaskReorder(client, commandArgs, stderr)
	case "task-relation-create":
		payload, err = runKanbanCLITaskRelationCreate(client, commandArgs, stderr)
	case "task-relation-delete":
		payload, err = runKanbanCLITaskRelationDelete(client, commandArgs, stderr)
	case "task-external-reference-set":
		payload, err = runKanbanCLITaskExternalReferenceSet(client, commandArgs, stderr)
	default:
		return fmt.Errorf("unsupported kanban cli command: %s", command)
	}
	if err != nil {
		return err
	}
	return writePrettyJSON(stdout, payload)
}

func parseKanbanCLIConfig(args []string, stderr io.Writer) (kanbanCLIConfig, []string, error) {
	flags := flag.NewFlagSet("a2o kanban cli", flag.ContinueOnError)
	flags.SetOutput(stderr)
	backend := flags.String("backend", "", "kanban backend")
	baseURL := flags.String("base-url", "", "Kanbalone base URL")
	token := flags.String("token", "", "Kanbalone API token")
	if err := flags.Parse(args); err != nil {
		return kanbanCLIConfig{}, nil, err
	}
	backendKind, err := resolveKanbanBackend(*backend)
	if err != nil {
		return kanbanCLIConfig{}, nil, err
	}
	resolvedBaseURL, err := resolveKanbanBaseURL(*baseURL, backendKind)
	if err != nil {
		return kanbanCLIConfig{}, nil, err
	}
	resolvedToken, err := resolveKanbanToken(*token, backendKind)
	if err != nil {
		return kanbanCLIConfig{}, nil, err
	}
	return kanbanCLIConfig{BaseURL: resolvedBaseURL, Token: resolvedToken}, flags.Args(), nil
}

func resolveKanbanBackend(cliValue string) (string, error) {
	value := strings.ToLower(strings.TrimSpace(cliValue))
	if value == "" {
		value = strings.ToLower(strings.TrimSpace(os.Getenv("KANBAN_BACKEND")))
	}
	if value == "" {
		value = "kanbalone"
	}
	if value == "soloboard" {
		return "", errors.New("Removed kanban backend: soloboard. migration_required=true replacement_backend=kanbalone. Use KANBAN_BACKEND=kanbalone or omit KANBAN_BACKEND.")
	}
	if value != "kanbalone" {
		return "", fmt.Errorf("Unsupported kanban backend: %s. Supported: kanbalone", value)
	}
	return value, nil
}

func resolveKanbanBaseURL(cliValue string, backendKind string) (string, error) {
	if backendKind != "kanbalone" {
		return "", fmt.Errorf("Unsupported kanban backend: %s", backendKind)
	}
	if cliValue == "" && os.Getenv("KANBALONE_BASE_URL") == "" && os.Getenv("SOLOBOARD_BASE_URL") != "" {
		return "", errors.New("Removed environment variable: SOLOBOARD_BASE_URL. migration_required=true replacement_env=KANBALONE_BASE_URL.")
	}
	if cliValue != "" {
		return strings.TrimRight(cliValue, "/"), nil
	}
	if value := os.Getenv("KANBALONE_BASE_URL"); value != "" {
		return strings.TrimRight(value, "/"), nil
	}
	return defaultKanbaloneURL, nil
}

func resolveKanbanToken(cliValue string, backendKind string) (string, error) {
	if backendKind != "kanbalone" {
		return "", fmt.Errorf("Unsupported kanban backend: %s", backendKind)
	}
	if cliValue == "" && os.Getenv("KANBALONE_API_TOKEN") == "" && os.Getenv("SOLOBOARD_API_TOKEN") != "" {
		return "", errors.New("Removed environment variable: SOLOBOARD_API_TOKEN. migration_required=true replacement_env=KANBALONE_API_TOKEN.")
	}
	if cliValue != "" {
		return cliValue, nil
	}
	if value := os.Getenv("KANBALONE_API_TOKEN"); value != "" {
		return value, nil
	}
	return "", nil
}

func (c kanbaloneHTTPClient) request(method, path string, payload any, out any) error {
	var body io.Reader
	if payload != nil {
		raw, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		body = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, c.baseURL+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "a2o-kanban-cli/1.0")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return kanbaloneHTTPError{StatusCode: resp.StatusCode, Body: string(raw), Path: path}
	}
	if out == nil || len(raw) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("unexpected non-JSON response from REST API: %s: %w", path, err)
	}
	return nil
}

func writePrettyJSON(w io.Writer, payload any) error {
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	return encoder.Encode(payload)
}

func readTextArg(value, filePath string) (string, bool, error) {
	if value != "" {
		return value, true, nil
	}
	if filePath == "" {
		return "", false, nil
	}
	if filePath == "-" {
		raw, err := io.ReadAll(os.Stdin)
		return string(raw), true, err
	}
	raw, err := os.ReadFile(filePath)
	return string(raw), true, err
}

func readJSONArg(value, filePath string) (any, bool, error) {
	raw, ok, err := readTextArg(value, filePath)
	if err != nil || !ok || strings.TrimSpace(raw) == "" {
		return nil, ok, err
	}
	var decoded any
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return nil, true, errors.New("JSON argument is invalid.")
	}
	return decoded, true, nil
}

func asMap(value any) map[string]any {
	if item, ok := value.(map[string]any); ok {
		return item
	}
	return map[string]any{}
}

func asSlice(value any) []any {
	if items, ok := value.([]any); ok {
		return items
	}
	return nil
}

func intValue(value any) int {
	switch typed := value.(type) {
	case int:
		return typed
	case int64:
		return int(typed)
	case float64:
		return int(typed)
	case json.Number:
		result, _ := typed.Int64()
		return int(result)
	case string:
		result, _ := strconv.Atoi(strings.TrimSpace(typed))
		return result
	default:
		return 0
	}
}

func boolValue(value any) bool {
	if typed, ok := value.(bool); ok {
		return typed
	}
	return false
}

func stringValue(value any) string {
	if value == nil {
		return ""
	}
	return fmt.Sprint(value)
}

func canonicalProjectRefTitle(project string) string {
	project = strings.TrimSpace(project)
	return strings.TrimSuffix(project, " Staging")
}

func shortTaskRef(ticket map[string]any) string {
	if short := strings.TrimSpace(stringValue(ticket["shortRef"])); short != "" {
		return short
	}
	if ref := strings.TrimSpace(stringValue(ticket["ref"])); ref != "" {
		if index := strings.LastIndex(ref, "#"); index >= 0 {
			return ref[index:]
		}
	}
	return fmt.Sprintf("#%d", intValue(ticket["id"]))
}

func canonicalTaskRef(boardTitle string, ticket map[string]any) string {
	if ref := strings.TrimSpace(stringValue(ticket["ref"])); ref != "" {
		return ref
	}
	return fmt.Sprintf("%s#%d", canonicalProjectRefTitle(boardTitle), intValue(ticket["id"]))
}

func parseTaskID(ref string) (int, bool) {
	raw := strings.TrimSpace(ref)
	if raw == "" {
		return 0, false
	}
	if id, err := strconv.Atoi(raw); err == nil {
		return id, true
	}
	if strings.HasPrefix(raw, "#") {
		id, err := strconv.Atoi(strings.TrimPrefix(raw, "#"))
		return id, err == nil
	}
	if index := strings.LastIndex(raw, "#"); index >= 0 {
		id, err := strconv.Atoi(raw[index+1:])
		return id, err == nil
	}
	return 0, false
}

func parseISOEpoch(value any) int64 {
	raw := strings.TrimSpace(stringValue(value))
	if raw == "" {
		return 0
	}
	parsed, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return 0
	}
	return parsed.Unix()
}

func normalizeLabel(label map[string]any) map[string]any {
	return map[string]any{
		"id":          intValue(label["id"]),
		"title":       firstString(label["name"], label["title"]),
		"description": firstString(label["description"]),
		"hex_color":   firstString(label["color"], label["hex_color"]),
	}
}

func firstString(values ...any) string {
	for _, value := range values {
		if raw := stringValue(value); raw != "" {
			return raw
		}
	}
	return ""
}

func normalizeTicket(ticket map[string]any, boardTitle string, boardShell map[string]any) map[string]any {
	laneID := intValue(ticket["laneId"])
	status := laneName(boardShell, laneID)
	return map[string]any{
		"id":                  intValue(ticket["id"]),
		"project_id":          intValue(ticket["boardId"]),
		"column_id":           laneID,
		"bucket_id":           laneID,
		"priority":            intValue(ticket["priority"]),
		"done":                boolValue(ticket["isResolved"]),
		"is_archived":         boolValue(mapFirstPresent(ticket, "isArchived", "is_archived")),
		"status":              status,
		"title":               firstString(ticket["title"]),
		"description":         firstString(ticket["bodyMarkdown"]),
		"reference":           canonicalTaskRef(boardTitle, ticket),
		"remote":              ticket["remote"],
		"external_references": mapFirstPresent(ticket, "externalReferences", "external_references"),
		"identifier":          shortTaskRef(ticket),
		"index":               intValue(ticket["id"]),
		"position":            intValue(ticket["position"]),
		"project":             boardTitle,
		"date_modification":   parseISOEpoch(ticket["updatedAt"]),
	}
}

func mapFirstPresent(item map[string]any, keys ...string) any {
	for _, key := range keys {
		if value, ok := item[key]; ok {
			return value
		}
	}
	return nil
}

func normalizeTaskDetail(ticket map[string]any, boardTitle string) map[string]any {
	normalized := map[string]any{}
	for key, value := range ticket {
		normalized[key] = value
	}
	normalized["ref"] = canonicalTaskRef(boardTitle, ticket)
	normalized["short_ref"] = shortTaskRef(ticket)
	normalized["project"] = boardTitle
	normalized["identifier"] = shortTaskRef(ticket)
	normalized["index"] = intValue(ticket["id"])
	normalized["done"] = boolValue(ticket["done"])
	normalized["is_archived"] = boolValue(ticket["is_archived"])
	return normalized
}

func normalizeTaskSummary(ticket map[string]any, boardTitle string) map[string]any {
	return map[string]any{
		"ref":               canonicalTaskRef(boardTitle, ticket),
		"short_ref":         shortTaskRef(ticket),
		"project":           boardTitle,
		"id":                intValue(ticket["id"]),
		"identifier":        shortTaskRef(ticket),
		"index":             intValue(ticket["id"]),
		"title":             firstString(ticket["title"]),
		"description":       firstString(ticket["description"], ticket["bodyMarkdown"]),
		"status":            ticket["status"],
		"done":              boolValue(ticket["done"]),
		"is_archived":       boolValue(ticket["is_archived"]),
		"priority":          intValue(ticket["priority"]),
		"reference":         firstString(ticket["reference"], ticket["ref"]),
		"date_modification": intValue(ticket["date_modification"]),
	}
}

func laneName(boardShell map[string]any, laneID int) string {
	for _, lane := range asSlice(boardShell["lanes"]) {
		laneMap := asMap(lane)
		if intValue(laneMap["id"]) == laneID {
			return firstString(laneMap["name"])
		}
	}
	return ""
}

func laneIDByName(boardShell map[string]any, name string) (int, error) {
	normalized := strings.ToLower(strings.TrimSpace(name))
	var available []string
	for _, lane := range asSlice(boardShell["lanes"]) {
		laneMap := asMap(lane)
		laneName := firstString(laneMap["name"])
		available = append(available, laneName)
		if strings.ToLower(strings.TrimSpace(laneName)) == normalized {
			return intValue(laneMap["id"]), nil
		}
	}
	return 0, fmt.Errorf("Lane not found: %s. Available: %s", name, strings.Join(available, ", "))
}

func getBoards(client kanbaloneHTTPClient) ([]any, error) {
	var response map[string]any
	if err := client.request("GET", "/api/boards", nil, &response); err != nil {
		return nil, err
	}
	boards := asSlice(response["boards"])
	if boards == nil {
		return nil, errors.New("Unexpected boards response.")
	}
	return boards, nil
}

func resolveBoardID(client kanbaloneHTTPClient, boardID int, project string) (int, error) {
	if boardID > 0 {
		return boardID, nil
	}
	if strings.TrimSpace(project) == "" {
		return 0, errors.New("--project-id or --project is required.")
	}
	boards, err := getBoards(client)
	if err != nil {
		return 0, err
	}
	var exact []map[string]any
	var partial []map[string]any
	for _, board := range boards {
		boardMap := asMap(board)
		title := firstString(boardMap["name"], boardMap["title"])
		if title == project {
			exact = append(exact, boardMap)
		} else if strings.Contains(strings.ToLower(title), strings.ToLower(project)) {
			partial = append(partial, boardMap)
		}
	}
	if len(exact) == 1 {
		return intValue(exact[0]["id"]), nil
	}
	if len(exact) == 0 && len(partial) == 1 {
		return intValue(partial[0]["id"]), nil
	}
	if len(exact) > 0 || len(partial) > 0 {
		candidates := exact
		if len(candidates) == 0 {
			candidates = partial
		}
		parts := make([]string, 0, len(candidates))
		for _, candidate := range candidates {
			parts = append(parts, fmt.Sprintf("%d:%s", intValue(candidate["id"]), firstString(candidate["name"], candidate["title"])))
		}
		return 0, errors.New("Project name is ambiguous: " + strings.Join(parts, ", "))
	}
	return 0, fmt.Errorf("Project not found: %s", project)
}

func boardTitle(client kanbaloneHTTPClient, boardID int) (string, error) {
	boards, err := getBoards(client)
	if err != nil {
		return "", err
	}
	for _, board := range boards {
		boardMap := asMap(board)
		if intValue(boardMap["id"]) == boardID {
			return firstString(boardMap["name"], boardMap["title"], boardID), nil
		}
	}
	return "", fmt.Errorf("Project not found: %d", boardID)
}

func boardShell(client kanbaloneHTTPClient, boardID int) (map[string]any, error) {
	var response map[string]any
	if err := client.request("GET", fmt.Sprintf("/api/boards/%d", boardID), nil, &response); err != nil {
		return nil, err
	}
	return response, nil
}

func boardTags(client kanbaloneHTTPClient, boardID int) ([]any, error) {
	var response map[string]any
	if err := client.request("GET", fmt.Sprintf("/api/boards/%d/tags", boardID), nil, &response); err != nil {
		return nil, err
	}
	tags := asSlice(response["tags"])
	if tags == nil {
		return nil, errors.New("Unexpected tags response.")
	}
	return tags, nil
}

func taskByID(client kanbaloneHTTPClient, taskID int) (map[string]any, map[string]any, string, error) {
	var ticket map[string]any
	if err := client.request("GET", fmt.Sprintf("/api/tickets/%d", taskID), nil, &ticket); err != nil {
		return nil, nil, "", err
	}
	boardID := intValue(ticket["boardId"])
	shell, err := boardShell(client, boardID)
	if err != nil {
		return nil, nil, "", err
	}
	title := firstString(asMap(shell["board"])["name"], boardID)
	normalized := normalizeTicket(ticket, title, shell)
	normalized["bodyMarkdown"] = firstString(ticket["bodyMarkdown"])
	normalized["tags"] = mapFirstPresent(ticket, "tags")
	normalized["comments"] = mapFirstPresent(ticket, "comments")
	normalized["blockerIds"] = mapFirstPresent(ticket, "blockerIds")
	normalized["parentTicketId"] = mapFirstPresent(ticket, "parentTicketId")
	return normalized, shell, title, nil
}

func resolveTaskID(_ kanbaloneHTTPClient, taskID int, taskRef string) (int, error) {
	if taskID > 0 {
		return taskID, nil
	}
	if id, ok := parseTaskID(taskRef); ok {
		return id, nil
	}
	return 0, errors.New("--task or --task-id is required.")
}

type projectFlagSet struct {
	project   string
	projectID int
	search    string
}

func addProjectFlags(flags *flag.FlagSet, target *projectFlagSet) {
	flags.StringVar(&target.project, "project", "", "project name")
	flags.IntVar(&target.projectID, "project-id", 0, "project ID")
	flags.StringVar(&target.search, "search", "", "search query")
}

type taskFlagSet struct {
	projectFlagSet
	task   string
	taskID int
}

func addTaskFlags(flags *flag.FlagSet, target *taskFlagSet) {
	addProjectFlags(flags, &target.projectFlagSet)
	flags.StringVar(&target.task, "task", "", "task ref")
	flags.IntVar(&target.taskID, "task-id", 0, "task ID")
}

func runKanbanCLIProjectList(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("project-list", flag.ContinueOnError)
	flags.SetOutput(stderr)
	search := flags.String("search", "", "search")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	boards, err := getBoards(client)
	if err != nil {
		return nil, err
	}
	var result []map[string]any
	for _, board := range boards {
		boardMap := asMap(board)
		title := firstString(boardMap["name"], boardMap["title"])
		if *search != "" && !strings.Contains(strings.ToLower(title), strings.ToLower(*search)) {
			continue
		}
		result = append(result, map[string]any{"id": intValue(boardMap["id"]), "title": title, "is_archived": false})
	}
	return result, nil
}

func runKanbanCLIProjectCreate(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("project-create", flag.ContinueOnError)
	flags.SetOutput(stderr)
	title := flags.String("title", "", "title")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	var created map[string]any
	if err := client.request("POST", "/api/boards", map[string]any{"name": *title}, &created); err != nil {
		return nil, err
	}
	board := asMap(created["board"])
	return map[string]any{"id": intValue(board["id"]), "title": firstString(board["name"], board["title"]), "is_archived": false}, nil
}

func runKanbanCLIProjectEnsureBuckets(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("project-ensure-buckets", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var pf projectFlagSet
	addProjectFlags(flags, &pf)
	var buckets multiFlag
	flags.Var(&buckets, "bucket", "bucket")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	boardID, err := resolveBoardID(client, pf.projectID, pf.project)
	if err != nil {
		return nil, err
	}
	shell, err := boardShell(client, boardID)
	if err != nil {
		return nil, err
	}
	existing := map[string]map[string]any{}
	for _, lane := range asSlice(shell["lanes"]) {
		laneMap := asMap(lane)
		existing[strings.ToLower(firstString(laneMap["name"]))] = laneMap
	}
	var laneIDs []int
	for _, bucket := range buckets {
		lane := existing[strings.ToLower(strings.TrimSpace(bucket))]
		if lane == nil {
			var created map[string]any
			if err := client.request("POST", fmt.Sprintf("/api/boards/%d/lanes", boardID), map[string]any{"name": bucket}, &created); err != nil {
				return nil, err
			}
			lane = created
		}
		laneIDs = append(laneIDs, intValue(lane["id"]))
	}
	var reordered map[string]any
	if err := client.request("POST", fmt.Sprintf("/api/boards/%d/lanes/reorder", boardID), map[string]any{"laneIds": laneIDs}, &reordered); err != nil {
		return nil, err
	}
	idsByName := map[string]int{}
	for _, lane := range asSlice(reordered["lanes"]) {
		laneMap := asMap(lane)
		idsByName[firstString(laneMap["name"])] = intValue(laneMap["id"])
	}
	defaultID, doneID := 0, 0
	if len(laneIDs) > 0 {
		defaultID = laneIDs[0]
		doneID = laneIDs[len(laneIDs)-1]
	}
	return map[string]any{"project_id": boardID, "view_id": boardID, "bucket_names": []string(buckets), "bucket_ids_by_name": idsByName, "default_bucket_id": defaultID, "done_bucket_id": doneID}, nil
}

type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }
func (m *multiFlag) Set(value string) error {
	*m = append(*m, value)
	return nil
}

func runKanbanCLILabelList(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("label-list", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var pf projectFlagSet
	addProjectFlags(flags, &pf)
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	boardID, err := resolveBoardID(client, pf.projectID, pf.project)
	if err != nil {
		return nil, err
	}
	tags, err := boardTags(client, boardID)
	if err != nil {
		return nil, err
	}
	var result []map[string]any
	for _, tag := range tags {
		normalized := normalizeLabel(asMap(tag))
		if pf.search != "" && !strings.Contains(strings.ToLower(stringValue(normalized["title"])), strings.ToLower(pf.search)) {
			continue
		}
		result = append(result, normalized)
	}
	return result, nil
}

func runKanbanCLILabelEnsure(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("label-ensure", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var pf projectFlagSet
	addProjectFlags(flags, &pf)
	title := flags.String("title", "", "title")
	description := flags.String("description", "", "description")
	hexColor := flags.String("hex-color", "", "hex color")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	_ = description
	boardID, err := resolveBoardID(client, pf.projectID, pf.project)
	if err != nil {
		return nil, err
	}
	tags, err := boardTags(client, boardID)
	if err != nil {
		return nil, err
	}
	for _, tag := range tags {
		tagMap := asMap(tag)
		if firstString(tagMap["name"], tagMap["title"]) == *title {
			return normalizeLabel(tagMap), nil
		}
	}
	var created map[string]any
	color := *hexColor
	if color == "" {
		color = "#888888"
	}
	if err := client.request("POST", fmt.Sprintf("/api/boards/%d/tags", boardID), map[string]any{"name": *title, "color": color}, &created); err != nil {
		return nil, err
	}
	return normalizeLabel(created), nil
}

func runKanbanCLILabelDelete(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("label-delete", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var pf projectFlagSet
	addProjectFlags(flags, &pf)
	labelID := flags.Int("label-id", 0, "label ID")
	title := flags.String("title", "", "title")
	label := flags.String("label", "", "label")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	if *title == "" {
		*title = *label
	}
	boardID, err := resolveBoardID(client, pf.projectID, pf.project)
	if err != nil {
		return nil, err
	}
	tags, err := boardTags(client, boardID)
	if err != nil {
		return nil, err
	}
	var matched []map[string]any
	for _, raw := range tags {
		tag := asMap(raw)
		if *labelID > 0 && intValue(tag["id"]) == *labelID {
			matched = append(matched, tag)
		}
		if *labelID == 0 && *title != "" && firstString(tag["name"], tag["title"]) == *title {
			matched = append(matched, tag)
		}
	}
	if len(matched) > 1 {
		parts := make([]string, 0, len(matched))
		for _, tag := range matched {
			parts = append(parts, fmt.Sprintf("%d:%s", intValue(tag["id"]), firstString(tag["name"], tag["title"])))
		}
		return nil, errors.New("Tag title is ambiguous: " + strings.Join(parts, ", "))
	}
	if len(matched) == 1 {
		if err := client.request("DELETE", fmt.Sprintf("/api/tags/%d", intValue(matched[0]["id"])), nil, nil); err != nil {
			return nil, err
		}
	}
	remaining, err := boardTags(client, boardID)
	if err != nil {
		return nil, err
	}
	result := make([]map[string]any, 0, len(remaining))
	for _, tag := range remaining {
		result = append(result, normalizeLabel(asMap(tag)))
	}
	return result, nil
}

func listBoardTickets(client kanbaloneHTTPClient, boardID int, search string, includeClosed bool) (map[string]any, string, []map[string]any, error) {
	shell, err := boardShell(client, boardID)
	if err != nil {
		return nil, "", nil, err
	}
	title := firstString(asMap(shell["board"])["name"], boardID)
	var query []string
	if search != "" {
		query = append(query, "q="+url.QueryEscape(search))
	}
	if !includeClosed {
		query = append(query, "resolved=false")
	}
	path := fmt.Sprintf("/api/boards/%d/tickets", boardID)
	if len(query) > 0 {
		path += "?" + strings.Join(query, "&")
	}
	var response map[string]any
	if err := client.request("GET", path, nil, &response); err != nil {
		return nil, "", nil, err
	}
	rawTickets := asSlice(response["tickets"])
	if rawTickets == nil {
		return nil, "", nil, errors.New("Unexpected tasks response.")
	}
	tickets := make([]map[string]any, 0, len(rawTickets))
	for _, raw := range rawTickets {
		normalized := normalizeTicket(asMap(raw), title, shell)
		if !includeClosed && boolValue(normalized["is_archived"]) {
			continue
		}
		tickets = append(tickets, normalized)
	}
	sort.Slice(tickets, func(i, j int) bool {
		if intValue(tickets[i]["index"]) == intValue(tickets[j]["index"]) {
			return intValue(tickets[i]["id"]) < intValue(tickets[j]["id"])
		}
		return intValue(tickets[i]["index"]) < intValue(tickets[j]["index"])
	})
	return shell, title, tickets, nil
}

func runKanbanCLITaskList(client kanbaloneHTTPClient, command string, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	var pf projectFlagSet
	addProjectFlags(flags, &pf)
	status := flags.String("status", "", "status")
	limit := flags.Int("limit", 0, "limit")
	query := flags.String("query", "", "query")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	if command == "task-find" {
		pf.search = *query
	}
	boardID, err := resolveBoardID(client, pf.projectID, pf.project)
	if err != nil {
		return nil, err
	}
	_, title, tickets, err := listBoardTickets(client, boardID, pf.search, false)
	if err != nil {
		return nil, err
	}
	if *status != "" {
		filtered := tickets[:0]
		for _, ticket := range tickets {
			if strings.EqualFold(stringValue(ticket["status"]), *status) {
				filtered = append(filtered, ticket)
			}
		}
		tickets = filtered
	}
	if *limit > 0 && len(tickets) > *limit {
		tickets = tickets[:*limit]
	}
	result := make([]map[string]any, 0, len(tickets))
	for _, ticket := range tickets {
		result = append(result, normalizeTaskSummary(ticket, title))
	}
	return result, nil
}

func taskRelations(client kanbaloneHTTPClient, taskID int) (map[string]any, error) {
	var response map[string]any
	if err := client.request("GET", fmt.Sprintf("/api/tickets/%d/relations", taskID), nil, &response); err != nil {
		return nil, err
	}
	result := map[string]any{}
	if parent := asMap(response["parent"]); len(parent) > 0 {
		result["parenttask"] = []any{parent}
	}
	if children := asSlice(response["children"]); len(children) > 0 {
		result["subtask"] = children
	}
	if blockers := asSlice(response["blockers"]); len(blockers) > 0 {
		result["blocked"] = blockers
	}
	if blockedBy := asSlice(response["blockedBy"]); len(blockedBy) > 0 {
		result["blocking"] = blockedBy
	}
	if related := asSlice(response["related"]); len(related) > 0 {
		result["related"] = related
	}
	return result, nil
}

func taskLabelReasons(client kanbaloneHTTPClient, taskID int) ([]map[string]any, error) {
	var response map[string]any
	err := client.request("GET", fmt.Sprintf("/api/tickets/%d/tag-reasons", taskID), nil, &response)
	if err != nil {
		if !kanbaloneNotFound(err) {
			return nil, err
		}
		labels, labelErr := taskLabels(client, taskID)
		if labelErr != nil {
			return nil, err
		}
		result := make([]map[string]any, 0, len(labels))
		for _, label := range labels {
			item := normalizeLabel(label)
			item["reason"] = nil
			item["details"] = nil
			item["reason_comment_id"] = nil
			item["attached_at"] = nil
			result = append(result, item)
		}
		return result, nil
	}
	tags := asSlice(response["tags"])
	if tags == nil {
		return nil, errors.New("Unexpected task tag reasons response.")
	}
	result := make([]map[string]any, 0, len(tags))
	for _, raw := range tags {
		item := asMap(raw)
		tag := asMap(item["tag"])
		if len(tag) == 0 {
			tag = item
		}
		normalized := normalizeLabel(tag)
		normalized["reason"] = item["reason"]
		normalized["details"] = item["details"]
		normalized["reason_comment_id"] = item["reasonCommentId"]
		normalized["attached_at"] = item["attachedAt"]
		result = append(result, normalized)
	}
	return result, nil
}

func taskLabels(client kanbaloneHTTPClient, taskID int) ([]map[string]any, error) {
	var ticket map[string]any
	if err := client.request("GET", fmt.Sprintf("/api/tickets/%d", taskID), nil, &ticket); err != nil {
		return nil, err
	}
	tags := asSlice(ticket["tags"])
	if tags == nil {
		return nil, errors.New("Unexpected task tags response.")
	}
	result := make([]map[string]any, 0, len(tags))
	for _, tag := range tags {
		result = append(result, normalizeLabel(asMap(tag)))
	}
	return result, nil
}

func normalizeSnapshot(client kanbaloneHTTPClient, ticket map[string]any, boardTitle string) (map[string]any, error) {
	taskID := intValue(ticket["id"])
	detail, _, _, err := taskByID(client, taskID)
	if err != nil {
		return nil, err
	}
	labels, err := taskLabels(client, taskID)
	if err != nil {
		return nil, err
	}
	labelTitles := make([]string, 0, len(labels))
	for _, label := range labels {
		labelTitles = append(labelTitles, stringValue(label["title"]))
	}
	sort.Strings(labelTitles)
	reasons, err := taskLabelReasons(client, taskID)
	if err != nil {
		return nil, err
	}
	relations, err := taskRelations(client, taskID)
	if err != nil {
		return nil, err
	}
	parentRefs := refsFromRelations(relations["parenttask"])
	blockingRefs := refsFromRelations(relations["blocked"])
	description := firstString(detail["description"], detail["bodyMarkdown"], ticket["description"])
	snapshot := normalizeTaskSummary(ticket, boardTitle)
	snapshot["description"] = description
	snapshot["description_summary"] = summarizeText(description, 160)
	if description != "" {
		snapshot["description_source"] = "detail"
	} else {
		snapshot["description_source"] = "empty"
	}
	snapshot["labels"] = labelTitles
	snapshot["label_reasons"] = reasons
	snapshot["blocking_task_refs"] = uniqueSorted(blockingRefs)
	snapshot["parent_refs"] = parentRefs
	if len(parentRefs) > 0 {
		snapshot["parent_ref"] = parentRefs[0]
	} else {
		snapshot["parent_ref"] = nil
	}
	return snapshot, nil
}

func refsFromRelations(raw any) []string {
	var refs []string
	for _, item := range asSlice(raw) {
		itemMap := asMap(item)
		ref := firstString(itemMap["ref"], itemMap["reference"])
		if ref != "" {
			refs = append(refs, ref)
		}
	}
	return refs
}

func uniqueSorted(values []string) []string {
	seen := map[string]bool{}
	var result []string
	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}

func summarizeText(value string, limit int) string {
	parts := strings.Fields(value)
	single := strings.Join(parts, " ")
	if len(single) <= limit {
		return single
	}
	return strings.TrimSpace(single[:limit-3]) + "..."
}

func runKanbanCLITaskSnapshotList(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-snapshot-list", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var pf projectFlagSet
	addProjectFlags(flags, &pf)
	status := flags.String("status", "", "status")
	limit := flags.Int("limit", 0, "limit")
	includeClosed := flags.Bool("include-closed", false, "include closed")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	boardID, err := resolveBoardID(client, pf.projectID, pf.project)
	if err != nil {
		return nil, err
	}
	_, title, tickets, err := listBoardTickets(client, boardID, pf.search, *includeClosed)
	if err != nil {
		return nil, err
	}
	var result []map[string]any
	for _, ticket := range tickets {
		if *status != "" && !strings.EqualFold(stringValue(ticket["status"]), *status) {
			continue
		}
		snapshot, err := normalizeSnapshot(client, ticket, title)
		if err != nil {
			return nil, err
		}
		result = append(result, snapshot)
		if *limit > 0 && len(result) >= *limit {
			break
		}
	}
	return result, nil
}

func runKanbanCLITaskWatchSummaryList(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-watch-summary-list", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var pf projectFlagSet
	addProjectFlags(flags, &pf)
	var taskIDs multiFlag
	var tasks multiFlag
	flags.Var(&taskIDs, "task-id", "task ID")
	flags.Var(&tasks, "task", "task ref")
	ignoreMissing := flags.Bool("ignore-missing", false, "ignore missing")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	var ids []int
	for _, raw := range taskIDs {
		id, err := strconv.Atoi(raw)
		if err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	seen := map[int]bool{}
	var result []map[string]any
	resolve := func(id int) error {
		if seen[id] {
			return nil
		}
		seen[id] = true
		task, _, title, err := taskByID(client, id)
		if err != nil {
			if *ignoreMissing {
				return nil
			}
			return err
		}
		if boolValue(task["done"]) || boolValue(task["is_archived"]) {
			return nil
		}
		relations, err := taskRelations(client, id)
		if err != nil {
			return err
		}
		parentRefs := refsFromRelations(relations["parenttask"])
		reasons, err := taskLabelReasons(client, id)
		if err != nil {
			return err
		}
		item := map[string]any{
			"id":            id,
			"ref":           canonicalTaskRef(title, task),
			"title":         firstString(task["title"]),
			"status":        task["status"],
			"done":          boolValue(task["done"]),
			"is_archived":   boolValue(task["is_archived"]),
			"parent_ref":    nil,
			"label_reasons": reasons,
		}
		if len(parentRefs) > 0 {
			item["parent_ref"] = parentRefs[0]
		}
		result = append(result, item)
		return nil
	}
	for _, id := range ids {
		if err := resolve(id); err != nil {
			return nil, err
		}
	}
	for _, taskRef := range tasks {
		id, ok := parseTaskID(taskRef)
		if !ok {
			if *ignoreMissing {
				continue
			}
			return nil, fmt.Errorf("Task not found: %s", taskRef)
		}
		if err := resolve(id); err != nil {
			return nil, err
		}
	}
	sort.Slice(result, func(i, j int) bool { return stringValue(result[i]["ref"]) < stringValue(result[j]["ref"]) })
	return result, nil
}

func runKanbanBootstrapCLI(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o kanban bootstrap", flag.ContinueOnError)
	flags.SetOutput(stderr)
	baseURL := flags.String("base-url", "", "Kanbalone base URL")
	token := flags.String("token", "", "Kanbalone API token")
	board := flags.String("board", "", "board name")
	configJSON := flags.String("config-json", "", "bootstrap config JSON")
	configFile := flags.String("config-file", "", "bootstrap config file")
	if err := flags.Parse(args); err != nil {
		return err
	}
	resolvedBaseURL, err := resolveKanbanBaseURL(*baseURL, "kanbalone")
	if err != nil {
		return err
	}
	resolvedToken, err := resolveKanbanToken(*token, "kanbalone")
	if err != nil {
		return err
	}
	rawConfig, ok, err := readTextArg(*configJSON, *configFile)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("--config-json or --config-file is required")
	}
	var config map[string]any
	if err := json.Unmarshal([]byte(rawConfig), &config); err != nil {
		return errors.New("JSON argument is invalid.")
	}
	client := kanbaloneHTTPClient{
		baseURL: strings.TrimRight(resolvedBaseURL, "/"),
		token:   resolvedToken,
		client:  &http.Client{Timeout: 30 * time.Second},
	}
	result, err := ensureKanbaloneBootstrap(client, config, *board)
	if err != nil {
		return err
	}
	return writePrettyJSON(stdout, result)
}

func ensureKanbaloneBootstrap(client kanbaloneHTTPClient, config map[string]any, selectedBoard string) (any, error) {
	var ensuredBoards []map[string]any
	for _, rawBoard := range asSlice(config["boards"]) {
		boardSpec := asMap(rawBoard)
		name := firstString(boardSpec["name"], boardSpec["title"])
		if selectedBoard != "" && name != selectedBoard {
			continue
		}
		board, err := ensureKanbaloneBoard(client, name)
		if err != nil {
			return nil, err
		}
		boardID := intValue(board["id"])
		if err := ensureKanbaloneDefaultLanes(client, boardID); err != nil {
			return nil, err
		}
		var ensuredTags []map[string]any
		for _, rawTag := range asSlice(boardSpec["tags"]) {
			tagSpec := asMap(rawTag)
			tagName := firstString(tagSpec["name"], tagSpec["title"])
			if tagName == "" {
				continue
			}
			tag, err := ensureKanbaloneTag(client, boardID, tagName, firstString(tagSpec["color"], tagSpec["hex_color"]))
			if err != nil {
				return nil, err
			}
			ensuredTags = append(ensuredTags, normalizeLabel(tag))
		}
		ensuredBoards = append(ensuredBoards, map[string]any{
			"id":    boardID,
			"name":  firstString(board["name"], board["title"]),
			"tags":  ensuredTags,
			"lanes": []string{"Backlog", "To do", "In progress", "In review", "Inspection", "Merging", "Done"},
		})
	}
	if selectedBoard != "" && len(ensuredBoards) == 0 {
		return nil, fmt.Errorf("Board not found in bootstrap config: %s", selectedBoard)
	}
	return map[string]any{"boards": ensuredBoards}, nil
}

func ensureKanbaloneBoard(client kanbaloneHTTPClient, name string) (map[string]any, error) {
	boards, err := getBoards(client)
	if err != nil {
		return nil, err
	}
	for _, raw := range boards {
		board := asMap(raw)
		if firstString(board["name"], board["title"]) == name {
			return board, nil
		}
	}
	var created map[string]any
	if err := client.request("POST", "/api/boards", map[string]any{"name": name}, &created); err != nil {
		return nil, err
	}
	return asMap(created["board"]), nil
}

func ensureKanbaloneDefaultLanes(client kanbaloneHTTPClient, boardID int) error {
	shell, err := boardShell(client, boardID)
	if err != nil {
		return err
	}
	existing := map[string]map[string]any{}
	for _, raw := range asSlice(shell["lanes"]) {
		lane := asMap(raw)
		existing[strings.ToLower(firstString(lane["name"]))] = lane
	}
	var laneIDs []int
	for _, name := range []string{"Backlog", "To do", "In progress", "In review", "Inspection", "Merging", "Done"} {
		lane := existing[strings.ToLower(name)]
		if lane == nil {
			var created map[string]any
			if err := client.request("POST", fmt.Sprintf("/api/boards/%d/lanes", boardID), map[string]any{"name": name}, &created); err != nil {
				return err
			}
			lane = created
		}
		laneIDs = append(laneIDs, intValue(lane["id"]))
	}
	var ignored map[string]any
	return client.request("POST", fmt.Sprintf("/api/boards/%d/lanes/reorder", boardID), map[string]any{"laneIds": laneIDs}, &ignored)
}

func ensureKanbaloneTag(client kanbaloneHTTPClient, boardID int, name string, color string) (map[string]any, error) {
	tags, err := boardTags(client, boardID)
	if err != nil {
		return nil, err
	}
	for _, raw := range tags {
		tag := asMap(raw)
		if firstString(tag["name"], tag["title"]) == name {
			return tag, nil
		}
	}
	if color == "" {
		color = "#888888"
	}
	var created map[string]any
	if err := client.request("POST", fmt.Sprintf("/api/boards/%d/tags", boardID), map[string]any{"name": name, "color": color}, &created); err != nil {
		return nil, err
	}
	return created, nil
}

func runKanbanCLITaskGet(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-get", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	task, _, title, err := taskByID(client, id)
	if err != nil {
		return nil, err
	}
	relations, err := taskRelations(client, id)
	if err != nil {
		return nil, err
	}
	reasons, err := taskLabelReasons(client, id)
	if err != nil {
		return nil, err
	}
	task["related_tasks"] = relations
	task["label_reasons"] = reasons
	return normalizeTaskDetail(task, title), nil
}

func runKanbanCLITaskRelationList(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-relation-list", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	return taskRelations(client, id)
}

func runKanbanCLITaskCommentList(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-comment-list", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	var response map[string]any
	if err := client.request("GET", fmt.Sprintf("/api/tickets/%d/comments", id), nil, &response); err != nil {
		return nil, err
	}
	comments := asSlice(response["comments"])
	if comments == nil {
		return nil, errors.New("Unexpected task comments response.")
	}
	result := make([]map[string]any, 0, len(comments))
	for _, comment := range comments {
		result = append(result, normalizeComment(id, asMap(comment)))
	}
	return result, nil
}

func normalizeComment(taskID int, comment map[string]any) map[string]any {
	return map[string]any{
		"id":      intValue(comment["id"]),
		"task_id": taskID,
		"comment": firstString(comment["comment"], comment["bodyMarkdown"]),
		"created": firstString(comment["created"], comment["date_creation"]),
		"updated": firstString(comment["updated"], comment["date_modification"], comment["date_creation"], comment["createdAt"]),
		"author": map[string]any{
			"id":       intValue(comment["user_id"]),
			"username": comment["username"],
			"name":     comment["name"],
		},
	}
}

func runKanbanCLITaskCommentCreate(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-comment-create", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	comment := flags.String("comment", "", "comment")
	commentFile := flags.String("comment-file", "", "comment file")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	body, ok, err := readTextArg(*comment, *commentFile)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errors.New("--comment or --comment-file is required.")
	}
	var created map[string]any
	if err := client.request("POST", fmt.Sprintf("/api/tickets/%d/comments", id), map[string]any{"bodyMarkdown": body}, &created); err != nil {
		return nil, err
	}
	return normalizeComment(id, created), nil
}

func runKanbanCLITaskEventList(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-event-list", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	var response map[string]any
	if err := client.request("GET", fmt.Sprintf("/api/tickets/%d/events", id), nil, &response); err != nil {
		if !kanbaloneNotFound(err) {
			return nil, err
		}
		return []map[string]any{}, nil
	}
	events := asSlice(response["events"])
	result := make([]map[string]any, 0, len(events))
	for _, raw := range events {
		event := asMap(raw)
		result = append(result, map[string]any{
			"id":       intValue(event["id"]),
			"task_id":  intValue(mapFirstPresent(event, "ticketId", "task_id")),
			"source":   event["source"],
			"kind":     event["kind"],
			"title":    event["title"],
			"summary":  event["summary"],
			"severity": event["severity"],
			"icon":     event["icon"],
			"data":     mapFirstPresent(event, "data"),
			"created":  firstString(event["createdAt"], event["created"]),
		})
	}
	return result, nil
}

func runKanbanCLITaskEventCreate(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-event-create", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	source := flags.String("source", "", "source")
	kind := flags.String("kind", "", "kind")
	title := flags.String("title", "", "title")
	summary := flags.String("summary", "", "summary")
	severity := flags.String("severity", "info", "severity")
	icon := flags.String("icon", "", "icon")
	dataJSON := flags.String("data-json", "", "data json")
	dataFile := flags.String("data-file", "", "data file")
	fallbackComment := flags.String("fallback-comment", "", "fallback comment")
	fallbackCommentFile := flags.String("fallback-comment-file", "", "fallback comment file")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	data, _, err := readJSONArg(*dataJSON, *dataFile)
	if err != nil {
		return nil, err
	}
	payload := map[string]any{"source": *source, "kind": *kind, "title": *title, "summary": *summary, "severity": *severity, "data": map[string]any{}}
	if dataMap, ok := data.(map[string]any); ok {
		payload["data"] = dataMap
	}
	if *icon != "" {
		payload["icon"] = *icon
	}
	var created map[string]any
	if err := client.request("POST", fmt.Sprintf("/api/tickets/%d/events", id), payload, &created); err != nil {
		if !kanbaloneNotFound(err) {
			return nil, err
		}
		comment, ok, readErr := readTextArg(*fallbackComment, *fallbackCommentFile)
		if readErr != nil {
			return nil, readErr
		}
		if !ok {
			return nil, errors.New("Kanbalone structured events are unavailable and no fallback comment was provided.")
		}
		var createdComment map[string]any
		if commentErr := client.request("POST", fmt.Sprintf("/api/tickets/%d/comments", id), map[string]any{"bodyMarkdown": comment}, &createdComment); commentErr != nil {
			return nil, err
		}
		return map[string]any{"fallback": "comment", "comment": normalizeComment(id, createdComment), "event": payload}, nil
	}
	created["task_id"] = id
	return created, nil
}

func runKanbanCLITaskLabelList(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-label-list", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	return taskLabels(client, id)
}

func runKanbanCLITaskLabelReasonList(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-label-reason-list", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	return taskLabelReasons(client, id)
}

func resolveTag(client kanbaloneHTTPClient, taskID int, labelID int, title string) (map[string]any, error) {
	task, _, _, err := taskByID(client, taskID)
	if err != nil {
		return nil, err
	}
	tags, err := boardTags(client, intValue(task["project_id"]))
	if err != nil {
		return nil, err
	}
	for _, raw := range tags {
		tag := asMap(raw)
		if labelID > 0 && intValue(tag["id"]) == labelID {
			return tag, nil
		}
		if title != "" && firstString(tag["name"], tag["title"]) == title {
			return tag, nil
		}
	}
	if labelID > 0 {
		return nil, fmt.Errorf("Tag not found: %d", labelID)
	}
	return nil, fmt.Errorf("Tag not found: %s", title)
}

func setTaskTags(client kanbaloneHTTPClient, taskID int, names []string) error {
	task, _, _, err := taskByID(client, taskID)
	if err != nil {
		return err
	}
	available, err := boardTags(client, intValue(task["project_id"]))
	if err != nil {
		return err
	}
	var tagIDs []int
	for _, name := range names {
		found := false
		for _, raw := range available {
			tag := asMap(raw)
			if firstString(tag["name"], tag["title"]) == name {
				tagIDs = append(tagIDs, intValue(tag["id"]))
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("Tag not found for task assignment: %s", name)
		}
	}
	var updated map[string]any
	return client.request("PATCH", fmt.Sprintf("/api/tickets/%d", taskID), map[string]any{"tagIds": tagIDs}, &updated)
}

func currentTaskLabelTitles(client kanbaloneHTTPClient, taskID int) (map[string]bool, error) {
	labels, err := taskLabels(client, taskID)
	if err != nil {
		return nil, err
	}
	result := map[string]bool{}
	for _, label := range labels {
		title := stringValue(label["title"])
		if title != "" {
			result[title] = true
		}
	}
	return result, nil
}

func runKanbanCLITaskLabelAdd(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-label-add", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	labelID := flags.Int("label-id", 0, "label ID")
	title := flags.String("title", "", "title")
	label := flags.String("label", "", "label")
	reason := flags.String("reason", "", "reason")
	detailsJSON := flags.String("details-json", "", "details json")
	detailsFile := flags.String("details-file", "", "details file")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	if *title == "" {
		*title = *label
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	details, hasDetails, err := readJSONArg(*detailsJSON, *detailsFile)
	if err != nil {
		return nil, err
	}
	tag, err := resolveTag(client, id, *labelID, *title)
	if err != nil {
		return nil, err
	}
	if *reason != "" || hasDetails {
		payload := map[string]any{}
		if *reason != "" {
			payload["reason"] = *reason
		}
		if hasDetails {
			payload["details"] = details
		}
		var ignored map[string]any
		if err := client.request("POST", fmt.Sprintf("/api/tickets/%d/tags/%d", id, intValue(tag["id"])), payload, &ignored); err == nil {
			return taskLabels(client, id)
		} else if !kanbaloneNotFound(err) {
			return nil, err
		}
	}
	current, err := currentTaskLabelTitles(client, id)
	if err != nil {
		return nil, err
	}
	current[firstString(tag["name"], tag["title"])] = true
	names := make([]string, 0, len(current))
	for name := range current {
		names = append(names, name)
	}
	sort.Strings(names)
	if err := setTaskTags(client, id, names); err != nil {
		return nil, err
	}
	return taskLabels(client, id)
}

func runKanbanCLITaskLabelRemove(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-label-remove", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	labelID := flags.Int("label-id", 0, "label ID")
	title := flags.String("title", "", "title")
	label := flags.String("label", "", "label")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	if *title == "" {
		*title = *label
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	tag, err := resolveTag(client, id, *labelID, *title)
	if err != nil {
		return nil, err
	}
	current, err := currentTaskLabelTitles(client, id)
	if err != nil {
		return nil, err
	}
	delete(current, firstString(tag["name"], tag["title"]))
	names := make([]string, 0, len(current))
	for name := range current {
		names = append(names, name)
	}
	sort.Strings(names)
	if err := setTaskTags(client, id, names); err != nil {
		return nil, err
	}
	return taskLabels(client, id)
}

func runKanbanCLITaskCreate(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-create", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var pf projectFlagSet
	addProjectFlags(flags, &pf)
	title := flags.String("title", "", "title")
	description := flags.String("description", "", "description")
	descriptionFile := flags.String("description-file", "", "description file")
	reference := flags.String("reference", "", "reference")
	status := flags.String("status", "To do", "status")
	priority := flags.Int("priority", 2, "priority")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	_ = reference
	boardID, err := resolveBoardID(client, pf.projectID, pf.project)
	if err != nil {
		return nil, err
	}
	body, _, err := readTextArg(*description, *descriptionFile)
	if err != nil {
		return nil, err
	}
	shell, err := boardShell(client, boardID)
	if err != nil {
		return nil, err
	}
	laneID, err := laneIDByName(shell, *status)
	if err != nil {
		if lanes := asSlice(shell["lanes"]); len(lanes) > 0 {
			laneID = intValue(asMap(lanes[0])["id"])
		} else {
			return nil, errors.New("Kanbalone board must have at least one lane.")
		}
	}
	var created map[string]any
	if err := client.request("POST", fmt.Sprintf("/api/boards/%d/tickets", boardID), map[string]any{"laneId": laneID, "title": *title, "bodyMarkdown": body, "priority": *priority}, &created); err != nil {
		return nil, err
	}
	boardTitle := firstString(asMap(shell["board"])["name"], boardID)
	return normalizeTaskDetail(normalizeTicket(created, boardTitle, shell), boardTitle), nil
}

func runKanbanCLITaskUpdate(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-update", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	title := flags.String("title", "", "title")
	description := flags.String("description", "", "description")
	descriptionFile := flags.String("description-file", "", "description file")
	appendDescription := flags.String("append-description", "", "append description")
	appendDescriptionFile := flags.String("append-description-file", "", "append description file")
	reference := flags.String("reference", "", "reference")
	priority := flags.Int("priority", 0, "priority")
	done := flags.String("done", "", "done")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	_ = reference
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	task, _, _, err := taskByID(client, id)
	if err != nil {
		return nil, err
	}
	payload := map[string]any{}
	if *title != "" {
		payload["title"] = *title
	}
	if body, ok, err := readTextArg(*description, *descriptionFile); err != nil {
		return nil, err
	} else if ok {
		payload["bodyMarkdown"] = body
	} else if appendBody, ok, err := readTextArg(*appendDescription, *appendDescriptionFile); err != nil {
		return nil, err
	} else if ok {
		existing := firstString(task["description"], task["bodyMarkdown"])
		separator := ""
		if existing != "" && !strings.HasSuffix(existing, "\n") {
			separator = "\n"
		}
		payload["bodyMarkdown"] = existing + separator + appendBody
	}
	if *priority > 0 {
		payload["priority"] = *priority
	}
	if strings.TrimSpace(*done) != "" {
		payload["isResolved"] = strings.EqualFold(strings.TrimSpace(*done), "true")
	}
	var updated map[string]any
	if err := client.request("PATCH", fmt.Sprintf("/api/tickets/%d", id), payload, &updated); err != nil {
		return nil, err
	}
	if strings.TrimSpace(*done) != "" {
		refreshed, _, _, err := taskByID(client, id)
		if err != nil {
			return nil, err
		}
		if _, changedDescription := payload["bodyMarkdown"]; changedDescription && firstString(refreshed["description"], refreshed["bodyMarkdown"]) == "" {
			refreshed["description"] = payload["bodyMarkdown"]
			refreshed["bodyMarkdown"] = payload["bodyMarkdown"]
		}
		return normalizeTaskDetail(refreshed, firstString(refreshed["project"], intValue(refreshed["project_id"]))), nil
	}
	shell, err := boardShell(client, intValue(updated["boardId"]))
	if err != nil {
		return nil, err
	}
	boardTitle := firstString(asMap(shell["board"])["name"], intValue(updated["boardId"]))
	return normalizeTaskDetail(normalizeTicket(updated, boardTitle, shell), boardTitle), nil
}

func runKanbanCLITaskTransition(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-transition", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	status := flags.String("status", "", "status")
	syncDone := flags.Bool("sync-done-state", false, "sync done")
	flags.BoolVar(syncDone, "sync-completion-state", false, "sync done")
	flags.BoolVar(syncDone, "complete", false, "sync done")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	payload := map[string]any{"laneName": *status}
	current, _, _, err := taskByID(client, id)
	if err != nil {
		return nil, err
	}
	targetIsDone := strings.EqualFold(strings.TrimSpace(*status), "Done")
	if *syncDone && targetIsDone {
		payload["isResolved"] = true
	} else if !targetIsDone && (*syncDone || boolValue(current["done"])) {
		payload["isResolved"] = false
	}
	var transitioned map[string]any
	if err := client.request("PATCH", fmt.Sprintf("/api/tickets/%d/transition", id), payload, &transitioned); err != nil {
		return nil, err
	}
	shell, err := boardShell(client, intValue(transitioned["boardId"]))
	if err != nil {
		return nil, err
	}
	boardTitle := firstString(asMap(shell["board"])["name"], intValue(transitioned["boardId"]))
	normalized := normalizeTicket(transitioned, boardTitle, shell)
	relations, err := taskRelations(client, id)
	if err != nil {
		return nil, err
	}
	normalized["related_tasks"] = relations
	return normalizeTaskDetail(normalized, boardTitle), nil
}

func runKanbanCLITaskReorder(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-reorder", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	status := flags.String("status", "", "status")
	laneID := flags.Int("lane-id", 0, "lane ID")
	flags.IntVar(laneID, "bucket-id", 0, "lane ID")
	flags.IntVar(laneID, "column-id", 0, "lane ID")
	position := flags.Int("position", -1, "position")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	if *position < 0 {
		return nil, errors.New("--position must be zero or greater.")
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	task, shell, boardTitle, err := taskByID(client, id)
	if err != nil {
		return nil, err
	}
	targetLaneID := *laneID
	if targetLaneID == 0 {
		targetLaneID = intValue(task["column_id"])
	}
	if *status != "" {
		targetLaneID, err = laneIDByName(shell, *status)
		if err != nil {
			return nil, err
		}
	}
	var response map[string]any
	if err := client.request("GET", fmt.Sprintf("/api/boards/%d/tickets", intValue(task["project_id"])), nil, &response); err != nil {
		return nil, err
	}
	tickets := asSlice(response["tickets"])
	if tickets == nil {
		return nil, errors.New("Unexpected tasks response.")
	}
	items, err := buildReorderedTicketItems(tickets, id, targetLaneID, *position, shell)
	if err != nil {
		return nil, err
	}
	var reordered map[string]any
	if err := client.request("POST", fmt.Sprintf("/api/boards/%d/tickets/reorder", intValue(task["project_id"])), map[string]any{"items": items}, &reordered); err != nil {
		return nil, err
	}
	updatedTickets := asSlice(reordered["tickets"])
	for _, raw := range updatedTickets {
		ticket := asMap(raw)
		if intValue(ticket["id"]) == id {
			return normalizeTaskDetail(normalizeTicket(ticket, boardTitle, shell), boardTitle), nil
		}
	}
	return nil, fmt.Errorf("Reordered task was not returned: %d", id)
}

func buildReorderedTicketItems(tickets []any, taskID int, targetLaneID int, targetPosition int, shell map[string]any) ([]map[string]int, error) {
	var laneOrder []int
	for _, rawLane := range asSlice(shell["lanes"]) {
		laneID := intValue(asMap(rawLane)["id"])
		if laneID > 0 {
			laneOrder = append(laneOrder, laneID)
		}
	}
	laneSeen := map[int]bool{}
	for _, laneID := range laneOrder {
		laneSeen[laneID] = true
	}
	if !laneSeen[targetLaneID] {
		return nil, fmt.Errorf("Lane does not belong to board: %d", targetLaneID)
	}
	grouped := map[int][]map[string]any{}
	var target map[string]any
	for _, raw := range tickets {
		ticket := asMap(raw)
		id := intValue(ticket["id"])
		laneID := intValue(ticket["laneId"])
		if !laneSeen[laneID] && laneID > 0 {
			laneOrder = append(laneOrder, laneID)
			laneSeen[laneID] = true
		}
		if id == taskID {
			target = ticket
			continue
		}
		grouped[laneID] = append(grouped[laneID], ticket)
	}
	if target == nil {
		return nil, fmt.Errorf("Task is not reorderable in the active board ticket list: %d", taskID)
	}
	for laneID := range grouped {
		sort.Slice(grouped[laneID], func(i, j int) bool {
			left := grouped[laneID][i]
			right := grouped[laneID][j]
			if intValue(left["position"]) == intValue(right["position"]) {
				return intValue(left["id"]) < intValue(right["id"])
			}
			return intValue(left["position"]) < intValue(right["position"])
		})
	}
	targetGroup := grouped[targetLaneID]
	boundedPosition := targetPosition
	if boundedPosition > len(targetGroup) {
		boundedPosition = len(targetGroup)
	}
	target = copyMap(target)
	target["laneId"] = targetLaneID
	targetGroup = append(targetGroup, nil)
	copy(targetGroup[boundedPosition+1:], targetGroup[boundedPosition:])
	targetGroup[boundedPosition] = target
	grouped[targetLaneID] = targetGroup

	var items []map[string]int
	for _, laneID := range laneOrder {
		for position, ticket := range grouped[laneID] {
			items = append(items, map[string]int{
				"ticketId": intValue(ticket["id"]),
				"laneId":   laneID,
				"position": position,
			})
		}
	}
	return items, nil
}

func copyMap(input map[string]any) map[string]any {
	output := make(map[string]any, len(input))
	for key, value := range input {
		output[key] = value
	}
	return output
}

func runKanbanCLITaskRelationCreate(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	return runKanbanCLITaskRelationMutate(client, args, stderr, true)
}

func runKanbanCLITaskRelationDelete(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	return runKanbanCLITaskRelationMutate(client, args, stderr, false)
}

func runKanbanCLITaskRelationMutate(client kanbaloneHTTPClient, args []string, stderr io.Writer, create bool) (any, error) {
	name := "task-relation-delete"
	if create {
		name = "task-relation-create"
	}
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	otherTask := flags.String("other-task", "", "other task")
	otherTaskID := flags.Int("other-task-id", 0, "other task ID")
	relationKind := flags.String("relation-kind", "related", "relation kind")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	otherID, err := resolveTaskID(client, *otherTaskID, *otherTask)
	if err != nil {
		return nil, err
	}
	if err := mutateRelation(client, id, otherID, *relationKind, create); err != nil {
		return nil, err
	}
	task, _, _, err := taskByID(client, id)
	if err != nil {
		return nil, err
	}
	relations, err := taskRelations(client, id)
	if err != nil {
		return nil, err
	}
	task["related_tasks"] = relations
	return task, nil
}

func mutateRelation(client kanbaloneHTTPClient, taskID, otherTaskID int, kind string, create bool) error {
	switch kind {
	case "subtask":
		parentID, childID := taskID, otherTaskID
		if !create {
			parentID = 0
		}
		var updated map[string]any
		_ = parentID
		payload := map[string]any{"parentTicketId": nil}
		if create {
			payload["parentTicketId"] = taskID
		}
		return client.request("PATCH", fmt.Sprintf("/api/tickets/%d", childID), payload, &updated)
	case "parenttask":
		payload := map[string]any{"parentTicketId": nil}
		if create {
			payload["parentTicketId"] = otherTaskID
		}
		var updated map[string]any
		return client.request("PATCH", fmt.Sprintf("/api/tickets/%d", taskID), payload, &updated)
	case "blocked":
		return mutateIDList(client, taskID, "blockerIds", otherTaskID, create)
	case "related":
		return mutateIDList(client, taskID, "relatedIds", otherTaskID, create)
	default:
		return fmt.Errorf("Unsupported relation kind for Kanbalone: %s", kind)
	}
}

func mutateIDList(client kanbaloneHTTPClient, taskID int, field string, otherTaskID int, add bool) error {
	var task map[string]any
	if err := client.request("GET", fmt.Sprintf("/api/tickets/%d", taskID), nil, &task); err != nil {
		return err
	}
	seen := map[int]bool{}
	for _, raw := range asSlice(task[field]) {
		id := intValue(raw)
		if id != otherTaskID {
			seen[id] = true
		}
	}
	if add {
		seen[otherTaskID] = true
	}
	var ids []int
	for id := range seen {
		ids = append(ids, id)
	}
	sort.Ints(ids)
	var updated map[string]any
	return client.request("PATCH", fmt.Sprintf("/api/tickets/%d", taskID), map[string]any{field: ids}, &updated)
}

func runKanbanCLITaskExternalReferenceSet(client kanbaloneHTTPClient, args []string, stderr io.Writer) (any, error) {
	flags := flag.NewFlagSet("task-external-reference-set", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var tf taskFlagSet
	addTaskFlags(flags, &tf)
	kind := flags.String("kind", "", "kind")
	dataJSON := flags.String("data-json", "", "data json")
	dataFile := flags.String("data-file", "", "data file")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	id, err := resolveTaskID(client, tf.taskID, tf.task)
	if err != nil {
		return nil, err
	}
	payload, ok, err := readJSONArg(*dataJSON, *dataFile)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errors.New("--data-json or --data-file must contain a JSON object.")
	}
	var updated map[string]any
	if err := client.request("PUT", fmt.Sprintf("/api/tickets/%d/external-references/%s", id, url.PathEscape(*kind)), payload, &updated); err != nil {
		return nil, err
	}
	shell, err := boardShell(client, intValue(updated["boardId"]))
	if err != nil {
		return nil, err
	}
	boardTitle := firstString(asMap(shell["board"])["name"], intValue(updated["boardId"]))
	return normalizeTaskDetail(normalizeTicket(updated, boardTitle, shell), boardTitle), nil
}
