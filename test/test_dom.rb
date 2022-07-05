# frozen_string_literal: true

require_relative "./test_jscall.rb"

# Jscall::FetchServer.open_command = "open -a '/Applications/Google Chrome.app'"

class TestDom < Minitest::Test
    def setup
        Jscall.config browser: true
    end

    def test_print
        Jscall.dom.append_css('/test/test_dom.css')
        Jscall.dom.print('Hello World!')
    end
end
