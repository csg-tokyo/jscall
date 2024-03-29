# frozen_string_literal: true

# Copyright (C) 2022- Shigeru Chiba.  All rights reserved.

require "json"
require "weakref"

require_relative "jscall/version"
require_relative "jscall/browser"

module Jscall
    @@debug = 0

    # Current debug level (>= 0)
    def self.debug() @@debug end

    # Sets the current debug level.
    def self.debug=(level)
        @@debug = level
    end

    TableSize = 100

    class JavaScriptError < RuntimeError
        def initialize(msg)
            super(msg)
        end
    end

    class HiddenRef
        def initialize(obj)
            @object = obj
        end
        def __getobj__()
            @object
        end
    end

    class Exported      # inbound referneces from Node to Ruby
        attr_reader :objects

        def initialize
            ary = Array.new(Jscall::TableSize) {|i| i + 1}
            ary[-1] = -1
            @objects = HiddenRef.new(ary)
            @free_element = 0
            @hashtable = HiddenRef.new({})
        end

        def export(obj)
            hash = @hashtable.__getobj__
            if hash.include?(obj)
                hash[obj]
            else
                objs = @objects.__getobj__
                idx = @free_element
                if idx < 0
                    idx = objs.size
                else
                    @free_element = objs[idx]
                end
                objs[idx] = obj
                hash[obj] = idx   # return idx
            end
        end

        def find(idx)
            obj = @objects.__getobj__[idx]
            if obj.is_a?(Numeric)
                raise JavaScriptError.new("unknown index is given to find(): #{idx}")
            else
                obj
            end
        end

        def remove(idx)
            objects = @objects.__getobj__
            obj = objects[idx]
            if obj.is_a?(Numeric)
                raise JavaScriptError.new("unknown index is given to remove(): #{idx}")
            else
                objects[idx] = @free_element
                @free_element = idx
                @hashtable.__getobj__.delete(obj)
            end
        end
    end

    class RemoteRef
        def initialize(id)
            @id = id
        end

        def __get_id
            @id
        end

        def async
            AsyncRemoteRef.new(@id)
        end

        # override Object#then
        def then(*args)
            send('then', *args)
        end

        # puts() calls this
        def to_ary
            ["#<RemoteRef @id=#{@id}>"]
        end

        # override Object#send
        def send(name, *args)
            Jscall.__getpipe__.funcall(self, name, args)
        end

        def async_send(name, *args)
            Jscall.__getpipe__.async_funcall(self, name, args)
        end

        def method_missing(name, *args)
            Jscall.__getpipe__.funcall(self, name, args)
        end
    end

    class AsyncRemoteRef < RemoteRef
        alias send async_send

        def method_missing(name, *args)
            Jscall.__getpipe__.async_funcall(self, name, args)
        end
    end

    class Imported      # outbound references from Ruby to Node
        attr_reader :objects

        def initialize
            ary = Array.new(Jscall::TableSize, nil)
            @objects = HiddenRef.new(ary)
            @canary = WeakRef.new(RemoteRef.new(-1))
        end

        def import(index)
            objects = @objects.__getobj__
            wref = objects[index]
            if  wref&.weakref_alive?
                wref.__getobj__
            else
                rref = RemoteRef.new(index)
                objects[index] = WeakRef.new(rref)
                rref
            end
        end

        # forces dead_references() to check the liveness of references.
        def kill_canary
            @canary = nil
        end

        def dead_references()
            if @canary&.weakref_alive?
                return []
            else
                @canary = WeakRef.new(RemoteRef.new(-1))
            end
            deads = []
            objects = @objects.__getobj__
            objects.each_index do |index|
                wref = objects[index]
                if !wref.nil? && !wref.weakref_alive?
                    objects[index] = nil
                    deads << index
                end
            end
            deads
        end
    end

    class PipeToJs
        CMD_EVAL = 1
        CMD_CALL = 2
        CMD_REPLY = 3
        CMD_ASYNC_CALL = 4
        CMD_ASYNC_EVAL = 5
        CMD_RETRY = 6
        CMD_REJECT = 7

        Param_array = 0
        Param_object = 1
        Param_local_object = 2
        Param_error = 3
        Param_hash = 4

        Header_size = 6
        Header_format = '%%0%dx' % Header_size

        @@node_cmd = 'node'

        def self.node_command=(cmd)
            @@node_cmd = cmd
        end

        def initialize(config)
            @exported = Exported.new
            @imported = Imported.new
            @send_counter = 0
            @num_generated_ids = 0
            @pending_replies = {}
            module_names = config[:module_names] || []
            startJS(module_names, config)
        end

        def setup(config)
            # called just after executing new PipeToJs(config)
        end

        # Config options.
        #
        # module_names: an array of [module_name, module_root, module_file_name]
        #   For example,
        #     [['Foo', '/home/jscall', '/lib/foo.mjs']]
        #   this does
        #     import * as Foo from "/home/jscall/lib/foo.mjs"
        #
        # options: options passed to node.js
        #
        def startJS(module_names, config)
            options = config[:options] || ''
            script2 = ''
            module_names.each_index do |i|
                script2 += "import * as m#{i + 2} from \"#{module_names[i][1]}#{module_names[i][2]}\"; globalThis.#{module_names[i][0]} = m#{i + 2}; "
            end
            script2 += "import { createRequire } from \"node:module\"; globalThis.require = createRequire(\"file://#{Dir.pwd}/\");"
            main_js_file = if config[:sync] then "synch.mjs" else "main.mjs" end
            script = "'import * as m1 from \"#{__dir__}/jscall/#{main_js_file}\"; globalThis.Ruby = m1; #{script2}; Ruby.start(process.stdin, true)'"
            @pipe = IO.popen("#{@@node_cmd} #{options} --input-type 'module' -e #{script}", "r+t")
            @pipe.autoclose = true
        end

        def get_exported_imported
            [@exported, @imported]
        end

        def close
            @pipe.close
            true
        end

        def encode_obj(obj)
            if obj.is_a?(Numeric) || obj.is_a?(String) || obj.is_a?(Symbol) || obj == true || obj == false || obj == nil
                obj
            elsif obj.is_a?(Array)
                [Param_array, obj.map {|e| encode_obj(e)}]
            elsif obj.is_a?(Hash)
                hash2 = {}
                obj.each {|key, value| hash2[key] = encode_obj(value) }
                [Param_hash, hash2]
            elsif obj.is_a?(RemoteRef)
                [Param_local_object, obj.__get_id]
            else
                [Param_object, @exported.export(obj)]
            end
        end

        def encode_error(msg)
            [Param_error, msg]
        end

        def decode_obj(obj)
            if obj.is_a?(Numeric) || obj.is_a?(String) || obj == true || obj == false || obj == nil
                obj
            elsif obj.is_a?(Array) && obj.size == 2
                if obj[0] == Param_array
                    obj[1].map {|e| decode_obj(e)}
                elsif obj[0] == Param_hash
                    hash = {}
                    obj[1].each {|key, value| hash[key] = decode_obj(value)}
                    hash
                elsif obj[0] == Param_object
                    @imported.import(obj[1])
                elsif obj[0] == Param_local_object
                    @exported.find(obj[1])
                else  # if Param_error
                    JavaScriptError.new(obj[1])
                end
            else
                raise JavaScriptError.new('the result is a broken value')
            end
        end

        def fresh_id
            @num_generated_ids += 1
        end

        def funcall(receiver, name, args)
            cmd = [CMD_CALL, nil, encode_obj(receiver), name, args.map {|e| encode_obj(e)}]
            send_command(cmd)
        end

        def async_funcall(receiver, name, args)
            cmd = [CMD_ASYNC_CALL, nil, encode_obj(receiver), name, args.map {|e| encode_obj(e)}]
            send_command(cmd)
        end

        def exec(src)
            cmd = [CMD_EVAL, nil, src]
            send_command(cmd)
        end

        def async_exec(src)
            cmd = [CMD_ASYNC_EVAL, nil, src]
            send_command(cmd)
        end

        def encode_eval_error(e)
            traces = e.backtrace
            location = if traces.size > 0 then traces[0] else '' end
            if Jscall.debug > 0
                encode_error("\n#{e.full_message}")
            else
                encode_error(location + ' ' + e.to_s)
            end
        end

        def scavenge
            @send_counter = 200
            @imported.kill_canary
            exec 'Ruby.scavenge_references()'
        end

        def send_with_piggyback(cmd)
            threashold = 100
            @send_counter += 1
            if (@send_counter > threashold)
                @send_counter = 0
                dead_refs = @imported.dead_references()
                if (dead_refs.length > 0)
                    cmd2 = cmd.dup
                    cmd2[5] = dead_refs
                    return cmd2
                end
            end
            return cmd
        end

        def send_command(cmd)
            message_id = (cmd[1] ||= fresh_id)
            json_data = JSON.generate(send_with_piggyback(cmd))
            header = (Header_format % json_data.length)
            if header.length != Header_size
                raise "message length limit exceeded"
            end
            json_data_with_header = header + json_data
            @pipe.puts(json_data_with_header)

            while true
                reply_data = @pipe.gets
                reply = JSON.parse(reply_data || '[]')
                if reply.length > 5
                    reply[5].each {|idx| @exported.remove(idx) }
                    reply[5] = nil
                end
                if @pipe.closed?
                    raise RuntimeError.new("connection closed: #{reply}")
                elsif reply[0] == CMD_REPLY
                    result = decode_obj(reply[2])
                    if reply[1] != message_id
                        @pending_replies[reply[1]] = result
                        send_reply(reply[1], nil, false, CMD_REJECT)
                    elsif result.is_a?(JavaScriptError)
                        raise result
                    else
                        return result
                    end
                elsif reply[0] == CMD_EVAL
                    begin
                        result = Object::TOPLEVEL_BINDING.eval(reply[2])
                        send_reply(reply[1], result)
                    rescue => e
                        send_error(reply[1], e)
                    end
                elsif reply[0] == CMD_CALL
                    begin
                        receiver = decode_obj(reply[2])
                        name = reply[3]
                        args = reply[4].map {|e| decode_obj(e)}
                        result = receiver.public_send(name, *args)
                        send_reply(reply[1], result)
                    rescue => e
                        send_error(reply[1], e)
                    end
                elsif reply[0] == CMD_RETRY
                    if reply[1] != message_id
                        send_reply(reply[1], nil, false, CMD_REJECT)
                    else
                        if @pending_replies.key?(message_id)
                            result = @pending_replies.delete(message_id)
                            if result.is_a?(JavaScriptError)
                                raise result
                            else
                                return result
                            end
                        else
                            raise RuntimeError.new("bad CMD_RETRY: #{reply}")
                        end
                    end
                else
                    # CMD_REJECT and other unknown commands
                    raise RuntimeError.new("bad message: #{reply}")
                end
            end
        end

        def send_reply(message_id, value, erroneous = false, cmd_id=CMD_REPLY)
            if erroneous
                encoded = encode_eval_error(value)
            else
                encoded = encode_obj(value)
            end
            json_data = JSON.generate(send_with_piggyback([cmd_id, message_id, encoded]))
            header = (Header_format % json_data.length)
            if header.length != Header_size
                raise "message length limit exceeded"
            end
            json_data_with_header = header + json_data
            @pipe.puts(json_data_with_header)
        end

        def send_error(message_id, e)
            send_reply(message_id, e, true)
        end
    end

    @pipe = nil
    @configurations = {}
    @pipeToJsClass = PipeToJs

    #def self.config(module_names: [], options: '', browser: false, sync: false)
    def self.config(**kw)
        if kw.nil? || kw == {}
            @configurations = {}
        else
            @configurations = @configurations.merge!(kw)
        end
        browser = @configurations[:browser]
        @pipeToJsClass = if browser then PipeToBrowser else PipeToJs end
        nil
    end

    def self.close
        @pipe = nil if @pipe.close  unless @pipe.nil?
    end

    Signal.trap(0) { self.close }  # close before termination

    # reclaim unused remote references.
    #
    def self.scavenge_references
        __getpipe__.scavenge
    end

    def self.__getpipe__
        if @pipe.nil?
            @pipe = @pipeToJsClass.new(@configurations)
            @pipe.setup(@configurations)
        end
        @pipe
    end

    module Interface
        def exec(src)
            __getpipe__.exec(src)
        end

        def async_exec(src)
            __getpipe__.async_exec(src)
        end

        # name is a string object.
        # Evaluating this string in JavaScript results in a JavaScript function.
        #
        def funcall(name, *args)
            __getpipe__.funcall(nil, name, args)
        end

        def async_funcall(name, *args)
            __getpipe__.async_funcall(nil, name, args)
        end

        def dyn_import(name, var_name=nil)
            funcall('Ruby.dyn_import', name, var_name)
        end

        def method_missing(name, *args)
            funcall(name, *args)
        end
    end

    extend Interface

    module AsyncInterface
        include Interface

        alias exec async_exec
        alias funcall async_funcall
    end

    def self.async
        @async ||= Class.new do
            def __getpipe__
                Jscall.__getpipe__
            end

            include AsyncInterface
        end.new
    end
end
