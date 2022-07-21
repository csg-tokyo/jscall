# frozen_string_literal: true

require "benchmark"
require "test_helper"

class TestAsyncJscall < Minitest::Test
  def setup
    Jscall.config
    Jscall.config browser: false
    define_js_functions
  end

  def define_js_functions
    return if @js_functions_are_defined
    @js_functions_are_defined = true

    Jscall.exec <<~JS
        function isPromise(obj) {
            return obj instanceof Promise
        }

        function makePromise(value) {
            return Promise.resolve({then: (resolve) => resolve(value) })
        }

        function join(value) {
            return value
        }
    JS
  end

  def teardown
    Jscall.close
  end

  def test_exec
    p1 = Jscall.async.exec('Promise.resolve(58)')
    assert Jscall.isPromise(p1)
    assert_equal 58, Jscall.join(p1)
  end

  def test_funcall
    Jscall.exec <<~JS
        let resolve = undefined
        let fulfilled = false
        function foo() {
            return new Promise((res) => {
                resolve = res
            }).then((x) => {
                fulfilled = true
                return x + 1
            })
        }
        function bar() {
            return fulfilled
        }
        function baz(x) {
            resolve(x + 1)
        }
    JS
    p = Jscall.async.foo()
    assert Jscall.isPromise(p)
    assert !Jscall.bar()
    q = Jscall.async.baz(51)
    assert_nil q
    r = Jscall.join(p)
    assert_equal 53, r
    assert Jscall.bar()
  end

  def test_promise_then
    p = Jscall.async.makePromise(99)
    assert Jscall.isPromise(p)
    fulfilled = false
    q = p.async.then(proc do |x|
        fulfilled = true
        x + 1
    end)
    assert Jscall.isPromise(q)
    r = Jscall.join(q)
    assert fulfilled
    assert_equal 100, r
  end

  def test_promise_catch
    ## Jscall.async.exec('Promise.reject("test")').catch(proc { |err| nil })  <- this .catch() cannot prevent Node.js from aborting
    Jscall.exec <<~JS
        let reject     = undefined
        let fulfilled2 = false
        function getFulfilled2() {
            return fulfilled2
        }
        function makePromise2() {
            return new Promise((res, rej) => {
                reject = rej
            }).then((x) => {
                fulfilled2 = true
                return x + 1
            })
        }
        function callReject(err) {
            reject(err)
        }
    JS
    p = Jscall.async.makePromise2
    assert Jscall.isPromise(p)
    assert !Jscall.getFulfilled2
    q = p.async.catch(proc do |err|
        [err, 69]
    end)
    assert Jscall.isPromise(q)
    r = Jscall.callReject('test')
    assert_nil r
    s = Jscall.join(q)
    assert !Jscall.getFulfilled2
    assert_equal ['test', 69], s
  end

  def test_resolve_remoteref
    obj = Object.new
    p = Jscall.exec('({ call: (obj) => Promise.resolve(obj) })').async.call(obj)
    assert Jscall.isPromise(p)
    r = Jscall.join(p)
    assert_equal obj, r
  end

  def test_asynchronous_call_from_js_to_ruby
    Jscall.exec <<~JS
      let responses = []
      function asynchronous_callback(callback) {
        for (let i = 6; i > 0; i--) {
          setTimeout(((i) => async () => {
            responses.push([i, await callback(i)])
          })(i), 0)
        }
      }
      function getResponses() {
        return responses
      }
    JS
    Jscall.asynchronous_callback(proc do |i|
      sleep(i * 0.001)
      i ** 3
    end)
    sleep(0.01) until Jscall.getResponses.length == 6
    puts "js->ruby: #{ Jscall.getResponses.inspect }"
    Jscall.getResponses.each do |i, x|
      assert_equal i ** 3, x
    end
  end

  def test_asynchronous_callback_from_ruby_to_js
    Jscall.exec <<~JS
      let responses2 = []
      function asynchronous_callback2(callback) {
        for (let i = 6; i > 0; i--) {
          setTimeout(((i) => async () => {
            responses2.push([i, await callback(i)])
          })(i), 0)
        }
      }
      function getResponses2() {
        return responses2
      }
      async function sleep(t) {
        return new Promise((res) => setTimeout(() => res(undefined), t * 1000))
      }
      async function sleepAndReturnCubic(i) {
        await sleep(i * 0.001)
        return i ** 3
      }
    JS
    Jscall.asynchronous_callback2(proc do |i|
      Jscall.sleepAndReturnCubic(i)
    end)
    sleep(0.01) until Jscall.getResponses2.length == 6
    puts "ruby->js: #{ Jscall.getResponses2.inspect }"
    Jscall.getResponses2.each do |i, x|
      assert_equal i ** 3, x
    end
  end
end
