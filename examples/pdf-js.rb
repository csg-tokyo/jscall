# Display a pdf file by using pdf.js

require 'jscall'

# Run a JavaScript program on a browser
Jscall.config browser: true

# Write HTML code on a blank web page.
Jscall.dom.append_to_body(<<CODE)
  <h1>PDF.js 'Hello, world!' example</h1>
  <canvas id="the-canvas"></canvas>
CODE

# import pdf.js
pdfjs = Jscall.dyn_import('https://mozilla.github.io/pdf.js/build/pdf.js')

# A pdf file
url = "https://raw.githubusercontent.com/mozilla/pdf.js/ba2edeae/examples/learning/helloworld.pdf"

pdf = Jscall.exec 'window["pdfjs-dist/build/pdf"]'

pdf.GlobalWorkerOptions.workerSrc = "https://mozilla.github.io/pdf.js/build/pdf.worker.js"

loadingTask = pdf.getDocument(url)
loadingTask.async.promise.then(-> (pdf) {
    puts "PDF loaded"

    # Fetch the first page
    pageNumber = 1;
    pdf.async.getPage(pageNumber).then(-> (page) {
        puts "Page loaded"

        scale = 1.5;
        viewport = page.getViewport({ scale: scale })

        canvas = Jscall.document.getElementById("the-canvas")
        context = canvas.getContext("2d")
        canvas.height = viewport.height
        canvas.width = viewport.width
    
        # Render the pdf page
        renderContext = {
            canvasContext: context,
            viewport: viewport,
        }
        renderTask = page.render(renderContext)
        renderTask.async.promise.then(-> (r) {
            # Print a message when the rendering succeeds.
            puts "Page rendered #{r}"
        })
    })
},
-> (reason) {
    # an error occurs.
    puts reason  
})
