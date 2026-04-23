# frozen_string_literal: true

module ParentChildTaskFixtureHelper
  DEFAULT_VERIFICATION_SCOPE = %i[repo_alpha repo_beta].freeze
  DEFAULT_PARENT_EDIT_SCOPE = %i[repo_alpha repo_beta].freeze

  def build_child_task(ref:, edit_scope:, status: :todo, parent_ref:, verification_scope: DEFAULT_VERIFICATION_SCOPE, current_run_ref: nil, verification_source_ref: nil, priority: 0)
    A3::Domain::Task.new(
      ref: ref,
      kind: :child,
      edit_scope: Array(edit_scope),
      verification_scope: verification_scope,
      status: status,
      current_run_ref: current_run_ref,
      parent_ref: parent_ref,
      verification_source_ref: verification_source_ref,
      priority: priority
    )
  end

  def build_parent_task(ref:, child_refs:, status: :todo, edit_scope: DEFAULT_PARENT_EDIT_SCOPE, verification_scope: DEFAULT_VERIFICATION_SCOPE, current_run_ref: nil, verification_source_ref: nil, priority: 0)
    A3::Domain::Task.new(
      ref: ref,
      kind: :parent,
      edit_scope: edit_scope,
      verification_scope: verification_scope,
      status: status,
      current_run_ref: current_run_ref,
      child_refs: child_refs,
      verification_source_ref: verification_source_ref,
      priority: priority
    )
  end
end
