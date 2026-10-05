---
name: oak-cli
description: "Drive OakReader's library from the terminal with the `oak` CLI — list, search, read and import documents; manage collections and tags; read back notes, looked-up words and Quick Chat history; and recognise a document's reference metadata (DOI, arXiv, ISBN, PMID, or a title search) with `oak metadata`. Invoke when the user wants to query or change their OakReader library without opening the app, asks what's in their library, wants to batch-import or batch-fix metadata, says 'use the oak cli', 'oak metadata', 'fix my library's titles', 'my library is full of filenames', '用命令行', '批量导入', '修一下元数据'."
---

# The `oak` CLI

`oak` is OakReader's library, without the window. It writes the same SQLite catalog the
app reads, through the same stores in `backend/src/catalog/` — which is the point. A
rule with two implementations drifts; there is one.

Run it from the repo with `bun cli/src/main.ts <args>`, or as `oak` once the app has
installed it.

## Before you touch anything

**Quit the app, or use `--db` on a copy.** Two writers on one SQLite file is how a
library gets corrupted. Reads are safe while the app runs; writes are not.

```bash
cp ~/OakReader/library.sqlite /tmp/try.sqlite
oak --db /tmp/try.sqlite metadata --all          # rehearse here first
```

**`--json` on everything.** Every command speaks JSON, and that is what you should
parse. The human format's columns are fixed by muscle memory, not by a contract.

**Identify an item however is convenient.** `resolver.item` accepts a title, a cite key,
or an ID. Quote titles.

## The commands

| | |
|---|---|
| `oak items list` | `--collection --tag --type --search --sort --limit` |
| `oak items show <item>` | one item's detail |
| `oak items read <item>` | the text, `--pages "1-5"`. Capped at 100k characters |
| `oak items open <item>` | hand it to the app |
| `oak search <query>` | `--limit` |
| `oak import <source>` | a file, a URL; `--title --collection --tag --archive` |
| `oak metadata <item>` | see below |
| `oak collections list\|create\|rename\|add\|remove` | `--parent` on create |
| `oak tags list\|create\|rename\|add\|remove` | `--color` on create |
| `oak status <item> [value]` | read or set reading status |
| `oak notes` | `--item --since --limit --markdown` |
| `oak words` | words looked up while reading; `--today --since --csv` |
| `oak quickchat` | Quick Chat history; `--today --since --full` |
| `oak skills list\|show\|install\|uninstall\|check` | agent skills |

## `oak metadata` — what a document actually is

The recogniser behind this is in `backend/src/metadata/`, and the app's Metadata panel
calls the same code over the protocol. It tries, in order, stopping at the first answer
that clears its bar:

1. **The file's own metadata.** XMP (`dc:title`, `prism:doi`) and the Info dictionary.
2. **An identifier printed on the page** — DOI, arXiv ID, ISBN, PMID — resolved against
   CrossRef, DataCite, arXiv, Open Library, Google Books or PubMed. An arXiv preprint
   that was later published is re-resolved to the published version.
3. **A title search**, on the title the page's *typography* implies: the largest text on
   page one. This is the step Zotero sends to a server; it runs locally here, so nothing
   about the document leaves the machine.
4. **The file's own title and author**, unresolved.
5. **The filename**, cleaned.

```bash
oak metadata "Understanding Deep Learning"            # look, write nothing
oak metadata "Understanding Deep Learning" --apply    # write it
oak metadata <item> --explain                         # every step it tried
oak metadata <item> --identifier 10.1038/nature14539 --apply
oak metadata <item> --offline                         # read the file, make no calls
oak metadata --all                                    # sweep items with no metadata
oak metadata --all --apply --limit 200
oak metadata --all --force                            # redo items that already have it
```

### Read the confidence, always

`confidence` is the whole interface.

- **`>= 0.5`** — a registry confirmed it. `method` and `provider` say which.
- **`< 0.5`** — nothing confirmed it. The title is the document's own or its filename.
  This is an honest description, **not a citation**. Do not present it as one.

A recognition that found an identifier but could not resolve it reports the identifier
under `identifiers` anyway, so you can see what it had.

### Nothing is written without `--apply`

Deliberately. `--apply` **renames the item** to the recognised title and assigns a cite
key, which is visible in the user's sidebar. Never run `--all --apply` unasked.

### When an answer looks wrong

Run `--explain` and read the trail rather than guessing. The two things that actually go
wrong:

- **An identifier that is not this document's.** Technical books print the ISBNs of
  others in their series; a reference list is nothing but other people's DOIs. The
  recogniser checks a resolved record against what the document claims to be called and
  rejects a clear mismatch — the trail says `rejected, "..." is not this document`.
- **A title search that found nothing good enough.** The bar is title similarity, not
  the provider's own relevance score, because that score tracks the query rather than
  the truth. The trail says `nothing cleared the similarity bar`. That is the
  recogniser declining to guess, which is the correct outcome.

## Where the code is

| | |
|---|---|
| `cli/src/main.ts` | commands and dispatch |
| `cli/src/help.ts` | the command tree, which is also the help text |
| `cli/src/format.ts` | the human output |
| `backend/src/catalog/` | the stores — shared with the app, do not fork them |
| `backend/src/metadata/` | the recogniser: `identifiers`, `pdf`, `providers`, `match`, `recognize` |
| `protocol/schema.ts` | add a method here, then `pnpm protocol:generate` |

Adding a command means: a function in `main.ts`, an entry in `OPERATIONS`, an entry in
`help.ts`'s `TREE`, and any new boolean flag listed in `BOOLEANS` — a flag missing from
that set is parsed as taking a value and will swallow the next argument.

Tests: `cd cli && bun test test/*.test.ts`, and `cd backend && bun test test/*.test.ts`.
