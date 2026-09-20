FROM alpine:3.20

RUN apk add --no-cache ca-certificates

RUN mkdir -p /app

COPY zig-out/bin/comments-api /app/comments-api

EXPOSE 3000

CMD ["/app/comments-api"]
