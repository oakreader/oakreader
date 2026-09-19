// CJK bigram tokenizer parity test.
//
// Guards the invariant that makes the Swift -> Node catalog port possible:
// userland bigram expansion + plain unicode61 must retrieve exactly what the
// Swift `cjk_bigram` FTS5 tokenizer retrieved. Ground truth is a raw substring
// scan, which is what a CJK user actually expects from a keyword search.
//
// Runs on synthetic text by default. Point OAK_SEARCH_DB at a real
// search.sqlite to re-run it over a live corpus (that is how the approach was
// originally validated: 201,707 chunks, 12 highest-frequency CJK terms, zero
// false negatives and zero false positives).
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { expand, buildMatchQuery, isCJK } from "../src/catalog/tokenizer.ts";

test("expansion matches CJKBigramTokenizer.swift", () => {
  assert.equal(expand("机器学习"), "机器 器学 学习");
  assert.equal(expand("学习"), "学习");
  assert.equal(expand("字"), "字", "a lone CJK char is emitted as itself");
  assert.equal(expand("hello"), "hello", "Latin passes through untouched");
  assert.equal(expand("ハローワールド"), "ハロ ロー ーワ ワー ール ルド", "kana too");
  assert.equal(expand(""), "");
});

test("astral-plane CJK (Extension B) is not split mid-surrogate", () => {
  const a = String.fromCodePoint(0x20000), b = String.fromCodePoint(0x20001);
  assert.ok(isCJK(0x20000));
  assert.equal(expand(a + b), a + b);
});

test("query expansion quotes tokens so FTS5 operators in user text are inert", () => {
  assert.equal(buildMatchQuery("机器学习"), '"机器" AND "器学" AND "学习"');
  assert.equal(buildMatchQuery(""), "");
  assert.ok(!buildMatchQuery('a" OR "b').includes('" OR "'), "quotes must be escaped");
});

test("retrieval equals substring scan over a corpus", () => {
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE VIRTUAL TABLE fts USING fts5(body, tokenize=unicode61)");
  db.exec("CREATE TABLE raw(id INTEGER PRIMARY KEY, body TEXT)");
  const docs = [
    "机器学习是人工智能的一个分支",
    "深度学习与机器学习的区别",
    "learning rate schedules in PyTorch",
    "用 PyTorch 做深度学习入门",
    "屠龙之术",
    "ハローワールド",
  ];
  const insF = db.prepare("INSERT INTO fts(rowid, body) VALUES (?, ?)");
  const insR = db.prepare("INSERT INTO raw(id, body) VALUES (?, ?)");
  docs.forEach((d, i) => { insF.run(i + 1, expand(d)); insR.run(i + 1, d); });

  for (const q of ["学习", "机器学习", "深度学习", "屠龙之术", "ワール", "PyTorch"]) {
    const truth = db.prepare("SELECT id FROM raw WHERE body LIKE ?").all(`%${q}%`).map(r => r.id);
    const got = db.prepare("SELECT rowid AS id FROM fts WHERE fts MATCH ?").all(buildMatchQuery(q)).map(r => r.id);
    assert.deepEqual(got.sort(), truth.sort(), `query ${q}`);
  }
});

test("mid-run match is the whole point (regression against unicode61 alone)", () => {
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE VIRTUAL TABLE plain USING fts5(body, tokenize=unicode61)");
  db.exec("CREATE VIRTUAL TABLE fts USING fts5(body, tokenize=unicode61)");
  db.prepare("INSERT INTO plain(rowid, body) VALUES (1, ?)").run("机器学习");
  db.prepare("INSERT INTO fts(rowid, body) VALUES (1, ?)").run(expand("机器学习"));
  assert.equal(db.prepare("SELECT count(*) c FROM plain WHERE plain MATCH ?").get('"学习"').c, 0,
    "unicode61 alone cannot match mid-run — this is the bug the tokenizer exists to fix");
  assert.equal(db.prepare("SELECT count(*) c FROM fts WHERE fts MATCH ?").get(buildMatchQuery("学习")).c, 1);
});
