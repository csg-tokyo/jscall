# Jscall

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
multipe lines.  It is executed as source code written in JavaScript.

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

To call a JavaScript function from Ruby, call a mehtod on `Jscall`.
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

When a Ruby object is passed to a JavaScript function/method,
you can call a method on the passed Ruby object.

```
Jscall.exec <<CODE
  async function foo(obj) {
    return await obj.to_a()
  }
CODE
Jscall.foo((1..3))    # [], 2, 3]
```

Here, `obj.to_a()` calls the `to_a` method on a `Range` object
created in Ruby.
Note that you must `await` every call to Ruby object since it is
asynchronous call.

In JavaScript, `Ruby.exec` is availale to run a program in Ruby.
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

The file `./mime.js` is loaded and the module is bound to a global variable `mime`.

You may want to call `Jscall.dyn_import` in Ruby.

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


## Configuration

To import JavaScript modules when node.js starts,

```
Jscall.config(module_names: [["Foo", "./foo.mjs"], ["Bar", "./bar.mjs"]], options: "--use-strict")
```

This specifies that `./foo.mjs` and `./bar.mjs` are impoted when node.js starts.
This is equivalent to the following import declarations:

```
import * as "Foo" from "./foo.mjs"
import * as "Bar" from "./bar.mjs"
```

The above call to `Jscall.config` also specifies that
`'--use-strict'` is passed to node.js as a command line argument.

`module_names:` and `options:` are optional arguments to `Jscall.config`.

To change the name of the node command,

```
Jscall::PipeToJs.node_command = "node.exe"
```

The default command name is `"node"`.

When running JavaScript code on a web browser,

```
Jscall.config(browser: true, options: {port: 10082})
```

`options:` is an optional argument.
The example above specifies that Ruby receives http requests
sent to http://localhost:10082 from JavaScript on a web browser.

Passing `false` for `browser:` to `Jscall.config` switches
the execution engine to node.js.
Call `Jscall.close` to detach the current execution engine.
A new enigine with a new configuration will be created.

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

## Acknowledgement

The icon image for jscall was created by partly using the Ruby logo, which was obtained
from https://www.ruby-lang.org/en/about/logo/ under CC BY-SA 2.5.
