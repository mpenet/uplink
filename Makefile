FENNEL    ?= fennel
OPENRESTY ?= openresty
LUA       ?= lua

SRC      := $(filter-out fnl/generate.fnl,$(wildcard fnl/*.fnl))
OUT      := $(patsubst fnl/%.fnl,lib/%.lua,$(SRC))
TEST_SRC := $(wildcard test/*.fnl)
TEST_OUT := $(patsubst test/%.fnl,test/%.lua,$(TEST_SRC))

.PHONY: all clean run reload stop check test generate

all: $(OUT) generate.lua

# Compile all Fennel modules to lib/
lib/%.lua: fnl/%.fnl
	@mkdir -p lib
	$(FENNEL) --compile $< > $@

# Compile standalone generator
generate.lua: fnl/generate.fnl
	$(FENNEL) --compile $< > $@

# Generate nginx include files from config.json
generate: generate.lua
	$(LUA) generate.lua

test/%.lua: test/%.fnl
	$(FENNEL) --compile $< > $@

check:
	@for f in fnl/*.fnl; do \
	    echo "checking $$f"; \
	    $(FENNEL) --compile $$f > /dev/null && echo "  ok" || echo "  FAIL"; \
	done

# Generate nginx conf then start OpenResty.
run: all generate
	$(OPENRESTY) -p $(PWD) -c nginx/nginx.conf

reload:
	$(OPENRESTY) -p $(PWD) -c nginx/nginx.conf -s reload

stop:
	$(OPENRESTY) -p $(PWD) -c nginx/nginx.conf -s stop

test: all $(TEST_OUT)
	busted test/

clean:
	rm -f lib/*.lua generate.lua
	rm -f nginx/upstreams.conf nginx/locations.conf nginx/listen.conf
	rm -f logs/*.log logs/*.pid
