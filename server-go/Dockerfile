FROM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /polyapp-api ./cmd/api

FROM alpine:3.22

WORKDIR /srv

RUN addgroup -S app && adduser -S app -G app

COPY --from=builder /polyapp-api /usr/local/bin/polyapp-api

RUN mkdir -p /srv/data/news /srv/data/schedule && chown -R app:app /srv

USER app

EXPOSE 8000

ENV HTTP_PORT=8000
ENV MEDIA_DIR=/srv/data

ENTRYPOINT ["/usr/local/bin/polyapp-api"]
