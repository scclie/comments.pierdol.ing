FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' ca-certificates)" ge '20250419~deb12u2' \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY zig-out/bin/comments-api /app/
EXPOSE 3000
USER 20902:20902
CMD ["/app/comments-api"]
