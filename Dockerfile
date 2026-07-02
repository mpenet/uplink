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

# lyaml .so and its libyaml runtime dependency — both from builder.
# openresty:alpine doesn't carry libyaml in its repos; copying the .so avoids
# needing to install anything.
COPY --from=builder /usr/lib/libyaml*.so* /usr/lib/
COPY --from=builder /usr/local/openresty/luajit/share/lua/ /usr/local/openresty/luajit/share/lua/
COPY --from=builder /usr/local/openresty/luajit/lib/lua/ /usr/local/openresty/luajit/lib/lua/
COPY --from=builder /build/lib/ /uplink/lib/
COPY --from=builder /build/generate.lua /uplink/generate.lua

WORKDIR /uplink
COPY nginx/nginx.conf    nginx/nginx.conf
COPY nginx/entrypoint.sh nginx/entrypoint.sh
RUN chmod +x nginx/entrypoint.sh && mkdir -p logs nginx

EXPOSE 8080

# Entrypoint generates nginx/upstreams.conf + nginx/locations.conf from
# config.json, validates, then starts nginx.
# Mount config at runtime: docker run -v ./config.json:/uplink/config.json uplink
ENTRYPOINT ["nginx/entrypoint.sh"]
