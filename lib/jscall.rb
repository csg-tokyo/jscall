# frozen_string_literal: true

# Copyright (C) 2022- Shigeru Chiba.  All rights reserved.

require "json"
require "weakref"

require_relative "jscall/version"
require_relative "jscall/browser"

module Jscall
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
        attr_reader :id

        def initialize(id)
            @id = id
        end

        # override Object#then
        def then(*args)
            method_missing('then', *args)
        end

        # override Object#send
        def send(name, *args)
            Jscall.__getpipe__.funcall(self, name, args)
        end

        def method_missing(name, *args)
            Jscall.__getpipe__.funcall(self, name, args)
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
        Param_array = 0
        Param_object = 1
        Param_local_object = 2
        Param_error = 3

        @@node_cmd = 'node'

        def self.node_command=(cmd)
            @@node_cmd = cmd
        end

        # do import * as 'module_names[i][0]' from 'module_names[i][1]' 
        #
        def initialize(module_names=[], options='')
            startJS(module_names, options)
            @exported = Exported.new
            @imported = Imported.new
            @send_counter = 0
        end

        # module_names: an array of [module_name, module_file_name]
        #
        def startJS(module_names, options)
            script2 = ''
            module_names.each_index do |i|
                script2 += "import * as m#{i + 2} from \"#{module_names[i][1]}\"; globalThis.#{module_names[i][0]} = m#{i + 2}; "
            end
            script2 += "import { createRequire } from \"node:module\"; globalThis.require = createRequire(\"file://#{Dir.pwd}/\");"
            script = "'import * as m1 from \"#{__dir__}/jscall/main.mjs\"; globalThis.Ruby = m1; #{script2}; Ruby.start(process.stdin, true)'"
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
            elsif obj.is_a?(RemoteRef)
                [Param_local_object, obj.id]
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
                if (obj[0] == Param_array)
                    obj[1].map {|e| decode_obj(e)}
                elsif (obj[0] == Param_object)
                    @imported.import(obj[1])
                elsif (obj[0] == Param_local_object)
                    @exported.find(obj[1])
                else  # if Param_error
                    JavaScriptError.new(obj[1])
                end
            else
                raise JavaScriptError.new('the result is a broken value')
            end
        end

        def funcall(receiver, name, args)
            cmd = [CMD_CALL, encode_obj(receiver), name, args.map {|e| encode_obj(e)}]
            send_command(cmd)
        end

        def exec(src)
            cmd = [CMD_EVAL, src]
            send_command(cmd)
        end

        def encode_eval_error(e)
            traces = e.backtrace
            location = if traces.size > 0 then traces[0] else '' end
            encode_error(location + ' ' + e.to_s)
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
                    cmd2[4] = dead_refs
                    return cmd2
                end
            end
            return cmd
        end

        def send_command(cmd)
            json_data = JSON.generate(send_with_piggyback(cmd))
            @pipe.puts(json_data)
            reply_data = @pipe.gets
            reply = JSON.parse(reply_data || '[]')
            if reply.length > 4
                reply[4].each {|idx| @exported.remove(idx) }
            end
            if @pipe.closed?
                raise RuntimeError.new("connection closed: #{reply}")
            elsif reply[0] == CMD_REPLY
                result = decode_obj(reply[1])
                if result.is_a?(JavaScriptError)
                    raise result
                else
                    return result
                end
            elsif reply[0] == CMD_EVAL
                begin
                    result = Object::TOPLEVEL_BINDING.eval(reply[1])
                    encoded = encode_obj(result)
                rescue => e
                    encoded = encode_eval_error(e)
                end
                send_command([CMD_REPLY, encoded])
            elsif reply[0] == CMD_CALL
                begin
                    receiver = decode_obj(reply[1])
                    name = reply[2]
                    args = reply[3].map {|e| decode_obj(e)}
                    result = receiver.public_send(name, *args)
                    encoded = encode_obj(result)
                rescue => e
                    encoded = encode_eval_error(e)
                end
                send_command([CMD_REPLY, encoded])
            else
                raise RuntimeError.new("bad reply: #{reply}")
            end
        end
    end

    @pipe = nil
    @module_names = []
    @options = ''
    @pipeToJsClass = PipeToJs

    def self.config(module_names: [], options: '', browser: false)
        @module_names = module_names
        @options = options
        @pipeToJsClass = if browser then PipeToBrowser else PipeToJs end
        nil
    end

    def self.close
        @pipe = nil if @pipe.close  unless @pipe.nil?
    end

    Signal.trap(0) { self.close }  # close before termination

    def self.exec(src)
        __getpipe__.exec(src)
    end

    def self.dyn_import(name, var_name=nil)
        __getpipe__.funcall(nil, 'Ruby.dyn_import', [name, var_name])
    end

    # name is a string object.
    # Evaluating this string in JavaScript results in a JavaScript function.
    #
    def self.funcall(name, *args)
        __getpipe__.funcall(nil, name, args)
    end

    # reclaim unused remote references.
    #
    def self.scavenge_references
        __getpipe__.scavenge
    end

    def self.method_missing(name, *args)
        __getpipe__.funcall(nil, name, args)
    end

    def self.__getpipe__
        if @pipe.nil?
            @pipe = @pipeToJsClass.new(@module_names, @options)
        end
        @pipe
    end
end
