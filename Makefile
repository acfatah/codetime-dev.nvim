NVIM_BIN ?= nvim
MINI := deps/mini.nvim

.PHONY: deps test test-file format format-check

deps: $(MINI)

$(MINI):
	git clone --depth 1 https://github.com/nvim-mini/mini.nvim $@

# all tests
test: deps
	$(NVIM_BIN) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"

# one file: make test-file FILE=tests/test_events.lua
test-file: deps
	$(NVIM_BIN) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

format:
	stylua lua/ tests/

format-check:
	stylua --check lua/ tests/
