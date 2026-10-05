/**
 * The recogniser's judgement, tested without the network.
 *
 * Every case here is a document this met in a real library. The ones that
 * assert a *rejection* matter most: a recogniser that resolves everything is
 * worse than one that admits defeat, because a confident wrong answer is
 * filed, cited, and never looked at again.
 */
import { test, expect, describe } from "bun:test";
import { findDoi, findArxiv, findIsbn, findPmid, findIdentifiers } from "../src/metadata/identifiers.ts";
import { titleSimilarity, accepts, normalizeTitle, sharesAuthor } from "../src/metadata/match.ts";
import { titleFromFileName } from "../src/metadata/recognize.ts";
import { splitName, splitPubMedName } from "../src/metadata/providers.ts";

describe("DOI", () => {
  test("reads one out of running text without the next word", () => {
    expect(findDoi("See doi:10.1038/nature14539 for details.")).toBe("10.1038/nature14539");
    expect(findDoi("https://doi.org/10.1145/3292500.3330701")).toBe("10.1145/3292500.3330701");
    expect(findDoi("(10.1109/TPAMI.2016.2577031).")).toBe("10.1109/tpami.2016.2577031");
  });

  test("does not take a filename's extension with it", () => {
    expect(findDoi("10.1000/sample.pdf")).toBe("10.1000/sample");
  });

  test("declines a truncated suffix", () => {
    expect(findDoi("10.1234/a")).toBeNull();
  });

  test("declines a number that merely starts with 10.", () => {
    expect(findDoi("version 10.1 of the spec")).toBeNull();
  });
});

describe("arXiv", () => {
  test("reads both id generations", () => {
    expect(findArxiv("arXiv:1706.03762v5")).toBe("1706.03762v5");
    expect(findArxiv("arXiv:math.GT/0309136")).toBe("math.GT/0309136");
  });

  test("reads the id out of arXiv's own DOI", () => {
    expect(findArxiv("https://doi.org/10.48550/arXiv.2401.01234")).toBe("2401.01234");
  });
});

describe("ISBN", () => {
  test("accepts a valid 13 and a valid 10", () => {
    expect(findIsbn("ISBN 978-0-262-04864-4")).toBe("9780262048644");
    expect(findIsbn("ISBN: 0-321-26889-X")).toBe("032126889X");
  });

  test("rejects a number that fails its own check digit", () => {
    // The same string with the last digit changed. Without the checksum this
    // resolves to a real but different book.
    expect(findIsbn("ISBN 978-0-262-04864-5")).toBeNull();
  });

  test("ignores a page or phone number sitting beside the word", () => {
    expect(findIsbn("ISBN pending, call 555-0100")).toBeNull();
  });
});

describe("PMID", () => {
  test("reads a labelled id only", () => {
    expect(findPmid("PMID: 26017442")).toBe("26017442");
    expect(findPmid("accession 26017442")).toBeNull();
  });
});

describe("findIdentifiers", () => {
  test("reports every identifier a copyright page carries", () => {
    const page = "Published 2023. ISBN 978-0-262-04864-4. doi:10.7551/mitpress/14641.001.0001";
    const found = findIdentifiers(page);
    expect(found.isbn).toBe("9780262048644");
    expect(found.doi).toBe("10.7551/mitpress/14641.001.0001");
    expect(found.arxiv).toBeUndefined();
  });
});

describe("titleSimilarity", () => {
  test("accepts the same work recorded with its subtitle", () => {
    const score = titleSimilarity(
      "Understanding Deep Learning", "Understanding Deep Learning: A Visual Introduction");
    expect(accepts(score, false)).toBe(true);
  });

  test("rejects the thesis that contains every word of the textbook's title", () => {
    // The failure that made plain containment unusable: this scored 1.00 and
    // filed a 541-page MIT Press book as somebody's dissertation.
    const score = titleSimilarity(
      "Understanding Deep Learning",
      "Learning Deep Representations : Toward a better new understanding of the deep learning paradigm");
    expect(score).toBeLessThan(0.5);
    expect(accepts(score, false)).toBe(false);
    expect(accepts(score, true)).toBe(false);
  });

  test("a two-word title needs the author to agree", () => {
    const score = titleSimilarity("Clean Code", "Clean Code: A Handbook of Agile Software Craftsmanship");
    expect(accepts(score, false)).toBe(false);
    expect(accepts(score, true)).toBe(true);
  });

  test("a short title does not match a much longer different book", () => {
    const score = titleSimilarity("Deep Learning", "Deep Learning for Computer Vision with Python Volume 3");
    expect(accepts(score, true)).toBe(false);
  });

  test("one shared word is coincidence", () => {
    expect(titleSimilarity("Introduction to Algorithms", "Algorithms Unlocked")).toBe(0);
  });

  test("normalises punctuation and case", () => {
    expect(normalizeTitle("Attention Is All You Need!")).toBe("attention is all you need");
    expect(titleSimilarity("Attention Is All You Need", "ATTENTION IS ALL YOU NEED")).toBe(1);
  });
});

describe("sharesAuthor", () => {
  test("matches on family name across given-name spellings", () => {
    expect(sharesAuthor(
      [{ family: "Prince", given: "Simon" }],
      [{ family: "Prince", given: "Simon J. D." }])).toBe(true);
    expect(sharesAuthor([{ family: "Prince" }], [{ family: "Goodfellow" }])).toBe(false);
  });
});

describe("titleFromFileName", () => {
  test("cleans the name the bug report arrived under", () => {
    expect(titleFromFileName("UnderstandingDeepLearning_02_09_26_C (1).pdf"))
      .toBe("Understanding Deep Learning");
  });

  test("strips Zotero's author-year export prefix", () => {
    expect(titleFromFileName("Campbell et al. - 2022 - Factors that influence mental health.pdf"))
      .toBe("Factors that influence mental health");
  });

  test("leaves an ordinary title alone", () => {
    expect(titleFromFileName("Attention Is All You Need.pdf")).toBe("Attention Is All You Need");
  });

  test("drops a leading date without eating the words", () => {
    expect(titleFromFileName("2024-01-15_meeting_notes.pdf")).toBe("meeting notes");
  });
});

describe("author names", () => {
  test("splits Western order", () => {
    expect(splitName("Simon J.D. Prince")).toEqual({ family: "Prince", given: "Simon J.D." });
    expect(splitName("Prince, Simon")).toEqual({ family: "Prince", given: "Simon" });
  });

  test("splits PubMed's family-first order", () => {
    // splitName alone turns this into {family: "Y", given: "LeCun"}.
    expect(splitPubMedName("LeCun Y")).toEqual({ family: "LeCun", given: "Y" });
    expect(splitPubMedName("van der Maaten L")).toEqual({ family: "van der Maaten", given: "L" });
  });
});
