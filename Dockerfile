FROM alpine:3.20
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY zig-out/bin/comments-api /app/
EXPOSE 3000
CMD ["/app/comments-api"]
