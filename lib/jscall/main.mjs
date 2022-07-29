// Copyright (C) 2022- Shigeru Chiba.  All rights reserved.

const cmd_eval = 1
const cmd_call = 2
const cmd_reply = 3
const cmd_async_call = 4
const cmd_async_eval = 5

const param_array = 0
const param_object = 1
const param_local_object = 2
const param_error = 3
const param_hash = 4

const table_size = 100

const exported = new class {
    constructor() {
        this.objects = Array(table_size).fill().map((_, i) => i + 1)
        this.objects[table_size - 1] = -1
        this.free_element = 0
        this.hashtable = new Map()
    }

    export(obj) {
        const idx = this.hashtable.get(obj)
        if (idx !== undefined)
            return idx
        else {
            const idx = this.next_element()
            this.objects[idx] = obj
            this.hashtable.set(obj, idx)
            return idx
        }
    }

    export_remoteref(prref) {   // proxy for remote reference
        return prref.__self__.id
    }

    next_element() {
        const idx = this.free_element
        if (idx < 0)
            return this.objects.length
        else {
            this.free_element = this.objects[idx]
            return idx
        }
    }

    find(idx) {
        const obj = this.objects[idx]
        if (typeof obj === 'number')
            throw `unknown index is given to find(): ${idx}`
        else
            return obj
    }

    remove(idx) {
        const obj = this.objects[idx]
        if (typeof obj === 'number')
            throw `unknown index is given to remove(): ${idx}`
        else {
            this.objects[idx] = this.free_element
            this.free_element = idx
            this.hashtable.delete(obj)
        }
    }
}

class RemoteRef extends Function {
    constructor(id) {
        super()
        this.id = id
    }
}

const remoteRefHandler = new class {
    get(obj, name) {
        if (name === '__self__')
            return obj
        else if (name === 'then')
            // to prevent the Promise from handling RemoteRefs as thenable
            // e.g., `Jscall.exec("{ call: (x) => Promise.resolve(x) }").call(obj)' should return that obj itself
            return undefined
        else
            return (...args) => {
                // this returns Promise
                return funcall_to_ruby(obj.id, name, args)
            }
    }
    apply(obj, self, args) {
        // this returns Promise
        return funcall_to_ruby(obj.id, 'call', args)
    }
}

const imported = new class {
    constructor() {
        this.objects = Array(table_size).fill(null)
        this.canary = new WeakRef(new RemoteRef(-1))
    }

    import(index) {
        const wref = this.objects[index]
        const obj = wref === null || wref === undefined ? null : wref.deref()
        if (obj !== null && obj !== undefined)
            return obj
        else {
            const ref = new RemoteRef(index)
            const rref = new Proxy(ref, remoteRefHandler)
            this.objects[index] = new WeakRef(rref)
            return rref
        }
    }

    kill_canary() { this.canary = null }

    // collect reclaimed RemoteRef objects.
    dead_references() {
        // In Safari, deref() may return null
        if (this.canary === null || this.canary.deref() == undefined)
            this.canary = new WeakRef(new RemoteRef(-1))
        else
            return []   // the canary is alive, so no GC has happened yet.

        const deads = []
        this.objects.forEach((wref, index) => {
            if (wref !== null && wref !== undefined && wref.deref() == undefined) {
                this.objects[index] = null
                deads.push(index)
            }
        })
        return deads
    }
}

const encode_obj = obj => {
    if (typeof obj === 'number' || typeof obj === 'string' || obj === true || obj === false || obj === null)
        return obj
    else if (obj === undefined)
        return null
    else if (obj.constructor === Array)
        return [param_array, obj.map(e => encode_obj(e))]
    else if (obj instanceof Map) {
        const hash = {}
        for (const [key, value] of obj.entries())
            hash[key] = value
        return [param_hash, hash]
    }
    else if (obj instanceof RemoteRef)
        return [param_local_object, exported.export_remoteref(obj)]
    else
        return [param_object, exported.export(obj)]
}

const encode_error = msg => [param_error, msg.toString()]

