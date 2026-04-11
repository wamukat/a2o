# frozen_string_literal: true

require "json"

module A3
  module Infra
    class AgentHttpPullHandler
      Response = Struct.new(:status, :headers, :body, keyword_init: true)

      def initialize(job_store:, artifact_store: nil, clock: -> { Time.now.utc.iso8601 }, auth_token: nil, control_auth_token: nil)
        @job_store = job_store
        @artifact_store = artifact_store
        @clock = clock
        @auth_token = auth_token.to_s
        @control_auth_token = control_auth_token.to_s
      end

      def handle(method:, path:, query: {}, body: nil, headers: {})
        case [method.to_s.upcase, path]
        when ["POST", "/v1/agent/jobs"]
          return unauthorized_response unless authorized?(headers, :control)

          enqueue(body)
        when ["GET", "/v1/agent/jobs/next"]
          return unauthorized_response unless authorized?(headers, :agent)

          claim_next(query)
        else
          if method.to_s.upcase == "GET" && path.match?(%r{\A/v1/agent/jobs/[^/]+\z})
            return unauthorized_response unless authorized?(headers, :control)

            fetch_job(path)
          elsif method.to_s.upcase == "PUT" && path.match?(%r{\A/v1/agent/artifacts/[^/]+\z})
            return unauthorized_response unless authorized?(headers, :agent)

            upload_artifact(path, query, body)
          elsif method.to_s.upcase == "POST" && path.match?(%r{\A/v1/agent/jobs/[^/]+/result\z})
            return unauthorized_response unless authorized?(headers, :agent)

            record_result(path, body)
          else
            json_response(404, "error" => "not_found")
          end
        end
      rescue A3::Domain::RecordNotFound => e
        json_response(404, "error" => e.message)
      rescue KeyError, JSON::ParserError, A3::Domain::ConfigurationError => e
        json_response(400, "error" => e.message)
      end

      private

      def authorized?(headers, scope)
        expected = expected_token(scope)
        return true if expected.empty?

        header_value = headers.fetch("authorization", headers.fetch("Authorization", "")).to_s
        header_value == "Bearer #{expected}"
      end

      def expected_token(scope)
        return @control_auth_token unless scope == :agent || @control_auth_token.empty?

        @auth_token
      end

      def unauthorized_response
        json_response(401, "error" => "unauthorized")
      end

      def enqueue(body)
        request = A3::Domain::AgentJobRequest.from_request_form(parse_body(body))
        record = @job_store.enqueue(request)
        json_response(201, "job" => record.persisted_form)
      end

      def claim_next(query)
        agent_name = required_query(query, "agent")
        record = @job_store.claim_next(agent_name: agent_name, claimed_at: @clock.call)
        return json_response(204, {}) unless record

        json_response(200, "job" => record.request.request_form)
      end

      def fetch_job(path)
        job_id = path.split("/").last
        record = @job_store.fetch(job_id)
        json_response(200, "job" => record.persisted_form)
      end

      def record_result(path, body)
        job_id = path.split("/")[-2]
        result = A3::Domain::AgentJobResult.from_result_form(parse_body(body))
        raise A3::Domain::ConfigurationError, "result path job_id #{job_id} does not match payload #{result.job_id}" unless result.job_id == job_id

        record = @job_store.complete(result)
        json_response(200, "job" => record.persisted_form)
      end

      def upload_artifact(path, query, body)
        raise A3::Domain::ConfigurationError, "agent artifact store is not configured" unless @artifact_store

        upload = A3::Domain::AgentArtifactUpload.new(
          artifact_id: path.split("/").last,
          role: required_query(query, "role"),
          digest: required_query(query, "digest"),
          byte_size: required_query(query, "byte_size"),
          retention_class: required_query(query, "retention_class"),
          media_type: query["media_type"]
        )
        stored = @artifact_store.put(upload, body.to_s)
        json_response(201, "artifact" => stored.persisted_form)
      end

      def parse_body(body)
        JSON.parse(body.to_s)
      end

      def required_query(query, key)
        value = query[key].to_s
        raise A3::Domain::ConfigurationError, "missing query parameter: #{key}" if value.empty?

        value
      end

      def json_response(status, payload)
        Response.new(
          status: status,
          headers: {"content-type" => "application/json"},
          body: JSON.generate(payload)
        )
      end
    end
  end
end
