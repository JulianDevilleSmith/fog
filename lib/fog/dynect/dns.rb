require File.expand_path(File.join(File.dirname(__FILE__), '..', 'dynect'))
require 'fog/dns'

module Fog
  module DNS
    class Dynect < Fog::Service

      requires :dynect_customer, :dynect_username, :dynect_password
      recognizes :timeout, :persistent
      recognizes :provider # remove post deprecation

      model_path 'fog/dynect/models/dns'
      model       :record
      collection  :records
      model       :zone
      collection  :zones

      request_path 'fog/dynect/requests/dns'
      request :delete_record
      request :delete_zone
      request :get_node_list
      request :get_record
      request :get_zone
      request :post_record
      request :post_session
      request :post_zone
      request :put_zone

      class JobIncomplete < Error; end

      class Mock
        def initialize(options={})
          @dynect_customer = options[:dynect_customer]
          @dynect_username = options[:dynect_username]
          @dynect_password = options[:dynect_password]
        end

        def self.data
          @data ||= {
            :zones => {}
          }
        end

        def self.reset
          @data = nil
        end

        def auth_token
          @auth_token ||= Fog::Dynect::Mock.token
        end

        def data
          self.class.data
        end

        def reset_data
          self.class.reset
        end
      end

      class Real
        def initialize(options={})
          @dynect_customer = options[:dynect_customer]
          @dynect_username = options[:dynect_username]
          @dynect_password = options[:dynect_password]

          @connection_options = options[:connection_options] || {}
          @host       = "api2.dynect.net"
          @port       = options[:port]        || 443
          @path       = options[:path]        || '/REST'
          @persistent = options[:persistent]  || true
          @scheme     = options[:scheme]      || 'https'
          @version    = options[:version]     || '2.3.1'
          @connection = Fog::Connection.new("#{@scheme}://#{@host}:#{@port}", @persistent, @connection_options)
        end

        def auth_token
          @auth_token ||= post_session.body['data']['token']
        end

        def request(params)
          begin
            # any request could redirect to a job
            params[:expects] = Array(params[:expects]) | [307]

            params[:headers] ||= {}
            params[:headers]['Content-Type'] = 'application/json'
            params[:headers]['API-Version'] = @version
            params[:headers]['Auth-Token'] = auth_token unless params[:path] == "Session"
            params[:path] = "#{@path}/#{params[:path]}" unless params[:path] =~ %r{^#{Regexp.escape(@path)}/}
            response = @connection.request(params.merge!({:host => @host}))

            if response.status == 307
              response = poll_job(response)
            elsif !response.body.empty?
              response.body = Fog::JSON.decode(response.body)
            end

            response
          rescue Excon::Errors::HTTPStatusError => error
            if @auth_token && error.message =~ /login: (Bad or expired credentials|inactivity logout)/
              @auth_token = nil
              retry
            else
              raise error
            end
          end

          response
        end

        def poll_job(response, time_to_wait = 10)
          job_location = response.headers['Location']

          Fog.wait_for(time_to_wait) do
            response = request(:expects => 200, :method => :get, :path => job_location)
            response.body['status'] != 'incomplete'
          end

          if response.body['status'] == 'incomplete'
            raise JobIncomplete.new("Job #{response.body['job_id']} is still incomplete")
          end

          response
        end
      end

    end
  end
end