class RubyError {
    constructor(msg) { this.message = msg }
    get() { return 'RubyError: ' + this.message }
}

const decode_obj = obj => {
    if (typeof obj === 'number' || typeof obj === 'string' || obj === true || obj === false || obj === null)
        return obj
    else if (obj.constructor === Array && obj.length == 2)
        if (obj[0] == param_array)
            return obj[1].map(e => decode_obj(e))
        else if (obj[0] == param_hash) {
            const hash = {}
            for (const [key, value] of Object.entries(obj[1]))
                hash[key] = decode_obj(value)
            return hash
        }
        else if (obj[0] == param_object)
            return imported.import(obj[1])
        else if (obj[0] == param_local_object)
            return exported.find(obj[1])
        else if (obj[0] == param_error)
            return new RubyError(obj[1])

    throw `decode_obj: unsupported value, ${obj}`
}

const js_eval = eval

const funcall_from_ruby = cmd => {
    const receiver = decode_obj(cmd[2])
    const name = cmd[3]
    const args = cmd[4].map(e => decode_obj(e))
    if (name.endsWith('=')) {
        const name2 = name.substring(0, name.length - 1)
        if (receiver === null)
            throw `assignment to a global object ${name2} is not supported`
        else if (args.length === 1) {
            if (Reflect.set(receiver, name2, args[0]))
                return args[0]
        }
        throw `faild to set an object property ${name2}`
    }

    if (receiver === null) {
        const f = js_eval(name)
        if (typeof f === 'function')
            return f.apply(this, args)
        else if (args.length === 0)
            return f    // obtain a property
    }
    else {
        const f = Reflect.get(receiver, name)
        if (f)
            if (typeof f === 'function')
                return Reflect.apply(f, receiver, args)
            else if (args.length === 0)
                return f    // obtain a propety
    }

    throw `unknown JS function/method was called: ${name} on <${receiver}>`
}

let stdout_puts = console.log
let num_generated_ids = 0

const fresh_id = () => {
    num_generated_ids += 1
    return num_generated_ids
}

const reply = (message_id, value, sync_mode) => {
    if (sync_mode && value instanceof Promise)
        value.then(result => { reply(message_id, result, true) })
             .catch(err => reply_error(message_id, err))
    else {
        try {
            const cmd = reply_with_piggyback([cmd_reply, message_id, encode_obj(value)])
            const data = JSON.stringify(cmd)
            stdout_puts(data)
        } catch (e) {
            reply_error(message_id, e)
        }
    }
}

const reply_error = (message_id, e) => {
    const cmd = reply_with_piggyback([cmd_reply, message_id, encode_error(e)])
    stdout_puts(JSON.stringify(cmd))
}

export const scavenge_references = () => {
    reply_counter = 200
    imported.kill_canary()
    return true
}

const reply_with_piggyback = cmd => {
    const threashold = 100
    if (++reply_counter > threashold) {
        reply_counter = 0
        const dead_refs = imported.dead_references()
        if (dead_refs.length > 0) {
            const cmd2 = cmd.concat()
            cmd2[5] = dead_refs
            return cmd2
        }
    }

    return cmd
}

const callback_stack = []
let reply_counter = 0

export const exec = src => {
    return new Promise((resolve, reject) => {
        const message_id = fresh_id()
        const cmd = reply_with_piggyback([cmd_eval, message_id, src])
        callback_stack.push([message_id, resolve, reject])
        stdout_puts(JSON.stringify(cmd))
    })
}

const funcall_to_ruby = (receiver_id, name, args) => {
    return new Promise((resolve, reject) => {
        const message_id = fresh_id()
        const receiver = [param_local_object, receiver_id]
        const encoded_args = args.map(e => encode_obj(e))
        const cmd = reply_with_piggyback([cmd_call, message_id, receiver, name, encoded_args])
        callback_stack.push([message_id, resolve, reject])
        stdout_puts(JSON.stringify(cmd))
    })
}

