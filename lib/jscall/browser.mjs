// Copyright (C) 2022- Shigeru Chiba.  All rights reserved.

export class HttpStream {
    constructor() {
        this.send_buffer = []
        this.send_callback = null
        this.puts('start')
    }

    [Symbol.asyncIterator]() {
        const http_stream = this
        return {
            next() {
                let next_data = http_stream.send_buffer.shift()
                if (next_data === undefined)
                    return new Promise((resolve, reject) => {
                        if (http_stream.send_callback === null)
                            http_stream.send_callback = resolve
                        else
                            throw new Error('(fatal) send_callback is not null!')
                    })
                else
                    return next_data
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
        return this.do_fetch(msg)
                .then((data) => {
                    if (this.send_callback !== null) {
                        const callback = this.send_callback
                        this.send_callback = null
                        callback(data)
                    } else {
                        this.send_buffer.push(data)
                    }
                })
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

    append_to_body(html_source) {
        document.body.insertAdjacentHTML('beforeend', html_source)
    }
}
