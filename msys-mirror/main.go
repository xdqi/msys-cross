// msys-mirror — a thin pacman-repo front-end backed by GitHub Releases.
//
// Packages live as GitHub release assets (GitHub stores + CDN-serves them).
// This service only:
//   - serves a directory listing for humans / mirror tools, and
//   - 302-redirects each package/db request to the matching release asset.
//
// pacman never lists directories; it reads msys-cross.db (built by repo-add in
// CI and uploaded as an asset) and then GETs each package by name — both are
// transparently redirected here to GitHub's CDN.
//
// Routes:
//   /repo/                      -> listing of the latest release
//   /repo/<file>                -> 302 to latest release asset <file>
//   /archive/<tag>/             -> listing of release <tag>
//   /archive/<tag>/<file>       -> 302 to release <tag> asset <file>
//   /healthz                    -> 200 ok
//
// "latest" follows GitHub's releases/latest. Tags are date.seq, e.g. 20260531.1.
//
// The pacman db is published as msys-cross.db.tar.gz (asset names can't be
// symlinks), but pacman requests msys-cross.db; this service aliases the
// .db/.files short names to their .tar.gz assets.
//
// GitHub's releases API is queried anonymously (the repo is public) and cached
// to disk as JSON, refreshed at most every CACHE_TTL.
package main

