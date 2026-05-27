/**
 * Shared URL detection utilities — single source of truth for all URL-based detection.
 */

export function isDOIURL(url: string): boolean {
  try {
    const u = new URL(url);
    return (
      u.hostname === "doi.org" ||
      u.hostname === "www.doi.org" ||
      u.hostname === "dx.doi.org"
    );
  } catch {
    return false;
  }
}

const SCHOLARLY_DOMAINS = [
  "arxiv.org",
  "pubmed.ncbi.nlm.nih.gov",
  "ncbi.nlm.nih.gov",
  "scholar.google.com",
  "jstor.org",
  "springer.com",
  "link.springer.com",
  "nature.com",
  "science.org",
  "sciencedirect.com",
  "ieeexplore.ieee.org",
  "ieee.org",
  "dl.acm.org",
  "acm.org",
  "wiley.com",
  "onlinelibrary.wiley.com",
  "tandfonline.com",
  "sagepub.com",
  "cambridge.org",
  "oxford.org",
  "academic.oup.com",
  "oup.com",
  "plos.org",
  "journals.plos.org",
  "biorxiv.org",
  "medrxiv.org",
  "ssrn.com",
  "researchgate.net",
  "frontiersin.org",
  "mdpi.com",
  "cell.com",
  "thelancet.com",
  "bmj.com",
  "pnas.org",
  "aps.org",
  "aip.org",
];

export function isScholarlyDomain(url: string): boolean {
  try {
    const hostname = new URL(url).hostname.toLowerCase();
    return SCHOLARLY_DOMAINS.some(
      (domain) => hostname === domain || hostname.endsWith("." + domain)
    );
  } catch {
    return false;
  }
}

