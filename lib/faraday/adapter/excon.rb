# frozen_string_literal: true

module Faraday
  class Adapter
    # Excon adapter.
    class Excon < Faraday::Adapter
      dependency 'excon'

      def call(env)
        super

        opts = opts_from_env(env)
        conn = create_connection(env, opts)

        resp = conn.request(method: env[:method].to_s.upcase,
                            headers: env[:request_headers],
                            body: read_body(env))

        req = env[:request]
        if req&.stream_response?
          warn "Streaming downloads for #{self.class.name} are not yet " \
               ' implemented.'
          req.on_data.call(resp.body, resp.body.bytesize)
        end
        save_response(env, resp.status.to_i, resp.body, resp.headers,
                      resp.reason_phrase)

        @app.call(env)
      rescue ::Excon::Errors::SocketError => e
        raise Faraday::TimeoutError, e if e.message =~ /\btimeout\b/

        raise Faraday::SSLError, e if e.message =~ /\bcertificate\b/

        raise Faraday::ConnectionFailed, e
      rescue ::Excon::Errors::Timeout => e
        raise Faraday::TimeoutError, e
      end

      # @return [Excon]
      def create_connection(env, opts)
        ::Excon.new(env[:url].to_s, opts.merge(@connection_options))
      end

      # TODO: support streaming requests
      def read_body(env)
        env[:body].respond_to?(:read) ? env[:body].read : env[:body]
      end

      private

      def opts_from_env(env)
        opts = {}
        amend_opts_with_ssl!(opts, env[:ssl]) if needs_ssl_settings?(env)

        if (req = env[:request])
          amend_opts_with_timeouts!(opts, req)
          amend_opts_with_proxy_settings!(opts, req)
        end

        opts
      end

      def needs_ssl_settings?(env)
        env[:url].scheme == 'https' && env[:ssl]
      end

      OPTS_KEYS = [
        %i[client_cert client_cert],
        %i[client_key client_key],
        %i[certificate certificate],
        %i[private_key private_key],
        %i[ssl_ca_path ca_path],
        %i[ssl_ca_file ca_file],
        %i[ssl_version version],
        %i[ssl_min_version min_version],
        %i[ssl_max_version max_version]
      ].freeze

      def amend_opts_with_ssl!(opts, ssl)
        opts[:ssl_verify_peer] = !!ssl.fetch(:verify, true)
        # https://github.com/geemus/excon/issues/106
        # https://github.com/jruby/jruby-ossl/issues/19
        opts[:nonblock] = false

        OPTS_KEYS.each do |(key_in_opts, key_in_ssl)|
          next unless ssl[key_in_ssl]

          opts[key_in_opts] = ssl[key_in_ssl]
        end
      end

      def amend_opts_with_timeouts!(opts, req)
        timeout = req[:timeout]
        return unless timeout

        opts[:read_timeout] = timeout
        opts[:connect_timeout] = timeout
        opts[:write_timeout] = timeout

        open_timeout = req[:open_timeout]
        return unless open_timeout

        opts[:connect_timeout] = open_timeout
      end

      def amend_opts_with_proxy_settings!(opts, req)
        opts[:proxy] = proxy_settings_for_opts(req[:proxy]) if req[:proxy]
      end

      def proxy_settings_for_opts(proxy)
        {
          host: proxy[:uri].host,
          hostname: proxy[:uri].hostname,
          port: proxy[:uri].port,
          scheme: proxy[:uri].scheme,
          user: proxy[:user],
          password: proxy[:password]
        }
      end
    end
  end
end
