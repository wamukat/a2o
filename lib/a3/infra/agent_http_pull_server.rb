# frozen_string_literal: true

require "json"
require "uri"
require "socket"

module A3
  module Infra
    class AgentHttpPullServer
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 7393

      REASON_PHRASES = {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error"
      }.freeze

      def initialize(handler:, host: DEFAULT_HOST, port: DEFAULT_PORT)
        @handler = handler
        @server = TCPServer.new(host, port)
        @shutdown = false
      end

      def start
        until @shutdown
          begin
            client = @server.accept
            handle_client(client)
          rescue IOError, Errno::EBADF
            break if @shutdown

            raise
          end
        end
      end

      def shutdown
        @shutdown = true
        @server.close unless @server.closed?
      end

      def bound_port
        @server.addr.fetch(1)
      end

      private

      def handle_client(client)
        request_line = client.gets&.strip
        return unless request_line

        method, request_target, = request_line.split(" ", 3)
        headers = read_headers(client)
        body = read_body(client, headers)
        uri = URI.parse(request_target)
        handler_response = @handler.handle(
          method: method,
          path: uri.path,
          query: parse_query(uri.query),
          body: body
        )
        write_response(client, handler_response)
      rescue URI::InvalidURIError => e
        write_response(client, A3::Infra::AgentHttpPullHandler::Response.new(
          status: 400,
          headers: {"content-type" => "application/json"},
          body: JSON.generate("error" => e.message)
        ))
      ensure
        client.close unless client.closed?
      end

      def read_headers(client)
        headers = {}
        while (line = client.gets)
          line = line.strip
          break if line.empty?

          key, value = line.split(":", 2)
          headers[key.downcase] = value.to_s.strip if key
        end
        headers
      end

      def read_body(client, headers)
        length = Integer(headers.fetch("content-length", "0"))
        return nil if length.zero?

        client.read(length)
      end

      def parse_query(query_string)
        URI.decode_www_form(query_string.to_s).to_h
      end

      def write_response(client, handler_response)
        body = handler_response.status == 204 ? "" : handler_response.body.to_s
        reason = REASON_PHRASES.fetch(handler_response.status, "OK")
        client.write("HTTP/1.1 #{handler_response.status} #{reason}\r\n")
        handler_response.headers.each { |key, value| client.write("#{key}: #{value}\r\n") }
        client.write("content-length: #{body.bytesize}\r\n")
        client.write("connection: close\r\n")
        client.write("\r\n")
        client.write(body)
      end
    end
  end
end
