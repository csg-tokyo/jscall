
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
        (2..6).collect{ |i| 10 ** i }.each do |n|
            large_json = JSON.dump((1 .. n).collect{ |i| [i, [i]] }.to_h)
            assert_equal 42, Jscall.get42(large_json)
        end
    end
end
