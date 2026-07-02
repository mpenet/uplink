FROM openresty/openresty:alpine-fat AS builder

RUN apk add --no-cache libyaml-dev
RUN luarocks install fennel && \
    luarocks install lyaml && \
    luarocks install lua-resty-openssl
ENV PATH="/usr/local/openresty/luajit/bin:${PATH}"

WORKDIR /build
COPY fennel/ fennel/

RUN mkdir -p lib && \
    for f in fennel/*.fnl; do \
        fennel --compile "$f" > "lib/$(basename "${f%.fnl}").lua"; \
    done

FROM openresty/openresty:alpine

# libyaml runtime library (lyaml .so links against it)
RUN apk add --no-cache libyaml

# Copy compiled Lua modules from builder (lyaml .so + lua-resty-openssl pure Lua)
COPY --from=builder /usr/local/openresty/luajit/share/lua/ /usr/local/openresty/luajit/share/lua/
COPY --from=builder /usr/local/openresty/luajit/lib/lua/ /usr/local/openresty/luajit/lib/lua/
COPY --from=builder /build/lib/ /ladon/lib/

WORKDIR /ladon
COPY conf/nginx.conf conf/nginx.conf
RUN mkdir -p logs

EXPOSE 8080

# Mount config.json at runtime:
#   docker run -v ./config.json:/ladon/config.json ladon
CMD ["openresty", "-p", "/ladon", "-c", "conf/nginx.conf", "-g", "daemon off;"]
