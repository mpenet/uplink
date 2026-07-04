FROM openresty/openresty:alpine-fat AS builder

# Build libyaml from source — not available in openresty:alpine-fat repos.
# alpine-fat includes build-base (gcc, make) already.
RUN apk add --no-cache wget && \
    wget -q https://pyyaml.org/download/libyaml/yaml-0.2.5.tar.gz && \
    tar xzf yaml-0.2.5.tar.gz && \
    cd yaml-0.2.5 && ./configure --prefix=/usr && make && make install && \
    cd .. && rm -rf yaml-0.2.5 yaml-0.2.5.tar.gz

RUN luarocks install fennel && luarocks install lyaml && luarocks install dkjson && luarocks install lua-resty-http && luarocks install lua-resty-jwt
ENV PATH="/usr/local/openresty/luajit/bin:${PATH}"

WORKDIR /build
COPY fnl/ fnl/

# Compile Fennel modules → lib/ (generate.fnl is a standalone script, not a module)
RUN mkdir -p lib && \
    for f in fnl/*.fnl; do \
        [ "$(basename "$f")" = "generate.fnl" ] && continue; \
        fennel --compile "$f" > "lib/$(basename "${f%.fnl}").lua"; \
    done

# Compile standalone generator → generate.lua
RUN fennel --compile fnl/generate.fnl > generate.lua

FROM openresty/openresty:alpine

# Copy libyaml runtime .so and lyaml Lua rock from builder.
# Neither is available in openresty:alpine repos so we bundle them directly.
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

ENTRYPOINT ["nginx/entrypoint.sh"]