const returned_from_callback = cmd => {
    const message_id = cmd[1]
    const result = decode_obj(cmd[2])
    for (let i = callback_stack.length - 1; i >= 0; i--) {
        // investigate the most recent element first since callbacks are assumed to be synchronous
        if (callback_stack[i][0] === message_id) {
            const [[_, resolve, reject]] = callback_stack.splice(i, 1)
            if (result instanceof RubyError)
                reject(result.get())
            else
                resolve(result)
        }
    }
}

export class MessageReader {
    static HeaderSize = 6

    constructor(stream) {
        this.stream = stream
        this.state = "header"
        this.acc = ""
        this.bodySize = 0
    }

    parseHeader(pos) {
        // skip leading whitespace characters as a countermeasure against leftover "\n"
        while (pos < this.acc.length && /\s/.test(this.acc[pos])) {
            pos++
        }
        if (this.acc.length >= MessageReader.HeaderSize) {
            const start = pos
            pos += MessageReader.HeaderSize
            return [parseInt(this.acc.slice(start, pos), 16), pos]
        } else {
            return undefined
        }
    }

    parseBody(pos) {
        if (this.acc.length >= this.bodySize) {
            const start = pos
            pos += this.bodySize
            return [this.acc.slice(start, pos), pos]
        } else {
            return undefined
        }
    }

    consume(pos) {
        if (pos > 0) {
            this.acc = this.acc.slice(pos)
        }
    }

    async *[Symbol.asyncIterator]() {
        for await (const data of this.stream) {
            this.acc += data
            let pos = 0
            while (true) {
                if (this.state === "header") {
                    const header = this.parseHeader(pos)
                    if (header === undefined) {
                        this.consume(pos)
                        break
                    } else {
                        this.bodySize = header[0]
                        pos = header[1]
                        this.state = "body"
                    }
                }
                if (this.state === "body") {
                    const body = this.parseBody(pos)
                    if (body === undefined) {
                        this.consume(pos)
                        break
                    } else {
                        yield body[0]
                        pos = body[1]
                        this.state = "header"
                    }
                }
                if (pos == this.acc.length || (pos == this.acc.length - 1 && this.acc[this.acc.length - 1] === "\n")) {
                    this.acc = ""
                    break
                }
            }
        }
        if (this.acc.length > 0) {
            throw new Error("Pipe closed while message is incomplete")
        }
    }
}

export const start = async (stdin, use_stdout) => {
    if (use_stdout)
        console.log = console.error         // on node.js
    else
        stdout_puts = (m) => stdin.puts(m)  // on browser

    stdin.setEncoding('utf8')
    for await (const json_data of new MessageReader(stdin)) {
        let cmd
        try {
            cmd = JSON.parse(json_data)

            // scavenge remote references
            if (cmd.length > 5)
                cmd[5].forEach(i => exported.remove(i))

            if (cmd[0] == cmd_eval) {
                const result = js_eval(cmd[2])
                reply(cmd[1], result, true)
            }
            else if (cmd[0] == cmd_call) {
                const result = funcall_from_ruby(cmd)
                reply(cmd[1], result, true)
            }
            else if (cmd[0] == cmd_reply)
                returned_from_callback(cmd)
            else if (cmd[0] == cmd_async_call) {
                const result = funcall_from_ruby(cmd)
                reply(cmd[1], result, false)
            }
            else if (cmd[0] == cmd_async_eval) {
                const result = js_eval(cmd[2])
                reply(cmd[1], result, false)
            }
            else {
                reply_error(cmd[1], 'invalid command')
            }
        } catch (error) {
            const msg = typeof error === 'string' ? error : error.toString() +
                                                            '\n  ---\n' + error.stack
            reply_error(cmd[1], msg)
        }
    }
}

// for testing and debugging
export const get_exported_imported = () => {
    return [exported, imported]
}

export const dyn_import = async (file_name, var_name) => {
    const m = await import(file_name)     // dynamic import
    if (var_name)
        eval(`(v)=>{globalThis.${var_name} = v}`)(m)

    return m
}
