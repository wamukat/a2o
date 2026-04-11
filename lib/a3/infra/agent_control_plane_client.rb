# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module A3
  module Infra
    class AgentControlPlaneClient
      attr_reader :base_url

      def initialize(base_url:, auth_token: nil)
        @base_url = base_url.to_s
        @base_uri = URI(@base_url)
        @auth_token = auth_token.to_s
      end

      def enqueue(request)
        uri = endpoint("/v1/agent/jobs")
        http_request = Net::HTTP::Post.new(uri)
        http_request["content-type"] = "application/json"
        authorize(http_request)
        http_request.body = JSON.generate(request.request_form)
        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(http_request) }
        raise "enqueue failed: HTTP #{response.code} #{response.body}" unless response.code == "201"

        A3::Domain::AgentJobRecord.from_persisted_form(JSON.parse(response.body).fetch("job"))
      end

      def fetch(job_id)
        uri = endpoint("/v1/agent/jobs/#{URI.encode_www_form_component(job_id)}")
        request = Net::HTTP::Get.new(uri)
        authorize(request)
        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        raise "fetch failed: HTTP #{response.code} #{response.body}" unless response.code == "200"

        A3::Domain::AgentJobRecord.from_persisted_form(JSON.parse(response.body).fetch("job"))
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
