# Sharing & Short Links

**Status:** Backlog
**Created:** 2026-05-15

## Goal

Allow users to share library items (documents, collections, annotations) via short links. Recipients can view shared content in the browser without installing OakReader.

## Key Decisions

### Domain Strategy

Use a separate domain to isolate user-generated content from the main brand:

| Option | Notes |
|--------|-------|
| `oakreader.site` | Best brand recognition, normal price |
| `oakr.cc` | Shortest, weaker brand association |
| `oakr.site` | Balance of brevity and brand |

Rationale for domain isolation:
- Prevents UGC risk from affecting `oakreader.com` SEO and reputation
- Industry standard practice (GitHub → `github.io`, Notion → `notion.site`)
- Avoids the need for heavy content moderation at launch

### URL Format

```
oakreader.site/s/x7Kp2m          # document
oakreader.site/c/x7Kp2m          # collection
oakreader.site/n/x7Kp2m          # note / annotation
```

- Path IDs: base62 (`[a-zA-Z0-9]`), 6 characters (~568 billion combinations)
- Single-character prefix distinguishes content types

## Architecture

### Components

1. **Share Service (client-side)**
   - Generates share payload (content snapshot + metadata)
   - Uploads to backend, receives short link ID
   - Manages user's shared items (list, revoke, update)

2. **Short Link Service (server-side)**
   - ID → content mapping store
   - Resolves short links and serves rendered pages
   - Tracks basic analytics (view count, referrer)

3. **Web Viewer (frontend)**
   - Lightweight read-only renderer for shared content
   - Supports PDF preview, Markdown, web snapshots, annotations
   - "Open in OakReader" deep link for app users

### Infrastructure Options

| Approach | Pros | Cons |
|----------|------|------|
| Cloudflare Workers + KV + R2 | Near-zero cost at low scale, global edge | Vendor lock-in |
| Self-hosted (VPS + SQLite/Postgres) | Full control | Ops overhead |
| Serverless (AWS Lambda + DynamoDB + S3) | Scales well | More complex setup |

Cloudflare Workers + KV (metadata) + R2 (content blobs) is recommended for the initial launch — minimal cost and maintenance.

## Phased Plan

### Phase 1: Document Sharing

- Share a single library item as a read-only web page
- Support PDF, Markdown, and web snapshot content types
- Basic share dialog in the app (copy link, revoke)
- Shared pages are public (no auth required to view)
- Content snapshot at share time (not live-synced)

### Phase 2: Collections & Annotations

- Share a collection as a browsable list
- Share annotations/highlights with source context
- Expiration controls (7d / 30d / permanent)
- Password-protected shares

### Phase 3: Collaboration

- Shared items with comment threads
- Invite-based access (email / link with permissions)
- Live-sync option (viewer sees latest version)

## Content Policy

- Terms of service prohibiting illegal/harmful content
- Abuse reporting endpoint on every shared page
- Automated takedown for reported content
- Rate limiting on share creation to prevent spam

## Open Questions

- Should shared content be indexable by search engines, or `noindex` by default?
- What is the maximum file size for shared content?
- Should free users have a share quota?
- Do we need Open Graph / social preview cards for shared links?
