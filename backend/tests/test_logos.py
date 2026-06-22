"""Logo proxy: fetches a brand logo from upstream, caches it in MinIO, and serves it; rejects bad
domains. Hits the running api like the other integration tests and cleans up its own MinIO object.
"""
import urllib.error
import urllib.request

from app.integrations.storage import minio_client

API = "http://localhost:8000"
DOMAIN = "github.com"


def _get(path):
    req = urllib.request.Request(API + path, method="GET")
    try:
        resp = urllib.request.urlopen(req)
        return resp.status, resp.read(), resp.headers.get("Content-Type")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("Content-Type")


def test_logo_proxy_caches_and_serves():
    key = f"logos/{DOMAIN}.img"
    try:
        status, body, ctype = _get(f"/logos/{DOMAIN}")
        assert status == 200, (status, ctype, body[:200])
        assert ctype == "image/png"
        assert len(body) > 0
        assert minio_client.object_exists(key)
        # Second call is served straight from the MinIO cache.
        status2, body2, _ = _get(f"/logos/{DOMAIN}")
        assert status2 == 200 and len(body2) == len(body)
    finally:
        try:
            minio_client.remove(key)
        except Exception:
            pass


def test_logo_proxy_rejects_bad_domain():
    # Too short / invalid → 404, no upstream fetch.
    assert _get("/logos/x")[0] == 404
