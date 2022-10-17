// Copyright (C) 2022- Shigeru Chiba.  All rights reserved.
// This works only with node.js on Linux

import * as main from './main.mjs'
import { readSync, openSync } from 'fs'

class SynchronousStdin {
    constructor() {
        this.buf_size = 4096
        this.buffer = Buffer.alloc(this.buf_size);
        this.stdin = openSync('/dev/stdin', 'rs') 
    }

    *[Symbol.iterator]() {
        let str
        while ((str = this.readOne()) !== null)
            yield str
    }

    readOne() {
        while (true) {
            try {
                const nbytes = readSync(this.stdin, this.buffer, 0, this.buf_size)
                if (nbytes > 0)
                    return this.buffer.toString('utf-8', 0, nbytes)
                else
                    return null     // maybe EOF on macOS
            }
            catch (e) {
                if (e.code === 'EOF')
                    return null
                else if (e.code !== 'EAGAIN')
                    throw e
            }
        }
    }
}

class SyncMessageReader extends main.MessageReader {
    constructor(stream) {
        super(stream)
        this.stdin = new SynchronousStdin()
        this.generator = null
    }

    gets_function() {
        const iterator = this[Symbol.iterator]()
        return () => {
            const v = iterator.next()
            if (v.done)
                return null
            else
                return v.value
        }
    }

    async *[Symbol.asyncIterator]() {
        if (this.generator !== null) {
            while (true) {
                const v = this.generator.next()
                if (v.done)
                    break
                else
                    yield v.value
            }
        }
        for await (const data of this.stream) {
            this.acc += data
            this.generator = this.generatorBody()
            while (true) {
                const v = this.generator.next()
                if (v.done)
                    break
                else
                    yield v.value
            }
        }
        this.checkEOS()
    }

    *[Symbol.iterator]() {
        if (this.generator !== null) {
            while (true) {
                const v = this.generator.next()
                if (v.done)
                    break
                else
                    yield v.value
            }
        }
        for (const data of this.stdin) {
            this.acc += data
            this.generator = this.generatorBody()
            while (true) {
                const v = this.generator.next()
                if (v.done)
                    break
                else
                    yield v.value
            }
        }
        this.checkEOS()
    }

    *generatorBody() {
        let pos = 0
        while (true) {
            const result = this.iteratorBody(pos)
            if (result[0] === false)
                break
            else if (result[0] !== true)
                yield result[0]     // result[0] is a string

            pos = result[1]
            if (this.checkEmptiness(pos))
                break
        }
    }
}

export const start = main.start

let stdin_gets = null

main.set_make_message_reader((stdin) => {
    const reader = new SyncMessageReader(stdin)
    stdin_gets = reader.gets_function()
    return reader
})

const js_eval = eval
const exported = main.get_exported_imported()[0]

const event_loop = () => {
    let json_data
    while ((json_data = stdin_gets()) !== null) {
        let cmd
        try {
            cmd = JSON.parse(json_data)

            // scavenge remote references
            if (cmd.length > 5)
                cmd[5].forEach(i => exported.remove(i))

            if (cmd[0] == main.cmd_eval || cmd[0] == main.cmd_async_eval) {
                const result = js_eval(cmd[2])
                main.reply(cmd[1], result, false)
            }
            else if (cmd[0] == main.cmd_call || cmd[0] == main.cmd_async_call) {
                const result = main.funcall_from_ruby(cmd)
                main.reply(cmd[1], result, false)
            }
            else if (cmd[0] == main.cmd_reply)
                return main.decode_obj_or_error(cmd[2])
            else { // cmd_retry, cmd_reject, and other unknown commands
                console.error(`*** node.js; bad message received: ${json_data}`)
                break
            }
        } catch (error) {
            const msg = typeof error === 'string' ? error : error.toString() +
                                                            '\n  ---\n' + error.stack
            main.reply_error(cmd[1], msg)
        }
    }
    return undefined
}

export const exec = src => {
    const cmd = main.make_cmd_eval(src)
    main.stdout_puts(JSON.stringify(cmd))
    return event_loop()
}

main.set_funcall_to_ruby((receiver, name, args) => {
    const cmd = main.make_cmd_call(receiver, name, args)
    main.stdout_puts(JSON.stringify(cmd))
    return event_loop()
})

export const scavenge_references = main.scavenge_references

// for testing and debugging
export const get_exported_imported = main.get_exported_imported

export const dyn_import = main.dyn_import
