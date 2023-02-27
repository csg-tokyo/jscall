# Show a text input field on a web page and read the text in that field
# by Ruby when an OK button is clicked.

require 'jscall'

# Run a JavaScript program on a browser
Jscall.config browser: true

# If you want to explicitly invoke Chrome on macOS, uncomment the next line.
# Jscall::FetchServer.open_command = "open -a '/Applications/Google Chrome.app'"

Jscall.exec <<~JS
// the following is a JavaScript program run on a browser.
class EventLoop {
    // start() awaits until resume() is called.
    // It returns the argument passed to resume().
    start() {
        return new Promise((res) => {
            this.resolve = res
        })
    }

    resume(v) {
        this.resolve(v)
    }
}

const eventLoop = new EventLoop()

function waitForClick() {
    return eventLoop.start()
}

function clicked() {
    const ok = document.getElementById('ok')
    ok.disabled = true
    const textbox = document.getElementById('value')
    eventLoop.resume(textbox.value)
}
JS

Jscall.dom.append_css "/#{File.dirname(__FILE__)}/dom.css"
Jscall.dom.print 'Please input'
Jscall.dom.append_to_body <<HTML
    <input type="text" id="value" size="20">
    <button id="ok" onclick="clicked()">OK</button>
HTML

# This call blocks until the OK button is clicked.
# Then, it prints the contents of the text field.
puts Jscall.waitForClick()
