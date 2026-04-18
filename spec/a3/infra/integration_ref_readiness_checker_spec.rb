# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::IntegrationRefReadinessChecker do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "reports missing slots for a ref that is absent in part of the edit scope" do
    repo_alpha = File.join(@tmpdir, "repo-alpha")
    repo_beta = File.join(@tmpdir, "repo-beta")
    [repo_alpha, repo_beta].each do |path|
      system("git", "init", path, exception: true, out: File::NULL, err: File::NULL)
      File.write(File.join(path, "README.md"), "# test\n")
      system("git", "-C", path, "add", "README.md", exception: true, out: File::NULL, err: File::NULL)
      system("git", "-C", path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init", exception: true, out: File::NULL, err: File::NULL)
    end
    system("git", "-C", repo_beta, "update-ref", "refs/heads/a2o/parent/Sample-5200", "HEAD", exception: true, out: File::NULL, err: File::NULL)

    checker = described_class.new(
      repo_sources: {
        repo_alpha: repo_alpha,
        repo_beta: repo_beta
      }
    )

    result = checker.check(
      ref: "refs/heads/a2o/parent/Sample-5200",
      repo_slots: %i[repo_alpha repo_beta]
    )

    expect(result.ready?).to eq(false)
    expect(result.missing_slots).to eq([:repo_alpha])
  end
end