import (
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// ---- Config (env) ----
var (
	owner    = env("GITHUB_OWNER", "xdqi")
	repo     = env("GITHUB_REPO", "msys-cross")
	token    = os.Getenv("GITHUB_TOKEN") // optional; raises API rate limit
	cacheDir = env("CACHE_DIR", "/var/cache/msys-mirror")
	listen   = env("LISTEN", ":80")
	cacheTTL = envDur("CACHE_TTL", 30*time.Minute)
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envDur(k string, def time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

// ---- GitHub release model (subset) ----
type asset struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	URL  string `json:"browser_download_url"`
}

type release struct {
	TagName    string    `json:"tag_name"`
	Assets     []asset   `json:"assets"`
	Prerelease bool      `json:"prerelease"`
	Draft      bool      `json:"draft"`
	Published  time.Time `json:"published_at"`
}

// ---- Disk-backed, TTL'd cache of API responses ----
type cache struct {
	mu sync.Mutex
}

var c = &cache{}

// fetchJSON GETs a GitHub API path, returning the body. It serves from a disk
// cache keyed by the path when the cached copy is younger than cacheTTL, so a
// burst of pacman clients triggers at most one upstream call per TTL window.
func (c *cache) fetchJSON(apiPath string, out interface{}) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	key := strings.NewReplacer("/", "_", "?", "_", "&", "_", "=", "_").Replace(strings.TrimPrefix(apiPath, "/"))
	cf := filepath.Join(cacheDir, key+".json")

	if fi, err := os.Stat(cf); err == nil && time.Since(fi.ModTime()) < cacheTTL {
		if b, err := os.ReadFile(cf); err == nil {
			if json.Unmarshal(b, out) == nil {
				return nil
			}
		}
	}

	body, err := githubGET(apiPath)
	if err != nil {
		// On upstream failure, fall back to any stale cache rather than 5xx.
		if b, rerr := os.ReadFile(cf); rerr == nil && json.Unmarshal(b, out) == nil {
			log.Printf("warn: serving stale cache for %s (upstream err: %v)", apiPath, err)
			return nil
		}
		return err
	}

	if err := json.Unmarshal(body, out); err != nil {
		return err
	}
	_ = os.MkdirAll(cacheDir, 0o755)
	tmp := cf + ".tmp"
	if err := os.WriteFile(tmp, body, 0o644); err == nil {
		_ = os.Rename(tmp, cf) // atomic publish
	}
	return nil
}

func githubGET(apiPath string) ([]byte, error) {
	req, err := http.NewRequest("GET", "https://api.github.com"+apiPath, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "msys-mirror")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("github api %s -> %d: %s", apiPath, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return body, nil
}

// ---- Release lookups ----
func latestRelease() (*release, error) {
	var r release
	if err := c.fetchJSON(fmt.Sprintf("/repos/%s/%s/releases/latest", owner, repo), &r); err != nil {
		return nil, err
	}
	return &r, nil
}

func releaseByTag(tag string) (*release, error) {
	var r release
	if err := c.fetchJSON(fmt.Sprintf("/repos/%s/%s/releases/tags/%s", owner, repo, tag), &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// ---- Asset name resolution ----
//
// Two normalizations let the requested name match the actual asset:
//  1. GitHub rewrites characters like ':' to '.' in uploaded asset names, so an
//     epoch'd package (e.g. "2:1.0-...") is stored as "2.1.0-...". We apply the
//     same rewrite to the requested name before matching.
//  2. pacman fetches the db/files by their short names (msys-cross.db,
//     msys-cross.files), but they are uploaded as .tar.gz; alias the short
//     names to the .tar.gz asset.
func sanitizeAssetName(n string) string {
	return strings.ReplaceAll(n, ":", ".")
}

func resolveAsset(r *release, requested string) (*asset, bool) {
	want := sanitizeAssetName(requested)

	// db/files short-name alias -> .tar.gz
	if alias, ok := dbAlias(want); ok {
		want = alias
	}

	for i := range r.Assets {
		if r.Assets[i].Name == want {
			return &r.Assets[i], true
		}
	}
	return nil, false
}

// dbAlias maps pacman's short db/files names to their uploaded .tar.gz asset.
func dbAlias(name string) (string, bool) {
	switch {
	case strings.HasSuffix(name, ".db") && !strings.HasSuffix(name, ".tar.gz"):
		return name + ".tar.gz", true
	case strings.HasSuffix(name, ".files") && !strings.HasSuffix(name, ".tar.gz"):
		return name + ".tar.gz", true
	}
	return name, false
}

// downloadURL builds the stable public asset URL (which itself 302s to the CDN),
// preferring the API-provided browser_download_url when present.
func downloadURL(r *release, a *asset) string {
	if a.URL != "" {
		return a.URL
	}
	return fmt.Sprintf("https://github.com/%s/%s/releases/download/%s/%s", owner, repo, r.TagName, a.Name)
}

// ---- HTTP handlers ----
func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/repo/", handleRepo)
	mux.HandleFunc("/archive/", handleArchive)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/repo/", http.StatusFound)
			return
		}
		http.NotFound(w, r)
	})

	log.Printf("msys-mirror: %s/%s, cache=%s ttl=%s, listen=%s", owner, repo, cacheDir, cacheTTL, listen)
	srv := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

// /repo/ and /repo/<file> — the rolling "latest" view.
func handleRepo(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/repo/")
	rel, err := latestRelease()
	if err != nil {
		http.Error(w, "upstream error: "+err.Error(), http.StatusBadGateway)
		return
	}
	serveReleasePath(w, r, rel, "/repo", rest)
}

// /archive/<tag>/ and /archive/<tag>/<file> — pinned snapshot per tag.
func handleArchive(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/archive/")
	tag, file, _ := strings.Cut(rest, "/")
	if tag == "" {
		http.Error(w, "missing tag (use /archive/<tag>/)", http.StatusBadRequest)
		return
	}
	rel, err := releaseByTag(tag)
	if err != nil {
		http.Error(w, "no such release "+html.EscapeString(tag), http.StatusNotFound)
		return
	}
	serveReleasePath(w, r, rel, "/archive/"+tag, file)
}

// serveReleasePath either lists the release (empty file) or 302s to an asset.
func serveReleasePath(w http.ResponseWriter, r *http.Request, rel *release, base, file string) {
	if file == "" {
		listRelease(w, rel, base)
		return
	}
	a, ok := resolveAsset(rel, file)
	if !ok {
		http.NotFound(w, r)
		return
	}
	http.Redirect(w, r, downloadURL(rel, a), http.StatusFound)
}

// listRelease renders an Apache/nginx-autoindex-style HTML listing so both
// humans and mirroring tools can enumerate the assets. The db short-name
// aliases are surfaced as extra links so a tool following them still works.
func listRelease(w http.ResponseWriter, rel *release, base string) {
	assets := append([]asset(nil), rel.Assets...)
	sort.Slice(assets, func(i, j int) bool { return assets[i].Name < assets[j].Name })

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, "<!DOCTYPE html>\n<html><head><title>Index of %s/</title></head><body>\n", html.EscapeString(base))
	fmt.Fprintf(w, "<h1>Index of %s/ (release %s)</h1><hr><pre>\n", html.EscapeString(base), html.EscapeString(rel.TagName))
	for _, a := range assets {
		fmt.Fprintf(w, "<a href=\"%s/%s\">%s</a>%s%d\n",
			html.EscapeString(base), html.EscapeString(a.Name),
			html.EscapeString(a.Name),
			pad(a.Name, 60), a.Size)
		// Surface the short db/files alias next to its .tar.gz.
		if short, ok := shortDBName(a.Name); ok {
			fmt.Fprintf(w, "<a href=\"%s/%s\">%s</a>%s(alias of %s)\n",
				html.EscapeString(base), html.EscapeString(short),
				html.EscapeString(short), pad(short, 60), html.EscapeString(a.Name))
		}
	}
	fmt.Fprint(w, "</pre><hr></body></html>\n")
}

// shortDBName returns the pacman short name for a db/files .tar.gz asset.
func shortDBName(name string) (string, bool) {
	switch {
	case strings.HasSuffix(name, ".db.tar.gz"):
		return strings.TrimSuffix(name, ".tar.gz"), true
	case strings.HasSuffix(name, ".files.tar.gz"):
		return strings.TrimSuffix(name, ".tar.gz"), true
	}
	return "", false
}

func pad(s string, width int) string {
	if len(s) >= width {
		return "  "
	}
	return strings.Repeat(" ", width-len(s))
}
