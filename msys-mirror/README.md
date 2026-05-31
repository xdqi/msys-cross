# msys-mirror

A thin pacman-repo front-end backed by **GitHub Releases**. Packages live as
release assets (GitHub stores and CDN-serves them); this service only generates
directory listings and 302-redirects each package/db request to the matching
asset. Your own server therefore carries near-zero bandwidth and no package
storage.

## How it fits

```
pacman ──HTTPS──> caddy (TLS) ──> msys-mirror ──302──> github.com/.../releases/download/<tag>/<asset>
                                       │                         └─> GitHub CDN (actual bytes)
                                       └─ GET api.github.com (cached to disk, every CACHE_TTL)
```

pacman never lists directories: it fetches `msys-cross.db` (built by `repo-add`
in CI and uploaded as a release asset), reads the package list from it, then GETs
each package by name. Both are transparently redirected to GitHub's CDN.

## Routes

| Path | Behaviour |
|------|-----------|
| `/repo/` | HTML listing of the **latest** release (GitHub `releases/latest`) |
| `/repo/<file>` | 302 to the latest release's asset `<file>` |
| `/archive/<tag>/` | HTML listing of release `<tag>` (e.g. `20260531.1`) |
| `/archive/<tag>/<file>` | 302 to release `<tag>`'s asset `<file>` |
| `/healthz` | `200 ok` |

`<tag>` is `date.seq`, e.g. `20260531.1`, `20260531.2` — each tag is an immutable
snapshot, so `/archive/<tag>/` is a self-contained repo archive.

### Name resolution

- **db/files alias** — pacman requests `msys-cross.db` / `msys-cross.files`, but
  release assets can't be symlinks, so they are uploaded as `*.tar.gz`. The short
  names are aliased to the `.tar.gz` asset.
- **`:` → `.`** — GitHub rewrites `:` (and similar) in uploaded asset names, so an
  epoch'd package name is matched after the same rewrite.

## pacman client config

```ini
[msys-cross]
Server = https://msys.kosaka.moe/repo
SigLevel = Never
```

Pin a snapshot instead:

```ini
Server = https://msys.kosaka.moe/archive/20260531.1
```

## Configuration (env)

| Var | Default | Purpose |
|-----|---------|---------|
| `GITHUB_OWNER` | `xdqi` | releases repo owner |
| `GITHUB_REPO` | `msys-cross` | releases repo name |
| `GITHUB_TOKEN` | _(unset)_ | optional; raises API rate limit (60→5000/h) |
| `CACHE_DIR` | `/tmp/msys-mirror-cache` | on-disk JSON cache of API responses |
| `CACHE_TTL` | `30m` | min interval between upstream API calls |
| `LISTEN` | `:80` | listen address |

The API is queried anonymously (the repo is public). On upstream failure the
last cached JSON is served rather than erroring.

## Run

```sh
docker build -t msys-mirror .
docker run -p 80:80 msys-mirror
# then put caddy in front for TLS, reverse_proxy to it.
```

## Publishing (CI side)

The build workflow uploads every `*.pkg.tar.*` plus `msys-cross.db.tar.gz` /
`msys-cross.files.tar.gz` to a release tagged `YYYYMMDD.N`. The `.db` is generated
by `repo-add` so its metadata (CSIZE/SHA256/depends) is correct — this service
does **not** synthesize the db.
