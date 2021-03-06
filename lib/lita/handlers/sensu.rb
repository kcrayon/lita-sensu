require 'time'

module Lita
  module Handlers
    class Sensu < Handler
      # Handle errors
      # https://github.com/MrTin/lita-chuck_norris/blob/master/lib/lita/handlers/chuck_norris.rb

      config :api_url, default: '127.0.0.1', type: String
      config :domain, type: String
      config :api_user, type: String
      config :api_pass, type: String

      route(/^sensu client ([^\s]*$)/, :client, help: {"sensu client <client>" => "Shows information on a specific client"})
      route(/^sensu client ([^\s]*) history/, :client_history, help: {"sensu client <client> history" => "Shows history information for a specific client"})
      route(/^sensu clients/, :clients, help: {"sensu clients" => "List sensu clients"})
      route(/^sensu events(?: for (.*))?/, :events, help: {"sensu events [for <client>]" => "Shows current events, optionally for only a specific client"})
      route(/^sensu info/, :info, help: { "sensu info" => "Displays sensu information"})
      route(/^(?:sensu\s+)?remove client (.*)/, :remove_client, help: {"sensu remove client <client>" => "Remove client from sensu"})
      route(/^(?:sensu\s+)?resolve event (.*)(?:\/)(.*)/, :resolve, help: {"sensu resolve event <client>[/service]" => "Resolve event/all events for client"})
      route(/^(?:sensu\s+)?silence ([^\s\/]*)(?:\/)?([^\s]*)?(?: for (\d+)(\w))?(?: because (.*))?/, :silence, help: {"sensu silence <hostname>[/<check>][ for <duration><units>]" => "Silence event"})
      route(/^sensu stash(es)?/, :stashes, help: {"sensu stashes" => "Displays current sensu stashes"})

      def headers
        headers = {}
        if config.api_user
          headers["Authorization"] = "Basic #{Base64.encode64("#{config.api_user.chomp}:#{config.api_pass.chomp}")}"
        end
        headers
      end

      def http_get(url)
        http.get(url) do |req|
          req.headers = headers
        end
      end

      def http_delete(url)
        http.delete(url) do |req|
          req.headers = headers
        end
      end

      def http_post(url, data)
        http.post(url, data) do |req|
          req.headers = headers
        end
      end

      def client(response)
        client = add_domain(response.matches[0][0])
        resp = http_get("#{config.api_url}/clients/#{client}")
        if resp.status == 200
          client = MultiJson.load(resp.body, :symbolize_keys => true)
          response.reply(MultiJson.dump(client, :pretty => true))
        elsif resp.status == 404
          response.reply("#{client} was not found")
        else
          log.warn("Sensu returned an internal error fetching #{config.api_url}/clients/#{client}")
          response.reply("An error occurred fetching client #{client}")
        end
      end

      def client_history(response)
        client = add_domain(response.matches[0][0])
        resp = http_get("#{config.api_url}/clients/#{client}/history")
        if resp.status == 200
          history = MultiJson.load(resp.body, :symbolize_keys => true).sort{|a,b| a[:check]<=>b[:check]}
          response.reply(render_template('client_history', history: history))
        else
          log.warn("Sensu returned an internal error fetching #{config.api_url}/clients/#{client}/history")
          response.reply("An error occurred fetching client #{client} history")
        end
      end

      def clients(response)
        resp = http_get("#{config.api_url}/clients")
        if resp.status == 200
          clients = MultiJson.load(resp.body, :symbolize_keys => true).sort{|a,b| a[:name]<=>b[:name]}
          response.reply(render_template('clients', clients: clients))
        else
          log.warn("Sensu returned an internal error fetching #{config.api_url}/clients")
          response.reply('An error occurred fetching clients')
        end
      end

      def events(response)
        if response.matches[0][0]
          client = '/' + add_domain(response.matches[0][0])
        else
          client = ''
        end

        resp = http_get("#{config.api_url}/events#{client}")
        if resp.status == 200
          events = MultiJson.load(resp.body, :symbolize_keys => true).sort{|a,b| a[:client][:name]<=>b[:client][:name]}
          response.reply(render_template('events', events: events))
        else
          log.warn("Sensu returned an internal error fetching #{config.api_url}/events#{client}")
          response.reply('An error occurred fetching clients')
        end
      end

      def info(response)
        resp = http_get("#{config.api_url}/info")
        raise RequestError unless resp.status == 200
        info = MultiJson.load(resp.body, :symbolize_keys => true)
        response.reply(MultiJson.dump(info, :pretty => true))
      end

      def remove_client(response)
        client = add_domain(response.matches[0][0])
        resp = http_delete("#{config.api_url}/clients/#{client}")
        if resp.status == 202
          response.reply("#{client} removed")
        elsif resp.status == 404
          response.reply("#{client} was not found")
        else
          log.warn("Sensu returned an internal error deleting #{config.api_url}/clients/#{client}")
          response.reply("An error occurred removing #{client}")
        end
      end

      def resolve(response)
        client = add_domain(response.matches[0][0])
        check = response.matches[0][1]

        data = { :client => client, :check => check }
        resp = http_post("#{config.api_url}/resolve", MultiJson.dump(data))
        if resp.status == 202
          response.reply("#{client}/#{check} resolved")
        elsif resp.status == 400
          response.reply("Resolve message was malformed: #{MultiJson.dump(data)}")
        elsif resp.status == 404
          response.reply("#{client}/#{check} was not found")
        else
          log.warn("Sensu returned an internal error resolving #{config.api_url}/resolve with #{MultiJson.dump(data)}")
          response.reply("There was an error resolving #{client}/#{check}")
        end
      end

      def silence(response)
        client = add_domain(response.matches[0][0])
        check = response.matches[0][1] || nil
        duration = response.matches[0][2].to_i || nil
        units = response.matches[0][3] || nil
        reason = response.matches[0][4] || "silenced by #{response.user.name}"

        if check != nil && check != ''
          path = client + '/' + check
        else
          path = client
        end

        if units
          case units
          when 's'
            expiration = duration
          when 'm'
            expiration = duration * 60
          when 'h'
            expiration = duration * 3600
          when 'd'
            expiration = duration * 3600 * 24
          else
            response.reply("Unknown unit (#{units}).  I know s (seconds), m (minutes), h (hours), and d(days)")
            return
          end
          humanDuration = "#{duration}#{units}"
        else
          expiration = 3600
          humanDuration = "1h"
        end

        data = {
          :content => {
            :username => response.user.name,
            :reason => reason,
            :source => "lita",
            :timestamp => Time.now.to_i,
          },
          :expire => expiration,
          :path => "silence/#{path}",
        }

        resp = http_post("#{config.api_url}/stashes", MultiJson.dump(data))
        if resp.status == 201
          response.reply("#{path} silenced for #{humanDuration}")
        else
          log.warn("Sensu returned an internal error posting '#{MultiJson.dump(data)}' to #{config.api_url}/stashes")
          response.reply("An error occurred posting to #{path}")
        end
      end

      def stashes(response)
        resp = http_get("#{config.api_url}/stashes")
        if resp.status == 200
          stashes = MultiJson.load(resp.body, :symbolize_keys => true).sort{|a,b| a[:name]<=>b[:name]}
          response.reply(render_template('stashes', stashes: stashes))
        else
          log.warn("Sensu returned an internal error resolving #{config.api_url}/stashes")
          response.reply('An error occurred fetching stashes')
        end
      end

      private

      def add_domain(client)
        if config.domain && !client.include?(config.domain)
          if config.domain[0,1] == '.'
            return client + config.domain
          else
            return client + '.' + config.domain
          end
        else
          return client
        end
      end

    end

    Lita.register_handler(Sensu)
  end
end
