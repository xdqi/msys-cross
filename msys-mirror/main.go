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
//   /repo/                      -> listing of the latest LINUX release
//   /repo/<file>                -> 302 to latest linux release asset <file>
//   /repo-darwin/               -> listing of the latest DARWIN release
//   /repo-darwin/<file>         -> 302 to latest darwin release asset <file>
//   /archive/<tag>/             -> listing of release <tag>
//   /archive/<tag>/<file>       -> 302 to release <tag> asset <file>
//   /healthz                    -> 200 ok
//
// There are two independent rolling repos: the linux x86_64 cross-toolchain
// (tags build-YYYYMMDD.N) and the arm64-macOS-host toolchain (tags
// build-darwin-YYYYMMDD.N). Because GitHub's releases/latest would alternate
// between them as each is published, "latest" here is computed by listing
// releases and picking the newest tag matching a prefix: /repo/ takes the newest
// build- tag that is NOT build-darwin-, and /repo-darwin/ takes the newest
// build-darwin- tag.
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
func releaseByTag(tag string) (*release, error) {
	var r release
	if err := c.fetchJSON(fmt.Sprintf("/repos/%s/%s/releases/tags/%s", owner, repo, tag), &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// listReleases returns all releases (newest first), used to render the
// /archive index of available snapshot tags.
func listReleases() ([]release, error) {
	var rs []release
	if err := c.fetchJSON(fmt.Sprintf("/repos/%s/%s/releases?per_page=100", owner, repo), &rs); err != nil {
		return nil, err
	}
	return rs, nil
}

// latestByPrefix returns the newest (by published_at) non-draft, non-prerelease
// release whose tag starts with want and — if exclude is non-empty — does NOT start
// with exclude. This separates the two rolling repos that share one releases list:
// linux  -> latestByPrefix("build-", "build-darwin-")
// darwin -> latestByPrefix("build-darwin-", "")
// GitHub's releases/latest can't do this (it would alternate between the two).
func latestByPrefix(want, exclude string) (*release, error) {
	rs, err := listReleases()
	if err != nil {
		return nil, err
	}
	var best *release
	for i := range rs {
		r := &rs[i]
		if r.Draft || r.Prerelease {
			continue
		}
		if !strings.HasPrefix(r.TagName, want) {
			continue
		}
		if exclude != "" && strings.HasPrefix(r.TagName, exclude) {
			continue
		}
		if best == nil || r.Published.After(best.Published) {
			best = r
		}
	}
	if best == nil {
		return nil, fmt.Errorf("no release matching prefix %q", want)
	}
	return best, nil
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
	mux.HandleFunc("/repo-darwin/", handleRepoDarwin)
	mux.HandleFunc("/archive/", handleArchive)
	mux.HandleFunc("/archive", handleArchive)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			listRoot(w)
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

// /repo/ and /repo/<file> — the rolling latest LINUX release (newest build- tag
// that is not a build-darwin- tag).
func handleRepo(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/repo/")
	rel, err := latestByPrefix("build-", "build-darwin-")
	if err != nil {
		http.Error(w, "upstream error: "+err.Error(), http.StatusBadGateway)
		return
	}
	serveReleasePath(w, r, rel, "/repo", rest)
}

// /repo-darwin/ and /repo-darwin/<file> — the rolling latest DARWIN release
// (arm64 macOS host; newest build-darwin- tag).
func handleRepoDarwin(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/repo-darwin/")
	rel, err := latestByPrefix("build-darwin-", "")
	if err != nil {
		http.Error(w, "upstream error: "+err.Error(), http.StatusBadGateway)
		return
	}
	serveReleasePath(w, r, rel, "/repo-darwin", rest)
}

// /archive            -> list of all snapshot tags
// /archive/<tag>/      -> listing of that release
// /archive/<tag>/<file> -> 302 to that release's asset
func handleArchive(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, "/archive"), "/")
	tag, file, _ := strings.Cut(rest, "/")
	if tag == "" {
		listArchive(w)
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

// repoURL is the GitHub repo this mirror serves, linked from every page header.
func repoURL() string { return fmt.Sprintf("https://github.com/%s/%s", owner, repo) }

// pageHeader writes the common Apache/nginx-autoindex-style preamble plus a
// header link back to the source GitHub repo.
func pageHeader(w http.ResponseWriter, title string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, "<!DOCTYPE html>\n<html><head><title>%s</title></head><body>\n", html.EscapeString(title))
	fmt.Fprintf(w, "<p><a href=\"%s\">%s/%s on GitHub</a></p>\n",
		repoURL(), html.EscapeString(owner), html.EscapeString(repo))
	fmt.Fprintf(w, "<h1>%s</h1><hr><pre>\n", html.EscapeString(title))
}

func pageFooter(w http.ResponseWriter) { fmt.Fprint(w, "</pre><hr></body></html>\n") }

// link writes one autoindex row: an <a> plus right-aligned trailing text.
func link(w http.ResponseWriter, href, name, trailing string) {
	fmt.Fprintf(w, "<a href=\"%s\">%s</a>%s%s\n",
		html.EscapeString(href), html.EscapeString(name), pad(name, 60), trailing)
}

// listRoot renders the top-level index: the rolling repo and the archive,
// plus the GitHub link in the header.
func listRoot(w http.ResponseWriter) {
	pageHeader(w, "Index of /")
	link(w, "/repo/", "repo/", "rolling latest linux release (build-YYYYMMDD.N)")
	link(w, "/repo-darwin/", "repo-darwin/", "rolling latest arm64-macOS-host release (build-darwin-YYYYMMDD.N)")
	link(w, "/archive/", "archive/", "pinned snapshots (any tag)")
	pageFooter(w)
}

// listArchive renders the list of all snapshot tags, newest first.
func listArchive(w http.ResponseWriter) {
	rels, err := listReleases()
	if err != nil {
		http.Error(w, "upstream error: "+err.Error(), http.StatusBadGateway)
		return
	}
	pageHeader(w, "Index of /archive")
	link(w, "/", "../", "")
	for _, rel := range rels {
		link(w, "/archive/"+rel.TagName+"/", rel.TagName+"/", rel.Published.Format("2006-01-02"))
	}
	pageFooter(w)
}

// listRelease renders an Apache/nginx-autoindex-style listing of a release's
// assets so both humans and mirroring tools can enumerate them. The db
// short-name aliases are surfaced as extra links so a tool following them works.
func listRelease(w http.ResponseWriter, rel *release, base string) {
	assets := append([]asset(nil), rel.Assets...)
	sort.Slice(assets, func(i, j int) bool { return assets[i].Name < assets[j].Name })

	pageHeader(w, fmt.Sprintf("Index of %s/ (release %s)", base, rel.TagName))
	for _, a := range assets {
		link(w, base+"/"+a.Name, a.Name, fmt.Sprintf("%d", a.Size))
		// Surface the short db/files alias next to its .tar.gz.
		if short, ok := shortDBName(a.Name); ok {
			link(w, base+"/"+short, short, "(alias of "+a.Name+")")
		}
	}
	pageFooter(w)
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
