import json, os, re, sys

src, outdir = sys.argv[1], sys.argv[2]
d = json.load(open(src))
os.makedirs(outdir, exist_ok=True)
for it in d["normalized_result"]["items"]:
    n = it["procedure"]["name"]
    fn = re.sub(r"[^A-Za-z0-9_]+", "_", n).strip("_")[:120]
    with open(os.path.join(outdir, fn + ".m"), "w") as fh:
        fh.write(f"// {n} @ {it['address']}\n// evidence {d['evidence_id']}\n" + (it.get("pseudocode") or ""))
