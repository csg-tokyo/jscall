# frozen_string_literal: true

require "benchmark"
require "test_helper"

class TestJscall < Minitest::Test
  def setup
    Jscall.config browser: false
  end

  def teardown
    Jscall.close
  end

  def test_that_it_has_a_version_number
    refute_nil ::Jscall::VERSION
  end

  def test_exec
    assert_equal 2, Jscall.exec('1 + 1')
  end

  def test_funcall
    Jscall.exec('function foo(x) { return x + 1 }')
    assert_equal 4, Jscall.foo(3)
    assert_equal 5, Jscall.funcall("foo", 4)
  end

  def test_inner_funcall
    Jscall.exec <<CODE
      globalThis.A = new class {}
      A.B = new class {
        foo(x) { return x + 1}
      }
      function bar() { return A.B.foo }
CODE
    assert_equal 8, Jscall.funcall("A.B.foo", 7)
    assert_equal 9, Jscall.funcall("bar()", 8)
  end

  def test_pass_ruby_obj_between_ruby_and_js
    Jscall.exec('function identity(x) { return x }')
    obj = Object.new
    assert_equal obj, Jscall.identity(obj)
  end

  def test_pass_js_obj_between_js_and_ruby
    Jscall.exec(<<CODE
      const js_obj = { a: 1 }
      function get_js_obj() { return js_obj }
      function check_js_obj(x) { return x === js_obj }
CODE
    )
    obj = Jscall.get_js_obj()
    assert Jscall.check_js_obj(obj)
  end

  def test_pass_same_js_obj_twice
    Jscall.exec <<CODE
      const js_obj = { a: 1 }
      function get_js_obj() { return js_obj }
CODE
    obj = Jscall.get_js_obj
    obj2 = Jscall.get_js_obj
    assert obj == obj2
  end

  def test_make_and_call_js_method
    obj = Jscall.exec '({ foo: (x) => x + 1 })'    #  must surround an {} expression with ().
    assert_equal 4, obj.foo(3)
  end

  def test_call_js_method
    Jscall.exec(<<CODE
      function get_js_method(p) {
        return { foo: (x) => x + p }
      }
CODE
    )
    obj = Jscall.get_js_method(7)
    assert_equal 17, obj.foo(10)
  end

  def test_get_js_property
    Jscall.exec 'a = { foo: { a: 3, b(x) { return x + 1 }}}'
    assert_equal 3, Jscall.a.foo.a
    assert_equal 7, Jscall.a.foo.b(6)
  end

  def test_set_js_property
    obj = Jscall.exec '({ p: 3 })'
    obj.p = 7
    obj.q = 10
    assert_equal 17, obj.p + obj.q
  end

  class Foo
    def foo(x)
      x + 3
    end
  end

  # pass a Ruby object to JS and then call a method
  # on that Ruby object in JS
  def test_call_ruby_method_in_js
    Jscall.exec(<<CODE
      async function call_ruby_method(p) {
        return await p.foo(10) + 100
      }
CODE
    )
    assert_equal 113, Jscall.call_ruby_method(Foo.new)
  end

  # call a Ruby method in JS without async/await.
  # an exception must be raised.
  def test_call_ruby_method_without_await
    Jscall.exec(<<CODE
      function call_ruby_method(p) {
        return p.foo(10) + 100
      }
CODE
    )
    assert_raises do
      Jscall.call_ruby_method(Foo.new)
    end
    Jscall.close    # needs to close to recover from the errorneous state.
  end

  def self.foo(x)
    x * 10
  end

  def test_ruby_exec
    Jscall.exec(<<CODE
      async function bar(x) {
        return await Ruby.exec("TestJscall.foo(4)") + x
      }
CODE
    )
    assert_equal 47, Jscall.bar(7)
  end

  class Fact
    def set_js(js)
      @js = js
    end
    def fact(n)
      if n > 1 then @js.fact(n - 1) * n else 1 end
    end
  end

  def test_mutual_recursion
    Jscall.exec(<<CODE
      function get_fact_func(ruby) {
        return {
          fact: async (n) => {
            if (n > 1)
              return await ruby.fact(n - 1) * n
            else
              return 1
          }
        }
      }
CODE
    )
    ruby_fact = Fact.new
    js_fact = Jscall.get_fact_func(ruby_fact)
    ruby_fact.set_js(js_fact)
    assert_equal 120, ruby_fact.fact(5)
  end

  class Many
    def initialize
      @value = Array.new(1000){|i| i}
    end
  end

  def get_exported_objects()
    pipe = Jscall.__getpipe__
    exported = pipe.instance_variable_get(:@exported)
    table = exported.instance_variable_get(:@hashtable).__getobj__
    table.count
  end

  def test_garbage_collect_remote_references
    Jscall.exec(<<CODE
      function make_many_objects(ruby) {
        return { a: 3, b: 'foo', c: Array(1000) }
      }
      function num_exported_objects() {
        const ex_im = Ruby.get_exported_imported()
        let sum = 0
        ex_im[1].objects.forEach((wref, index) => {
          if (wref !== null)
            sum += 1
        })
        return sum
      }
CODE
    )
    nrefs = get_exported_objects
    node_refs = Jscall.num_exported_objects
    n = 10000
    n.times do |i|
      assert Jscall.make_many_objects(Many.new).is_a?(Jscall::RemoteRef)
    end
    assert   Jscall.num_exported_objects < node_refs + n
    assert get_exported_objects < nrefs + n
  end

  def test_dyn_load
    mod = Jscall.dyn_import('../../test/ecma.mjs', 'mod')
    assert_equal 4, mod.foo(3)
    assert_equal 7, Jscall.exec('mod.foo(6)')
  end

  def test_require
    assert_equal 7,
      Jscall.exec("const mod = require('./test/cjs.js'); mod(4)")
  end

  class Simple
    attr_accessor :js
    def initialize(jsobj=nil)
        @js = jsobj
    end
  end

  def test_scavange_references
    Jscall.config(options: '--expose-gc')
    Jscall.close
    Jscall.exec <<CODE
      class JSimple {
        constructor(robj) { this.ruby = robj }
        get_rb() { return this.ruby }
      }

      function make_jsobj(robj) {
        return new JSimple(robj)
      }
CODE
    3.times do
      s = Simple.new
      3.times do
        s = Simple.new(Jscall.make_jsobj(s))
      end
      s = nil
      GC.start
      Jscall.exec 'global.gc()'
    end
    Jscall.scavenge_references
    Jscall.config(options: '')
  end

  def test_round_trip_time
    Jscall.exec('function baz(x) { return x + 1 }')
    n = 1000
    t = Benchmark.realtime do
      n.times do |i|
        Jscall.baz(i)
      end
    end
    puts "\nround-trip time for a JS call #{sprintf("%.2f", t * 1000000 / n)} usec."

    k = []
    t = Benchmark.realtime do
      n.times do |i|
        k << i
      end
    end
    puts "time for Array#<< #{sprintf("%.5f", t * 1000000 / n)} usec."
  end
end
