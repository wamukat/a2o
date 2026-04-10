# frozen_string_literal: true

require "json"

module A3
  module Infra
    class AgentHttpPullHandler
      Response = Struct.new(:status, :headers, :body, keyword_init: true)

      def initialize(job_store:, clock: -> { Time.now.utc.iso8601 })
        @job_store = job_store
        @clock = clock
      end

      def handle(method:, path:, query: {}, body: nil)
        case [method.to_s.upcase, path]
        when ["POST", "/v1/agent/jobs"]
          enqueue(body)
        when ["GET", "/v1/agent/jobs/next"]
          claim_next(query)
        else
          if method.to_s.upcase == "POST" && path.match?(%r{\A/v1/agent/jobs/[^/]+/result\z})
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

      def record_result(path, body)
        job_id = path.split("/")[-2]
        result = A3::Domain::AgentJobResult.from_result_form(parse_body(body))
        raise A3::Domain::ConfigurationError, "result path job_id #{job_id} does not match payload #{result.job_id}" unless result.job_id == job_id

        record = @job_store.complete(result)
        json_response(200, "job" => record.persisted_form)
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
