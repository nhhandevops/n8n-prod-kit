## What

<!-- one paragraph: what changes and why -->

## Checklist

- [ ] `make lint` is green locally
- [ ] Smoke output pasted below (or "docs only")
- [ ] Docs page added / updated for every behaviour change
- [ ] `n8n-kit-CHANGELOG.md` → Unreleased updated
- [ ] No real domains, IPs, keys or employer infrastructure anywhere (placeholders: `example.com`, `n8n.localtest.me`, `203.0.113.0/24`)
- [ ] Image digests / action SHAs / binary checksums pinned for anything new

## Smoke output

```text
(make -C compose smoke)
```
