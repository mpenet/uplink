FENNEL  ?= fennel
OPENRESTY ?= openresty

SRC := $(wildcard fennel/*.fnl)
OUT := $(patsubst fennel/%.fnl,lib/%.lua,$(SRC))

.PHONY: all clean run reload check

all: $(OUT)

lib/%.lua: fennel/%.fnl
	@mkdir -p lib
	$(FENNEL) --compile $< > $@

# Check Fennel syntax without compiling.
check:
	@for f in fennel/*.fnl; do \
	    echo "checking $$f"; \
	    $(FENNEL) --compile $$f > /dev/null && echo "  ok" || echo "  FAIL"; \
	done

run: all
	$(OPENRESTY) -p $(PWD) -c conf/nginx.conf

reload:
	$(OPENRESTY) -p $(PWD) -c conf/nginx.conf -s reload

stop:
	$(OPENRESTY) -p $(PWD) -c conf/nginx.conf -s stop

clean:
	rm -f lib/*.lua
	rm -f logs/*.log logs/*.pid
