FROM openresty/openresty:alpine-fat AS builder

RUN luarocks install fennel
ENV PATH="/usr/local/openresty/luajit/bin:${PATH}"

WORKDIR /build
COPY fennel/ fennel/

RUN mkdir -p lib && \
    for f in fennel/*.fnl; do \
        fennel --compile "$f" > "lib/$(basename "${f%.fnl}").lua"; \
    done

FROM openresty/openresty:alpine

WORKDIR /ladon

COPY --from=builder /build/lib/ lib/
COPY conf/nginx.conf conf/nginx.conf
RUN mkdir -p logs

EXPOSE 8080

# Mount config.json at runtime:
#   docker run -v ./config.json:/ladon/config.json ladon
CMD ["openresty", "-p", "/ladon", "-c", "conf/nginx.conf", "-g", "daemon off;"]
