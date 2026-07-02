FROM openresty/openresty:alpine-fat AS builder

RUN apk add --no-cache libyaml-dev
RUN luarocks install fennel && luarocks install lyaml
ENV PATH="/usr/local/openresty/luajit/bin:${PATH}"

WORKDIR /build
COPY fennel/ fennel/

# Compile Fennel modules → lib/ (generate.fnl is a standalone script, not a module)
RUN mkdir -p lib && \
    for f in fennel/*.fnl; do \
        [ "$(basename "$f")" = "generate.fnl" ] && continue; \
        fennel --compile "$f" > "lib/$(basename "${f%.fnl}").lua"; \
    done

# Compile standalone generator → generate.lua
RUN fennel --compile fennel/generate.fnl > generate.lua

FROM openresty/openresty:alpine

RUN apk add --no-cache libyaml

# lyaml .so from builder
COPY --from=builder /usr/local/openresty/luajit/share/lua/ /usr/local/openresty/luajit/share/lua/
COPY --from=builder /usr/local/openresty/luajit/lib/lua/ /usr/local/openresty/luajit/lib/lua/
COPY --from=builder /build/lib/ /ladon/lib/
COPY --from=builder /build/generate.lua /ladon/generate.lua

WORKDIR /ladon
COPY nginx/nginx.conf    nginx/nginx.conf
COPY nginx/entrypoint.sh nginx/entrypoint.sh
RUN chmod +x nginx/entrypoint.sh && mkdir -p logs nginx

EXPOSE 8080

# Entrypoint generates nginx/upstreams.conf + nginx/locations.conf from
# config.json, validates, then starts nginx.
# Mount config at runtime: docker run -v ./config.json:/ladon/config.json ladon
ENTRYPOINT ["nginx/entrypoint.sh"]
