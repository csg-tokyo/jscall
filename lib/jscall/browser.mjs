// Copyright (C) 2022- Shigeru Chiba.  All rights reserved.

export class HttpStream {
    constructor() {
        this.send_buffer = ['start']
        this.send_callback = null
    }

    [Symbol.asyncIterator]() {
        const http_stream = this
        return {
            next() {
                let msg = http_stream.send_buffer.shift()
                if (msg === undefined)
                    return new Promise((resolve, reject) => {
                        if (http_stream.send_callback === null)
                            http_stream.send_callback = resolve
                        else
                            throw new Error('(fatal) send_callback is not null!')
                    }).then(() => this.next())
                else
                    return http_stream.do_fetch(msg)
            }
        }
    }

    do_fetch(msg) {
        const hs = new Headers()
        hs.append('Content-Type', 'text/plain')
        return fetch('/cmd/', { method: 'POST', headers: hs, body: msg })
                .then(async (response) => {
                        if (response.ok) {
                            const text = await response.text()
                            return { value: text, done: text === 'done' }
                        }
                        else
                            throw new Error(`HTTP error! Status: ${response.status}`)
                    },
                    (reason) => { return { value: 'failure', done: true } })
    }

    puts(msg) {
        this.send_buffer.push(msg)
        if (this.send_callback !== null) {
            const callback = this.send_callback
            this.send_callback = null
            callback()
        }
    }

    setEncoding(encoding) {}
}

export const Jscall = new class {
    print(msg) {
        const e = document.createElement('p')
        e.textContent = msg
        document.body.append(e)
    }

    append_css(file_name) {
        const link = document.createElement('link')
        link.rel = "stylesheet"
        link.href = file_name
        document.head.append(link)
    }
}
