# frozen_string_literal: true

require_relative "./test_jscall.rb"

class TestSynchronousIO < TestJscall
  def setup
    Jscall.config
    Jscall.config(browser: false, sync: true)
  end

  def teardown
    Jscall.close
  end

  def test_pass_ruby_function
    f = -> (x) { x + 1 }
    Jscall.exec(<<CODE
      function get_ruby_function(f) {
        return f(7)
      }
CODE
    )
    assert_equal 8, Jscall.get_ruby_function(f)
  end

  class Foo
    def foo(x)
      x + 3
    end
  end

  def test_call_ruby_method_in_js
    Jscall.exec(<<CODE
      function call_ruby_method(p) {
        return p.foo(10) + 100
      }
CODE
    )
    assert_equal 113, Jscall.call_ruby_method(Foo.new)
  end

  def test_ruby_exec
    Jscall.exec(<<CODE
      function bar(x) {
        return Ruby.exec("TestJscall.foo(4)") + x
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
          fact: (n) => {
            if (n > 1)
              return ruby.fact(n - 1) * n
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

  def test_pass_promise
  end

  def test_call_ruby_method_without_await
  end

  class Large
    def make(n)
      JSON.generate((1 .. n).collect {|i| [i, [i]] }.to_h)
    end
  end

  def test_large_string
    Jscall.exec(<<CODE
      function get42(ruby, n) {
        const json = ruby.make(n)
        const obj = JSON.parse(json)
        return obj[42][0]
      }
CODE
    )
    large = Large.new
    (2..5).collect {|i| 10 ** i }.each do |n|
        assert_equal 42, Jscall.get42(large, n)
    end
  end
end
