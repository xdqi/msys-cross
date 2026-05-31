# msys-mirror — thin pacman-repo front-end over GitHub Releases.
# Static binary, distroless runtime, listens on :80.
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
# Static, stripped build (no cgo) so it runs on distroless/static.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /msys-mirror .

# Plain (root) distroless so the binary can bind :80 without NET_BIND_SERVICE.
# The image still ships only the binary + CA bundle — no shell, no package manager.
FROM gcr.io/distroless/static-debian12
COPY --from=build /msys-mirror /msys-mirror
# Writable cache dir for the GitHub API JSON (override with CACHE_DIR / a volume).
ENV CACHE_DIR=/tmp/msys-mirror-cache
EXPOSE 80
ENTRYPOINT ["/msys-mirror"]
