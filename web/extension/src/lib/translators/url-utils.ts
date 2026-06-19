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

/**
 * Hosts whose value is the live page, not a saved snapshot — video platforms and
 * social media. An offline HTML snapshot of these is meaningless (no player, dynamic
 * feed, login walls), so they are always clipped as a `.link` bookmark that opens live.
 * Keep in sync with `ZoteroMigrationService.liveWebHosts` on the Swift side.
 */
const LIVE_WEB_HOSTS = [
  // ── Video ──
  "youtube.com", "youtu.be", "vimeo.com", "dailymotion.com", "dai.ly",
  "tiktok.com", "douyin.com", "kuaishou.com", "kwai.com",
  "bilibili.com", "b23.tv", "youku.com", "iqiyi.com", "v.qq.com", "ixigua.com",
  "rumble.com", "odysee.com", "bitchute.com", "nicovideo.jp", "coub.com",
  "streamable.com", "tv.naver.com", "rutube.ru", "abema.tv", "tving.com", "triller.com",
  // ── Live streaming ──
  "twitch.tv", "kick.com", "chzzk.naver.com", "sooplive.co.kr", "afreecatv.com",
  "douyu.com", "huya.com", "nimo.tv", "trovo.live", "dlive.tv", "bigo.tv",
  "showroom-live.com", "younow.com",
  // ── Social ──
  "x.com", "twitter.com", "t.co", "facebook.com", "fb.com", "fb.watch",
  "instagram.com", "threads.net", "threads.com", "reddit.com", "redd.it",
  "linkedin.com", "lnkd.in", "pinterest.com", "pin.it", "tumblr.com",
  "snapchat.com", "bsky.app", "mastodon.social", "truthsocial.com", "gettr.com",
  "gab.com", "vk.com", "ok.ru", "weibo.com", "weibo.cn", "xiaohongshu.com",
  "xhslink.com", "zhihu.com", "douban.com", "tieba.baidu.com", "line.me",
  "band.us", "mixi.jp", "quora.com", "qr.ae",
  // ── Messaging ──
  "t.me", "telegram.org", "telegram.me", "wa.me", "whatsapp.com",
  "discord.com", "discord.gg",
  // ── Music / audio / podcast ──
  "spotify.com", "music.apple.com", "podcasts.apple.com", "music.amazon.com",
  "soundcloud.com", "bandcamp.com", "deezer.com", "tidal.com", "pandora.com",
  "iheart.com", "mixcloud.com", "audiomack.com", "anchor.fm", "music.163.com",
  "y.qq.com", "kugou.com", "kuwo.cn", "ximalaya.com", "xiaoyuzhoufm.com",
  "lizhi.fm", "castbox.fm", "overcast.fm", "pocketcasts.com", "podbean.com",
  "spreaker.com", "melon.com", "genie.co.kr", "bugs.co.kr", "joox.com",
  // ── Regional: India ──
  "sharechat.com", "mojapp.in", "chingari.io", "roposo.com",
  "hotstar.com", "jiocinema.com", "zee5.com", "sonyliv.com",
  "gaana.com", "jiosaavn.com", "wynk.in", "hungama.com",
  // ── Regional: Japan ──
  "pixiv.net", "tver.jp", "17.live", "pococha.com",
  // ── Regional: South Korea ──
  "weverse.io", "wavve.com", "watcha.com", "music-flo.com",
  // ── Regional: Russia ──
  "dzen.ru", "music.yandex.ru", "likee.video", "yappy.media",
  // ── Regional: Southeast Asia ──
  "vidio.com", "viu.com", "wetv.vip", "snackvideo.com",
  // ── Regional: Middle East / North Africa ──
  "shahid.net", "anghami.com",
  // ── Regional: Türkiye ──
  "blutv.com", "exxen.com", "puhutv.com",
  // ── Regional: Iran ──
  "aparat.com", "filimo.com",
  // ── Regional: Vietnam ──
  "zingmp3.vn", "zalo.me",
  // ── Regional: Africa ──
  "boomplay.com",
  // ── Regional: Latin America ──
  "globoplay.globo.com", "vix.com",
];

export function isLiveWebHost(url: string): boolean {
  try {
    const hostname = new URL(url).hostname.toLowerCase();
    return LIVE_WEB_HOSTS.some(
      (domain) => hostname === domain || hostname.endsWith("." + domain)
    );
  } catch {
    return false;
  }
}

