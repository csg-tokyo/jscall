# frozen_string_literal: true

require_relative "./test_jscall.rb"

# Jscall::FetchServer.open_command = "open -a '/Applications/Google Chrome.app'"

class TestBrowser < TestJscall
    def setup
        Jscall.config browser: true
    end

    def test_dyn_load
        mod = Jscall.dyn_import('/test/ecma.mjs', 'mod')
        assert_equal 4, mod.foo(3)
        assert_equal 7, Jscall.exec('mod.foo(6)')
    end

    def test_require
        # skip
    end

    def test_garbage_collect_remote_references
        # skip
    end
end
