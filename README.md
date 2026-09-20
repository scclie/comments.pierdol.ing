# comments.pierdol.ing

anon comment system api with tg moderation
built with zig + httpz + pogsql

i use it on [sccl.cc/guestbook/](https://sccl.cc/guestbook) and [bred.sccl.cc/](https://bred.sccl.cc/)

## api

- `GET /health` # status
- `GET /api/threads/:id/comments?since=<timestamp>` # fetch approved comments
- `POST /api/threads/:id/comments` # submit comment (pending moderation)
- `POST /api/comments/:id/approve` # approve comment (requires X-Bot-Token)
- `POST /api/comments/:id/delete` # delete comment (requires X-Bot-Token)

## stack

- zig 0.16.0 + httpz for HTTP
- pgsql storage
- telegram bot for moderation notifications
- comments rendered as markdown
- rate limiting: 60 req/min (get), 5 req/min (post)
