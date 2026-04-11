# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module A3
  module Agent
    class HttpControlPlaneClient
      def initialize(base_url:, auth_token: nil)
        @base_uri = URI(base_url)
        @auth_token = auth_token.to_s
      end

      def claim_next(agent_name:)
        uri = endpoint("/v1/agent/jobs/next")
        uri.query = URI.encode_www_form("agent" => agent_name)
        request = Net::HTTP::Get.new(uri)
        authorize(request)
        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        return nil if response.code == "204"

        raise "claim_next failed: HTTP #{response.code} #{response.body}" unless response.code == "200"

        A3::Domain::AgentJobRequest.from_request_form(JSON.parse(response.body).fetch("job"))
      end

      def upload_artifact(upload, content)
        uri = endpoint("/v1/agent/artifacts/#{URI.encode_www_form_component(upload.artifact_id)}")
        uri.query = URI.encode_www_form(upload.persisted_form.reject { |key, _value| key == "artifact_id" })
        request = Net::HTTP::Put.new(uri)
        authorize(request)
        request.body = content
        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        raise "upload_artifact failed: HTTP #{response.code} #{response.body}" unless response.code == "201"

        A3::Domain::AgentArtifactUpload.from_persisted_form(JSON.parse(response.body).fetch("artifact"))
      end

      def submit_result(result)
        uri = endpoint("/v1/agent/jobs/#{URI.encode_www_form_component(result.job_id)}/result")
        request = Net::HTTP::Post.new(uri)
        request["content-type"] = "application/json"
        authorize(request)
        request.body = JSON.generate(result.result_form)
        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        raise "submit_result failed: HTTP #{response.code} #{response.body}" unless response.code == "200"

        true
      end

      private

      def endpoint(path)
        uri = @base_uri.dup
        uri.path = path
        uri.query = nil
        uri
      end

      def authorize(request)
        request["authorization"] = "Bearer #{@auth_token}" unless @auth_token.empty?
      end
    end
  end
end
