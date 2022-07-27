
require 'test_helper'
require 'json'

class TestLargeString < Minitest::Test
    def setup
        Jscall.exec <<~CODE
            function get42(json) {
                let obj = JSON.parse(json)
                return obj[42][0]
            }
        CODE
    end

    def teardown
        Jscall.close
    end

    def test_large_string
        (2..5).collect {|i| 10 ** i }.each do |n|
            large_json = JSON.generate((1 .. n).collect {|i| [i, [i]] }.to_h)
            assert_equal 42, Jscall.get42(large_json)
        end
    end

    def test_too_large_string
        (6..6).collect {|i| 10 ** i }.each do |n|
            assert_raises(RuntimeError) do
                large_json = JSON.generate((1 .. n).collect {|i| [i, [i]] }.to_h)
                Jscall.get42(large_json)
            end
        end
    end
end
