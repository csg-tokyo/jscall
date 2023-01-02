# Jscall

[![Ruby](https://github.com/csg-tokyo/jscall/actions/workflows/ruby.yml/badge.svg)](https://github.com/csg-tokyo/jscall/actions/workflows/ruby.yml)

Jscall allows executing a program in JavaScript on node.js or a web browser.
By default, node.js is used for the execution.
To choose a web browser, call `Jscall.config`.

```
Jscall.config(browser: true)
```

To run JavaScript code, call `Jscall.exec`.
For example,

```
Jscall.exec '1 + 1'
```

This returns `2`.  The argument passed to `Jscall.exec` can be
multiple lines.  It is executed as source code written in JavaScript.

`Jscall.exec` returns a resulting value.  Numbers, character strings (and symbols), boolean values, and `nil` (and `null`)
are copied when passing between Ruby and JavaScript.  An array is shallow-copied.
Other objects are not copied.  When they are passed, a remote reference is created at the destination.
When a `Map` object is returned from JavaScript to Ruby, it is also
shallow-copied but into a `Hash` object in Ruby.

A remote reference is a local reference to a proxy object.
A method call on a remote reference invokes a method on the corresponding
object on the remote site.  For example,

```
js_obj = Jscall.exec '({ foo: (x) => x + 1, bar: 7 })'
js_obj.foo(3)    # 4
js_obj.bar       # 7
js_obj.baz = 9
js_obj.baz       # 9
```

The `foo` method is executed in JavaScript.
Since `bar` is not a function, its value is returned to Ruby as it is.

Setting an object property to a given value is also
allowed.  The expression `js_obj.baz = 9` above sets
the object property `baz` to 9.

An argument to a JavaScript method is copied from Ruby to
JavaScript unless it is an object.  When an argument is a Ruby object,
a proxy object is created in JavaScript.  The rule is the same as the
rule for returning a value from JavaScript to Ruby.  A primitive
value is copied but an object is not.  An array is shallow-copied.

A `Hash` object in Ruby is also shallow-copied into JavaScript but a normal
object is created in JavaScript.  Recall that a JavaScript object is
regarded as an associative array, or a hash table as in Ruby.
For example, in Ruby,

```
obj = { a: 2, b: 3 }
```

when this ruby object is passed to JavaScript as an argument,
a normal object `{ a: 2, b: 3 }` is created as its copy in JavaScript
and passed to a JavaScript method.

To call a JavaScript function from Ruby, call a method on `Jscall`.
For example,

```
Jscall.exec <<CODE
  function foo(x) {
    return x + 1
  }
CODE
Jscall.foo(7)    # 8
```

`Jscall.foo(7)` invokes the JavaScript function with the name following `Jscall.`
with the given argument.  In this case,
the `foo` function is executed with the argument `7`.
Arguments and a return value are passed to/from a function
as they are passed to/from a method.

`Jscall` can be used for obtaining a remote reference to access a global variable
in JavaScript.  For example,

```
Jscall.console.log('Hello')
```

This prints `Hello` on a JavaScript console.  `Jscall.console` returns a remote
reference to the value of `console` in JavaScript.  Then, `.log('Hello')`
calls the `log` method on `console` in JavaScript.

When a Ruby object is passed to a JavaScript function/method,
you can call a method on the passed Ruby object.

```
Jscall.exec <<CODE
  async function foo(obj) {
    return await obj.to_a()
  }
CODE
Jscall.foo((1..3))    # [1, 2, 3]
```

Here, `obj.to_a()` calls the `to_a` method on a `Range` object
created in Ruby.
Note that you must `await` every call to Ruby object since it is
asynchronous call.

A shorthand for `obj.to_a()` is `obj.to_a` in Ruby.  However,
this shorthand is not available in JavaScript.
You must explicitly write `obj.to_a()`
in JavaScript when `obj` is a Ruby object.

In JavaScript, `Ruby.exec` is available to run a program in Ruby.
For example,

```
Jscall.exec <<CODE
  async function foo() {
    return await Ruby.exec('RUBY_VERSION')
  }
CODE
Jscall.foo()
```

`Jscall.foo()` returns the result of evaluating given Ruby code
`RUBY_VERSION` in Ruby.
Don't forget to `await` a call to `Ruby.exec`.

### Remote references

A remote reference is implemented by a local reference to a proxy
object representing the remote object that the remote reference refers to.
When a proxy object is passed as an argument or a return value
from Ruby to JavaScript (or vice versa), the corresponding JavaScript
(or Ruby) object is passed to the destination.  In other words,
a remote reference passed is converted back to a local reference.

Remote references will be automatically reclaimed when they are no
longer used.  To reclaim them immediately, call:

```
Jscall.scavenge_references
```

As mentioned above, a remote reference is a local reference
to a proxy object.  In Ruby,
even a proxy object provides a number of methods inherited from `Object` class,
such as `clone`, `to_s`, and `inspect`.  A call to such a method is not
delegated to the corresponding JavaScript object.  To invoke such a method
on a JavaScript object, call `send` on its proxy object.
For example,

```
js_obj = Jscall.exec '({ to_s: (x, y) => x + y })'
puts js_obj.to_s(3, 4)            # error
puts js_obj.send('to_s', 3, 4)    # 7
```

The `send` method invokes the JavaScript method with the name specified
by the first argument.  The remaining arguments passed to `send` are passed
to that JavaScript method.


## DOM manipulation

When JavaScript code is run on a browser, some utility methods
are available in Ruby for manipulating DOM objects.

- `Jscall.dom.append_css(css_file_path)`

This adds a `link` element to the DOM tree so that the specified
css file will be linked.  For example, `append_css('/mystyle.css')`
links `mystyle.css` in the current directory.

- `Jscall.dom.print(msg)`

This adds a `p` element to the DOM tree.
Its inner text is the character string passed as `msg`.

- `Jscall.dom.append_to_body(html_source)`

This inserts the given `html_source` at the end of the `body` element.
It is a shorthand for

```
Jscall.document.body.insertAdjacentHTML('beforeend', html_source)
```

## Variable scope

Since Jscall uses `eval` to execute JavaScript code, the scope of
variable/constant names is within the code passed to `eval`.
For example,

```
Jscall.exec 'const k = 3'
Jscall.exec 'k + 3'         # Can't find variable: k
```

The second line causes an error.  `k` is not visible
when `'k + 3'` is executed.

To avoid this, use a global variable.

```
Jscall.exec 'k = 3'
Jscall.exec 'globalThis.j = 4'
Jscall.exec 'k + j'             # 7
```

## Loading a module

When JavaScript code is executed on node.js, `require` is available in JavaScript
for loading a CommonJS module.  For example,

```
Jscall.exec "mime = require('./mime.js')"
```

The file `./mime.js` is loaded and the module is bound to a global variable `mime` in JavaScript.

You can directly call `require` on `Jscall` in Ruby.

```
parser = Jscall.require("@babel/parser")
ast = parser.parse('const i = 3')
Jscall.console.log(ast)
```

`require` will search `./node_modules/` for `@babel/parser`.
This is equivalent to the following JavaScript code.

```
parser = require("@babel/parser")
ast = parser.parse('const i = 3')
console.log(ast)
```

Dynamic importing is also available.  Call `Jscall.dyn_import` in Ruby.

```
fs = Jscall.dyn_import('fs')
```

This executes dynamic importing in JavaScript.
For node.js, the file name of the imported module should be a full path name.  For a web browser, the root directory is the current working directory.  So `Jscall.dyn_import('/mine.mjs')` loads the file `./mine.mjs`.

`Jscall.dyn_import` takes the second argument.  If it is given,
a global variable in JavaScript is bound to the loaded module.

```
fs = Jscall.dyn_import('fs', 'fs_module')
```

This is quite equivalent to the following JavaScript code:

```
fs_module = await load('fs')
```

## Promise

If a program attempts to pass a `Promise` object from JavaScript to Ruby,
it waits until the promise is fulfilled.  Then Jscall passes
the value of that promise from JavaScript to Ruby instead of that
promise itself (or a remote reference to that promise).  When that promise
is rejected, an error object is passed to Ruby
so that the error will be raised in Ruby.
This design reflects the fact that an `async` function in JavaScript
also returns a `Promise` object but this object must not be returned
to Ruby as is when that `async` function is called from Ruby.
Jscall cannot determine whether a promise should be passed as is to Ruby
or its value must be passed to Ruby after the promise is fulfilled.

When enforcing Jscall to pass a `Promise` object from JavaScript to Ruby,
`.async` must be inserted between a receiver and a method name.

```
Jscall.exec(<<CODE)
  function make_promise() {
    return { a: Promise.resolve(7) }
  }
CODE

obj = Jscall.make_promise
result = obj.a                # 7
prom = obj.async.a            # promise
prom.then(->(r) { puts r })   # 7
```

## Synchronous calls

You might want to avoid writing `await` when you call a method on a Ruby
object or you execute Ruby code by `Ruby.exec` from JavaScript.
For example, that call is included in library code and you might not
be able to modify the library code so that `await` will be inserted.

Jscall supports synchronous calls from JavaScript to Ruby only when
the underlying JavaScript engine is node.js on Linux.
In the mode of synchronous calls, you do not have to `await` a method call
on a Ruby object or a call to `Ruby.exec`.
It blocks until the return value comes back from Ruby.
While it blocks, all calls from Ruby to JavaScript are
synchronously processed.

To change to the mode of synchronous calls,
call `Jscall.config`:

```
Jscall.config(sync: true)
```

## Configuration

Jscall supports several configuration options.
Call `Jscall.config` with necessary options.

### module_names:

To import JavaScript modules when node.js or a web browser starts,

```
Jscall.config(module_names: [["Foo", "./js", "/lib/foo.mjs"], ["Bar", "./js", "/lib/bar.mjs"]])
```

This specifies that `./js/lib/foo.mjs` and `./js/lib/bar.mjs` are imported
at the beginning.
This is equivalent to the following import declarations:

```
import * as "Foo" from "./js/lib/foo.mjs"
import * as "Bar" from "./js/lib/bar.mjs"
```

Note that each array element given to `module_names:` is

```
[<module_name> <root> <path>]
```

`<path>` must start with `/`.  It is used as a part of the URL when a browser
accesses a module.
When importing a module for node.js, `<root>` and `<path>` are concatenated
to form a full path name.

`<path>` must not start with `/jscall` or `/cmd`.  They are reserved for
internal use.

### options:

To specify a command line argument passed to node.js,

```
Jscall.config(options: '--use-strict')
```

This call specifies that
`--use-strict` is passed as a command line argument.

### browser: and port:

When running JavaScript code on a web browser,

```
Jscall.config(browser: true, port: 10082)
```

Passing `true` for `browser:` switches the execution engine to a web browser.
The default engine is node.js.
To switch the engine back to node.js, pass `false` for `browser:`.
Call `Jscall.close` to detach the current execution engine.
A new engine with a new configuration will be created.

`port:` specifies the port number of an http server.  It is optional.
The example above specifies that Ruby receives http requests
sent to http://localhost:10082 from JavaScript on a web browser.


### Misc.

To change to the mode of synchronous calls,

```
Jscall.config(sync: true)
```

To set all the configurations to the default ones,

```
Jscall.config()
```

### Other configurations

To obtain more detailed error messages,
set a debugging level to 10.
In Ruby,

```
Jscall.debug = 10
```

In JavaScript,

```
Ruby.setDebugLevel(10)
```

The default debugging level is 0.

To change the name of the node command,

```
Jscall::PipeToJs.node_command = "node.exe"
```

The default command name is `"node"`.

To change the command for launching a web browser,

```
Jscall::FetchServer.open_command = "open -a '/Applications/Safari.app'"
```

By default, the command name is `open` for macOS, `start` for Windows,
or `xdg-open` for Linux.
Jscall launches a web browser by the command like the following:

```
open http://localhost:10082/jscall/jscall.html
```

Jscall generates a verbose error message if its debug level is more than 0.

```
Jscall.debug = 1
```

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'jscall'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install jscall

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/csg-tokyo/jscall.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

## Acknowledgment

The icon image for jscall was created by partly using the Ruby logo, which was obtained
from https://www.ruby-lang.org/en/about/logo/ under CC BY-SA 2.5.
