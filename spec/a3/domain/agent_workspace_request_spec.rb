# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Domain::AgentWorkspaceRequest do
  it "round-trips an agent materialized worktree request" do
    request = described_class.new(
      mode: :agent_materialized,
      workspace_kind: :ticket_workspace,
      workspace_id: "Portal-42-ticket",
      freshness_policy: :reuse_if_clean_and_ref_matches,
      cleanup_policy: :retain_until_a3_cleanup,
      publish_policy: {
        mode: "commit_declared_changes_on_success",
        commit_message: "A3 implementation update for Portal#42"
      },
      slots: {
        repo_alpha: {
          source: {
            kind: "local_git",
            alias: "member-portal-starters"
          },
          ref: "refs/heads/a3/work/Portal-42",
          checkout: "worktree_branch",
          access: "read_write",
          sync_class: "eager",
          ownership: "edit_target",
          required: true
        }
      }
    )

    expect(request.request_form).to eq(
      "mode" => "agent_materialized",
      "workspace_kind" => "ticket_workspace",
      "workspace_id" => "Portal-42-ticket",
      "freshness_policy" => "reuse_if_clean_and_ref_matches",
      "cleanup_policy" => "retain_until_a3_cleanup",
      "publish_policy" => {
        "mode" => "commit_declared_changes_on_success",
        "commit_message" => "A3 implementation update for Portal#42"
      },
      "slots" => {
        "repo_alpha" => {
          "source" => {
            "kind" => "local_git",
            "alias" => "member-portal-starters"
          },
          "ref" => "refs/heads/a3/work/Portal-42",
          "checkout" => "worktree_branch",
          "access" => "read_write",
          "sync_class" => "eager",
          "ownership" => "edit_target",
          "required" => true
        }
      }
    )
    expect(described_class.from_request_form(request.request_form)).to eq(request)
  end

  it "round-trips parent-child workspace topology" do
    request = described_class.new(
      mode: :agent_materialized,
      workspace_kind: :ticket_workspace,
      workspace_id: "Portal-134-children-Portal-135-implementation-run-implementation",
      freshness_policy: :reuse_if_clean_and_ref_matches,
      cleanup_policy: :retain_until_a3_cleanup,
      topology: {
        kind: "parent_child",
        parent_ref: "Portal#134",
        child_ref: "Portal#135",
        parent_workspace_id: "Portal-134-parent",
        relative_path: "children/Portal-135/ticket_workspace"
      },
      slots: {
        repo_alpha: {
          source: { kind: "local_git", alias: "member-portal-starters" },
          ref: "refs/heads/a3/work/Portal-135",
          checkout: "worktree_branch",
          access: "read_write",
          sync_class: "eager",
          ownership: "edit_target",
          required: true
        }
      }
    )

    expect(request.request_form.fetch("topology")).to eq(
      "kind" => "parent_child",
      "parent_ref" => "Portal#134",
      "child_ref" => "Portal#135",
      "parent_workspace_id" => "Portal-134-parent",
      "relative_path" => "children/Portal-135/ticket_workspace"
    )
    expect(described_class.from_request_form(request.request_form)).to eq(request)
  end

  it "fails closed on unsupported source and checkout values" do
    expect do
      described_class.new(
        mode: :agent_materialized,
        workspace_kind: :ticket_workspace,
        workspace_id: "Portal-42-ticket",
        freshness_policy: :reuse_if_clean_and_ref_matches,
        cleanup_policy: :retain_until_a3_cleanup,
        slots: {
          repo_alpha: {
            source: { kind: "remote_git", alias: "member-portal-starters" },
            ref: "refs/heads/a3/work/Portal-42",
            checkout: "clone",
            access: "read_write",
            sync_class: "eager",
            ownership: "edit_target",
            required: true
          }
        }
      )
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported source kind/)
  end

  it "requires explicit slot sync class and ownership metadata" do
    expect do
      described_class.new(
        mode: :agent_materialized,
        workspace_kind: :ticket_workspace,
        workspace_id: "Portal-42-ticket",
        freshness_policy: :reuse_if_clean_and_ref_matches,
        cleanup_policy: :retain_until_a3_cleanup,
        slots: {
          repo_alpha: {
            source: { kind: "local_git", alias: "member-portal-starters" },
            ref: "refs/heads/a3/work/Portal-42",
            checkout: "worktree_branch",
            access: "read_write",
            required: true
          }
        }
      )
    end.to raise_error(KeyError, /sync_class/)
  end

  it "rejects non-branch refs for worktree branch checkout" do
    expect do
      described_class.new(
        mode: :agent_materialized,
        workspace_kind: :ticket_workspace,
        workspace_id: "Portal-42-ticket",
        freshness_policy: :reuse_if_clean_and_ref_matches,
        cleanup_policy: :retain_until_a3_cleanup,
        slots: {
          repo_alpha: {
            source: { kind: "local_git", alias: "member-portal-starters" },
            ref: "abc123",
            checkout: "worktree_branch",
            access: "read_write",
            sync_class: "eager",
            ownership: "edit_target",
            required: true
          }
        }
      )
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported branch ref/)
  end

  it "rejects unsupported publish policy modes" do
    expect do
      described_class.new(
        mode: :agent_materialized,
        workspace_kind: :ticket_workspace,
        workspace_id: "Portal-42-ticket",
        freshness_policy: :reuse_if_clean_and_ref_matches,
        cleanup_policy: :retain_until_a3_cleanup,
        publish_policy: {
          mode: "apply_patch_in_engine",
          commit_message: "wrong"
        },
        slots: {
          repo_alpha: {
            source: { kind: "local_git", alias: "member-portal-starters" },
            ref: "refs/heads/a3/work/Portal-42",
            checkout: "worktree_branch",
            access: "read_write",
            sync_class: "eager",
            ownership: "edit_target",
            required: true
          }
        }
      )
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported agent workspace publish_policy mode/)
  end
end
