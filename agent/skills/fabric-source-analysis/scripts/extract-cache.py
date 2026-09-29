#!/usr/bin/env python3
"""Extract & decompress bodies from a Chromium 'Simple Cache' dir (Electron HTTP cache).
Robust to EOF-magic byte collisions inside compressed streams: tries every candidate
boundary and keeps the first that decompresses. Writes decoded bodies + _INDEX.txt.

Usage: extract_cache.py "<Cache_Data dir>" <out dir>
Primary value = _INDEX.txt (every URL the app fetched, by size). For clean minified JS
prefer fetching the _next/static chunks straight from the origin with `curl --compressed`."""
import os, sys, struct, zlib, re, glob
try: import brotli
except ImportError: brotli=None
INIT_MAGIC=0xfcfb6d1ba7725c30; EOF_MAGIC=struct.pack("<Q",0xf4fa6f45970d8d57)

def decompress(b):
    if not b: return None
    if brotli:
        try: return brotli.decompress(b)
        except Exception: pass
    for fn in (lambda x:zlib.decompress(x,16+zlib.MAX_WBITS),
               lambda x:zlib.decompress(x),
               lambda x:zlib.decompress(x,-zlib.MAX_WBITS)):
        try: return fn(b)
        except Exception: pass
    return None

def parse(path):
    d=open(path,"rb").read()
    if len(d)<24: return None
    magic,ver,klen,khash=struct.unpack_from("<QIII",d,0)
    if magic!=INIT_MAGIC: return None
    key=d[24:24+klen].decode("utf-8","replace"); start=24+klen
    # candidate body ends: every EOF magic position, plus end-of-file
    ends=[m.start() for m in re.finditer(re.escape(EOF_MAGIC),d) if m.start()>start]+[len(d)]
    raw=d[start:ends[0]] if ends else d[start:]
    for e in ends:                       # try each boundary; keep first that decodes
        out=decompress(d[start:e])
        if out is not None: return key,out,True
    return key, raw, False               # fall back to raw (e.g. identity-encoded)

def main():
    cache=os.path.expanduser(sys.argv[1]); out=sys.argv[2]; os.makedirs(out,exist_ok=True)
    n=ok=0; idx=[]
    for f in glob.glob(os.path.join(cache,"*_0")):
        r=parse(f)
        if not r: continue
        key,data,decoded=r
        if not data: continue
        m=re.search(r"https?://[^\s\x00]+",key); url=m.group(0) if m else os.path.basename(f)
        base=re.sub(r"[^A-Za-z0-9._-]","_",url.split("?")[0].split("/")[-1] or "index")[:80]
        open(os.path.join(out,f"{os.path.basename(f)[:8]}__{base}"),"wb").write(data)
        n+=1; ok+=decoded; idx.append((url,len(data),decoded))
    idx.sort(key=lambda x:-x[1])
    open(os.path.join(out,"_INDEX.txt"),"w").write(
        "\n".join(f"{s:>9}  {'OK ' if d else 'RAW'}  {u}" for u,s,d in idx))
    print(f"entries={n} decoded_ok={ok} brotli={'yes' if brotli else 'NO(pip install brotli)'}")
if __name__=="__main__": main()
