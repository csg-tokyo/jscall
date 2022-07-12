# frozen_string_literal: true

# Copyright (C) 2022- Shigeru Chiba.  All rights reserved.

require 'webrick'

module Jscall
    WEBrick::HTTPUtils::DefaultMimeTypes['mjs'] ||= "application/javascript"

    class Dom
        # see Jscall class in browser.mjs
        def method_missing(name, *args)
            Jscall.__getpipe__.funcall(nil, "Jscall.#{name}", args)
        end
    end

    @js_dom = Dom.new

    def self.dom
        @js_dom
    end

    class PipeToJs
    end

    class PipeToBrowser < PipeToJs
        def startJS(module_names, config)
            urls = {}
            module_names.each_index do |i|
                mod = module_names[i]
                urls[mod[2]] = mod
            end
            port = config[:port] || 10081
            @pipe = FetchServer.new(port, urls)
            @pipe.open
        end

        def setup(config)
            if config[:browser]
                module_names = config[:module_names] || []
                module_names.each_index do |i|
                    mod = module_names[i]
                    Jscall.dyn_import(mod[2], mod[0])
                end
            end
        end

        def close
            @pipe.shutdown
            sleep(0.5)
            true
        end

        def soft_close
            @pipe.close
            false
        end
    end

    class FetchServer
        @@webpage = '/jscall/jscall.html'

        @@run_cmd = case RbConfig::CONFIG['host_os']
        when /linux/
            'xdg-open'
        when /darwin|mac os/
            'open'
        else
            'start'
        end

        def self.open_command=(name)
            @@run_cmd = name
        end

        def initialize(port, urls)
            @url_map = urls
            @send_buffer = Thread::Queue.new
            @receive_buffer = Thread::Queue.new
            @server_running = false

            @server = WEBrick::HTTPServer.new(
                # :DoNotReverseLookup => true,
                :DocumentRoot => './',
                :BindAddress => '0.0.0.0',
                :Port => port,
                :ServerType => Thread,
                :Logger => WEBrick::Log.new(nil, WEBrick::Log::ERROR),
                :AccessLog => []
            )

            @server.mount_proc('/') do |req, res|
                peer_address  = req.peeraddr[3]
                if peer_address != '127.0.0.1'
                    $stderr.puts "access denied address=#{peer_address}"
                    raise WEBrick::HTTPStatus::Forbidden
                end

                if req.path.start_with?('/cmd/')
                    read_stream(req, res)
                else
                    read_file(req, res)
                end
            end
        end

        def read_stream(req, res)
            body = req.body
            @receive_buffer.push(if body.nil? then '' else body end)
            res.content_type = "text/plain"
            res.body = @send_buffer.pop
        end

        def read_file(req, res)
            path = req.path
            if path.start_with?('/jscall/')
                root = "#{__dir__}/../"
            else
                value = @url_map[path]
                if value.nil?
                    root = @server.config[:DocumentRoot]
                else
                    root = value[1]
                end
            end
            WEBrick::HTTPServlet::FileHandler.new(@server, root).service(req, res)
        end

        def open
            if @server_running
                close
            else
                @server_running = true
                if @server.status != :Running
                    Signal.trap(:INT){ @server.shutdown }
                    @server.start
                    Thread.pass
                end
            end
            raise "A web page was reloaded" unless @receive_buffer.empty?
            status = system "#{@@run_cmd} http://localhost:#{@server[:Port]}#{@@webpage}"
            raise "cannot launch a web browser by '#{@@run_cmd}'" if status.nil?
            unless @receive_buffer.pop == 'start'
                raise 'failed to initialize JavaScript'
            end
        end

        def close
            puts('done')
            @server_running = false
        end

        def closed?
            !@server_running
        end

        def autoclose=(value)
            false
        end

        def shutdown
            close
            @server.stop
        end

        def puts(msg)
            @send_buffer.push(msg)
            Thread.pass
        end

        def gets
            @receive_buffer.pop
        end
    end
end
