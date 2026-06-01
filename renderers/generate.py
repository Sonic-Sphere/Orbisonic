#!/usr/bin/env python3
"""Generate per-renderer spec bundles (machine JSON + human MD): geometry + design math +
helpful explanations + the resulting kernel + provenance + checksums. Stereo is parametric."""
import csv, math, json, os, hashlib
import numpy as np

OUT = "/tmp/renderers_out"
GEOM_COMMIT = os.environ.get("GEOM_COMMIT", "unknown")
ALGO_VERSION = "1.0.0"
SHARP = 3.0; CAP = 0.22; CAP_ITERS = 6
STEREO_DEFAULT = 90.0
STEREO_PRESETS = [
 {"angleDeg":0,   "name":"Mono collapse",    "effect":"L and R coincide at front-center — a single mono image."},
 {"angleDeg":60,  "name":"Classic stereo",   "effect":"conventional loudspeaker pair at ∓30° — natural frontal stage."},
 {"angleDeg":90,  "name":"Wide (Stereo 90)", "effect":"broad frontal image at ≃45° — the previous default."},
 {"angleDeg":180, "name":"Enveloping (180)", "effect":"L and R at the hard sides (≃90°) — maximally wide / enveloping."},
]

FEY = {1:(0.00,0.60,-0.90),2:(0.60,0.20,-0.90),3:(0.36,-0.49,-0.90),4:(-0.36,-0.49,-0.90),
 5:(-0.60,0.20,-0.90),6:(-0.60,0.69,-0.60),7:(0.60,0.69,-0.60),8:(0.80,-0.26,-0.60),
 9:(0.00,-0.80,-0.60),10:(-0.80,-0.26,-0.60),11:(-1.00,0.33,-0.25),12:(0.00,1.00,-0.25),
 13:(1.00,0.33,-0.25),14:(0.73,-1.00,-0.25),15:(-0.73,-1.00,-0.25),16:(-1.00,-0.33,0.25),
 17:(-0.72,1.00,0.25),18:(0.72,1.00,0.25),19:(1.00,-0.33,0.25),20:(0.00,-1.00,0.25),
 21:(-0.50,-0.69,0.60),22:(-0.80,0.25,0.60),23:(0.00,0.80,0.60),24:(0.80,0.26,0.60),
 25:(0.50,-0.69,0.60),26:(0.00,-0.60,0.90),27:(-0.60,-0.20,0.90),28:(-0.50,0.69,0.90),
 29:(0.50,0.69,0.90),30:(0.60,-0.20,0.90)}
sph_ids=sorted(FEY); S=np.array([FEY[i] for i in sph_ids],float); Sn=S/np.linalg.norm(S,axis=1,keepdims=True)
def az(x,y): return round(math.degrees(math.atan2(x,y)),1)
def elev(x,y,z):
    r=math.sqrt(x*x+y*y+z*z); return round(math.degrees(math.asin(z/r)),1) if r else 0.0
SPH_AZ=[az(x,y) for (x,y,z) in S]
def pos_from_az_el(a,e=0.0):
    ar,er=math.radians(a),math.radians(e); return (math.sin(ar)*math.cos(er), math.cos(ar)*math.cos(er), math.sin(er))
def _n(v):
    p=np.sqrt((v*v).sum()); return v if p<=0 else v/p
def capnorm(v):
    cap=math.sqrt(CAP); r=_n(v.copy())
    for _ in range(CAP_ITERS):
        cl=bool(np.any(r>cap)); r=np.minimum(r,cap); r=_n(r)
        if not cl: break
    return _n(r)
def pan(x,y,z):
    d=np.array([x,y,z],float); d=d/np.linalg.norm(d)
    return capnorm(np.clip(Sn.dot(d),0,None)**SHARP)
def columns(channels):
    cols=[]
    for ch in channels:
        if ch['lfe']:
            cols.append({"channelIndex":ch['index'],"label":ch['label'],"lfe":True,"gains":[[30,1.0]]}); continue
        p=ch['position']; col=pan(p['x'],p['y'],p['z'])
        g=sorted([[sph_ids[k],round(float(col[k]),6)] for k in range(30) if col[k]>1e-4],key=lambda t:-t[1])
        cols.append({"channelIndex":ch['index'],"label":ch['label'],"lfe":False,"gains":g})
    return cols

ROLE={"C":"center","L":"frontLeft","R":"frontRight","LFE":"lfe","FL":"frontLeft","FR":"frontRight",
 "RL":"rearLeft","RR":"rearRight","Ls":"sideLeft","Rs":"sideRight","Lss":"sideLeft","Rss":"sideRight",
 "Lrs":"rearLeft","Rrs":"rearRight","Lb":"rearLeft","Rb":"rearRight","Lw":"wideLeft","Rw":"wideRight",
 "Ltf":"topFrontLeft","Rtf":"topFrontRight","Ltr":"topRearLeft","Rtr":"topRearRight",
 "Ltm":"topMiddleLeft","Rtm":"topMiddleRight","HL":"heightFrontLeft","HR":"heightFrontRight",
 "HLs":"heightRearLeft","HRs":"heightRearRight","T":"topCenter","HC":"heightCenter",
 "LeftEar":"frontLeft","RightEar":"frontRight"}
META={"mono_1_0":("Mono 1.0","mono"),"stereo_2_0":("Stereo (parametric)","stereo"),
 "binaural_2_0_narrow":("Binaural 2.0 (narrow)","binaural"),"quad_4_0":("Quad 4.0","quad"),
 "5_1":("5.1","dolby"),"5_1_2":("Dolby 5.1.2","dolby"),"5_1_4":("Dolby 5.1.4","dolby"),
 "7_1":("Dolby 7.1","dolby"),"7_1_2":("Dolby 7.1.2","dolby"),"7_1_4":("Dolby 7.1.4","dolby"),
 "9_1_4":("Dolby 9.1.4","dolby"),"9_1_6":("Dolby 9.1.6","dolby"),
 "harmony_bloom_8ch":("Harmony Bloom (8ch)","custom"),"auro_8_0":("Auro 8.0","auro"),
 "auro_9_1":("Auro 9.1","auro"),"auro_10_1":("Auro 10.1","auro"),
 "auro_11_1_5_1_5h_t":("Auro 11.1 (5+5H+T)","auro"),"auro_11_1_7_1_4h":("Auro 11.1 (7+4H)","auro"),
 "auro_13_1":("Auro 13.1","auro")}
DESC={
 "mono_1_0":"Single-channel source placed at front-center. The dome focuses it on the nearest front speakers, giving a localized front image (not an omnidirectional wash). Use this for mono music/voice where a centered phantom image is wanted.",
 "binaural_2_0_narrow":"A deliberately narrow ±15° stereo pair for binaural/near-field material, keeping L and R tight to front-center for an intimate, head-locked image. For binaural content meant to wrap around you, prefer the parametric Stereo renderer opened to a wide angle.",
 "quad_4_0":"Four corner channels at ±45° (front) and ±135° (rear) — no center, no height. Maps to the four dome quadrants for a classic enveloping square; great for quad music and 4-corner ambience.",
 "5_1":"Cinema 5.1: front L/C/R, two surrounds at ±110°, and an LFE. Center anchors dialogue up front, surrounds wrap to the sides/back, LFE → sub. Mapping is role-aware, so the different 5.1 channel orders (film L/C/R…, SMPTE L/R/C…, DTS L/R/Ls/Rs/C/LFE) all resolve to the same dome image — this is the 'two kinds of 5.1' problem, solved by reading roles not positions.",
 "5_1_2":"5.1 with two overhead 'top-middle' channels (±90° at +45° elevation). Adds a height layer directly above the listener to the standard 5.1 bed — the entry-level Atmos-style immersive layout.",
 "5_1_4":"5.1 with four overhead channels (top-front and top-rear pairs), giving a full height layer over the 5.1 base for convincing overhead pans and ceiling ambience.",
 "7_1":"7.1 separates SIDE surrounds (±90°) from REAR surrounds (±135°) — the defining upgrade over 5.1. On the dome the sides and rears land on distinct speaker regions. (This is exactly what the old count-based Auro mapping got wrong, collapsing sides and rears together.)",
 "7_1_2":"7.1 plus two overhead 'top-middle' channels — a 7.1 base with a single height row above the listener.",
 "7_1_4":"7.1 plus four overhead channels (top-front + top-rear) — the canonical immersive bed shape (a.k.a. the Dolby Atmos 7.1.4 bed). Sides, rears, and both height rows each map to their own dome region.",
 "9_1_4":"7.1.4 plus a pair of 'wide' front channels at ±60° that fill the gap between front L/R and the side surrounds, widening and smoothing the frontal stage.",
 "9_1_6":"The widest bed here: 9.1.4 plus two extra 'top-middle' overheads — wide fronts, full side+rear surrounds, and a six-speaker height layer for dense overhead detail.",
 "harmony_bloom_8ch":"A custom 8-point ring ('Harmony Bloom') whose channels carry NO standard roles — only positions. It works purely from geometry, which is precisely why a data-driven engine is required: each HB-n channel lands wherever its position points on the dome. Hand-tuned, role-based beds cannot express this layout.",
 "auro_8_0":"Auro-3D 8.0: an ear-level L/R + side ring with a height layer stacked directly ABOVE it (HL/HR/HLs/HRs), rather than overhead like Atmos. No LFE.",
 "auro_9_1":"Auro-3D 9.1: 5.1 at ear level plus four Auro height channels stacked above the mains and surrounds.",
 "auro_10_1":"Auro-3D 10.1: Auro 9.1 plus a single 'Top' (voice-of-god) channel at the dome apex.",
 "auro_11_1_5_1_5h_t":"Auro-3D 11.1 (5.1 + 5 height + Top): 5.1 base, a five-wide height layer including a height-center (HC), and a Top channel.",
 "auro_11_1_7_1_4h":"Auro-3D 11.1 (7.1 + 4 height): a 7.1-style base in Auro channel order (note: Auro lists rears Lb/Rb BEFORE sides Ls/Rs, unlike Dolby) plus a four-wide height layer.",
 "auro_13_1":"Auro-3D 13.1: the largest Auro bed — 7.1-style base, a five-wide height layer with height-center, and a Top channel.",
}
STEREO_DESC=("Parametric stereo — the special one. L and R are placed symmetrically at ∓θ/2 and ±θ/2, "
 "and the single control θ is the ANGLE BETWEEN THEM. Sweeping θ continuously reshapes the image: at 0° the two "
 "channels collapse to front-center (mono); at 60° you get a conventional loudspeaker pair; at 90° a wide frontal "
 "stage; at 180° L and R sit at the hard sides for a fully enveloping image. Each channel is then panned onto the "
 "dome by the same geometry engine, so as θ grows the two images glide smoothly apart from the center to the sides.")
DESIGN_NOTE={
 "mono_1_0":"Placed at front-center per the layout. If you want whole-dome mono instead, that is a one-line variant (pan to all speakers equally) — left out here to stay faithful to the layout geometry.",
 "auro_11_1_7_1_4h":"Auro channel order differs from Dolby (rears before sides). Because mapping is role-aware, Auro and Dolby 12-channel beds resolve correctly even though they share a channel count.",
 "7_1":"Distinct side vs rear placement is the whole point of 7.1; verify by ear that Lss images to your side and Lrs behind you.",
}

# parameters with human-friendly explanations ("super helpful")
PARAMS={
 "cosineSharpness":{"value":SHARP,"description":"Focus of each channel's spread. Higher = tighter (a channel drives fewer, closer dome speakers); lower = broader and more diffuse. At 3.0 each channel lights ~4-6 nearest speakers."},
 "perSpeakerPowerCap":{"value":CAP,"unit":"fraction of a channel's power","description":"No single dome speaker may carry more than this share of a channel's power. It forces every channel to spread across several speakers, so images feel enveloping instead of pin-point, and no one speaker dominates."},
 "normalization":{"value":"unitL2Power","description":"Each channel's gains are scaled so its total power sums to 1. Spreading a channel across many speakers is therefore neither louder nor quieter than putting it on one speaker — loudness stays constant as geometry changes."},
 "capIterations":{"value":CAP_ITERS,"description":"How many clip-then-renormalize passes enforce the per-speaker cap. 6 is plenty for the cap to settle."},
 "lfeRouting":{"output":31,"outputIndex":30,"gain":1.0,"description":"LFE / direct-out channels skip the dome panning entirely and go straight to the sub (output 31) at unity gain."},
}
ALGO={"name":"cosine-power directional panning with capped power normalization","version":ALGO_VERSION,
 "summary":"Each non-LFE source channel is aimed in its real-world direction and spread across the nearest dome speakers by angular proximity, then loudness-normalized with a per-speaker cap so the image is even and enveloping. LFE goes to the sub.",
 "formula":"w_i = max(0, d · ŝ_i)^p over the 30 dome speakers; iteratively clip any w_i to a_max = sqrt(cap) and renormalize to unit L2 power (sum w_i^2 = 1); LFE channels map to the sub at unity.",
 "parameters":PARAMS}
CONV={"x":"listener-right","y":"front","z":"up","azimuth":"degrees from front, positive to the right","radius":"unit (LFE excluded)"}
def sha(o): return hashlib.sha256(json.dumps(o,sort_keys=True,separators=(",",":")).encode()).hexdigest()

os.makedirs(OUT,exist_ok=True)
sphere={"id":"fey-30.1","fullRangeOutputs":30,"lfeOutput":31,"lfeOutputIndex":30,"coordinateConvention":CONV,
 "speakers":[{"id":i,"x":FEY[i][0],"y":FEY[i][1],"z":FEY[i][2],"azimuthDeg":az(*FEY[i][:2]),"elevationDeg":elev(*FEY[i])} for i in sph_ids]}
SPH_SHA=sha(sphere["speakers"]); json.dump(sphere,open(f"{OUT}/sphere-fey-30.1.json","w"),indent=2)

rows=list(csv.DictReader(open('/tmp/layout_geometry.csv')))
layouts={}
for r in rows: layouts.setdefault(r['layout'],[]).append(r)

def csv_channels(chs):
    out=[]
    for i,c in enumerate(chs):
        x,y,z=float(c['x']),float(c['y']),float(c['z'])
        out.append({"index":i,"patch":int(c['patch']),"label":c['label'],"role":ROLE.get(c['label'],"discrete"),
          "azimuthDeg":float(c['azimuth_degrees']),"elevationDeg":float(c['elevation_degrees']),
          "position":{"x":round(x,10),"y":round(y,10),"z":round(z,10)},"lfe":c['direct_out_only']=='1'})
    return out
def stereo_channels(angle):
    half=angle/2.0; out=[]
    for i,(lab,role,a) in enumerate([("L","frontLeft",-half),("R","frontRight",half)]):
        x,y,z=pos_from_az_el(a)
        out.append({"index":i,"patch":i+1,"label":lab,"role":role,"azimuthDeg":round(a,3),"elevationDeg":0.0,
          "position":{"x":round(x,10),"y":round(y,10),"z":round(z,10)},"lfe":False})
    return out

def top_cells(col):
    return ", ".join(f"#{g[0]}@{SPH_AZ[sph_ids.index(g[0])]:+.0f}°:{g[1]:.2f}" for g in col['gains'][:5])

index=[]
for name,chs in layouts.items():
    disp,fam=META.get(name,(name,"other")); d=f"{OUT}/{name}"; os.makedirs(d,exist_ok=True)
    is_stereo = name=="stereo_2_0"
    channels = stereo_channels(STEREO_DEFAULT) if is_stereo else csv_channels(chs)
    lfe=sum(1 for ch in channels if ch['lfe'])
    cols=columns(channels)
    kernel={"outputCount":31,"lfeOutputIndex":30,"type":"inputMajorSparse","columns":cols}
    spec={"schemaVersion":1,"layout":name,"displayName":disp,"family":fam,
      "description":(STEREO_DESC if is_stereo else DESC.get(name,"")),
      "channelCount":len(channels),"lfeChannelCount":lfe,"coordinateConvention":CONV,"algorithm":ALGO,
      "sphereTarget":{"id":"fey-30.1","fullRangeOutputs":30,"lfeOutput":31,"speakersRef":"sphere-fey-30.1.json","speakersSha256":SPH_SHA},
      "provenance":{"geometrySource":{"repo":"Sonic-Sphere/spat-speaker-layouts","path":"layout_geometry.csv","commit":GEOM_COMMIT},
        "generator":"gen_renderers.py","algorithm":f"cosine-power v{ALGO_VERSION}"},
      "channels":channels,"kernel":kernel,
      "checksums":{"kernelSha256":sha(kernel),"geometrySha256":sha(channels)}}
    if name in DESIGN_NOTE: spec["designNotes"]=DESIGN_NOTE[name]
    if is_stereo:
        samples=[]
        for a in [p["angleDeg"] for p in STEREO_PRESETS]:
            samples.append({"angleDeg":a,"columns":columns(stereo_channels(a))})
        spec["parametric"]={
          "parameter":"angleBetweenLRDegrees",
          "description":"The angle between the Left and Right channels. L is placed at -angle/2 and R at +angle/2; the geometry engine then pans each onto the dome. Lower = narrower/more centered, higher = wider/more enveloping.",
          "range":{"min":0,"max":180,"unit":"degrees"},"default":STEREO_DEFAULT,
          "placement":"L.azimuth = -angle/2 ; R.azimuth = +angle/2 ; elevation = 0",
          "presets":STEREO_PRESETS,
          "codegen":"function(angleDegrees) -> columns",
          "kernelAtDefault":True,"samples":samples}
        spec["codegenHint"]="parametricFunction"
    else:
        spec["codegenHint"]="staticTable"
    json.dump(spec,open(f"{d}/{name}.renderer.json","w"),indent=2)

    # ---- human-readable MD ----
    L=[f"# {disp} — Sonic Sphere renderer spec\n"]
    L.append(f"- **Layout id:** `{name}`  ·  **Family:** {fam}  ·  **Channels:** {len(channels)} ({lfe} LFE)")
    L.append(f"- **Target:** Fey 30.1 dome (30 full-range + sub)  ·  **Algorithm:** cosine-power directional panning v{ALGO_VERSION}")
    L.append(f"- **Provenance:** `Sonic-Sphere/spat-speaker-layouts/layout_geometry.csv` @ `{GEOM_COMMIT[:10]}`\n")
    L.append("## What this renderer does\n")
    L.append((STEREO_DESC if is_stereo else DESC.get(name,"") or f"{disp} layout mapped onto the dome by geometry.")+"\n")
    if name in DESIGN_NOTE: L.append(f"> **Design note.** {DESIGN_NOTE[name]}\n")
    if is_stereo:
        L.append("## ⭐ Adjustable control — the L↔R angle\n")
        L.append("The single knob is **`angleBetweenLRDegrees`** (range **0–180°**, default **90°**): L sits at **−angle/2**, R at **+angle/2**, then each is panned onto the dome.\n")
        L.append("| angle | preset | what you hear | L → top dome speakers | R → top dome speakers |")
        L.append("|--:|---|---|---|---|")
        for p in STEREO_PRESETS:
            sc=stereo_channels(p["angleDeg"]); cc=columns(sc)
            l=", ".join(f"#{g[0]}@{SPH_AZ[sph_ids.index(g[0])]:+.0f}°" for g in cc[0]['gains'][:3])
            r=", ".join(f"#{g[0]}@{SPH_AZ[sph_ids.index(g[0])]:+.0f}°" for g in cc[1]['gains'][:3])
            L.append(f"| {p['angleDeg']}° | {p['name']} | {p['effect']} | {l} | {r} |")
        L.append("\nAt **0°** both columns are identical (mono); as the angle opens, L slides left and R slides right until they reach the hard sides at **180°**.\n")
    L.append("## Source geometry\n")
    L.append("| # | label | role | azimuth° | elev° | x | y | z | LFE |")
    L.append("|--:|---|---|--:|--:|--:|--:|--:|:--:|")
    for ch in channels:
        p=ch['position']
        L.append(f"| {ch['index']} | `{ch['label']}` | {ch['role']} | {ch['azimuthDeg']:.0f} | {ch['elevationDeg']:.0f} | {p['x']:.3f} | {p['y']:.3f} | {p['z']:.3f} | {'✓' if ch['lfe'] else ''} |")
    L.append("\n## How it's designed (the math)\n")
    L.append(ALGO["summary"]+"\n")
    L.append("```")
    L.append(f"w_i = max(0, d · ŝ_i) ^ p          p (cosineSharpness) = {SHARP}")
    L.append(f"clip w_i ≤ √cap, renormalize Σw_i²=1   cap = {CAP} (≤ {math.sqrt(CAP):.3f} amplitude), {CAP_ITERS} iters")
    L.append("LFE channels → sub (output 31) at unity")
    L.append("```\n")
    L.append("**What the adjustable parameters do:**\n")
    for k,v in PARAMS.items():
        val=v.get("value", v.get("output"))
        L.append(f"- **`{k}`** = `{val}` — {v['description']}")
    L.append(f"\nCoordinate convention: `+x` {CONV['x']}, `+y` {CONV['y']}, `+z` {CONV['z']}; azimuth 0° = front, + to the right.\n")
    L.append("## Resulting kernel (per channel → dome speakers)\n")
    L.append("| channel | role | dome speakers *(id @ azimuth : gain)* |")
    L.append("|---|---|---|")
    for col,ch in zip(cols,channels):
        if col.get('lfe'): L.append(f"| `{ch['label']}` | {ch['role']} | **→ SUB (output 31)** |"); continue
        L.append(f"| `{ch['label']}` | {ch['role']} | {top_cells(col)} |")
    L.append(f"\n## Reproducibility\n")
    L.append(f"- Kernel is fully regenerable from *source geometry + algorithm parameters* above" + (" (computed live from the angle for stereo)." if is_stereo else "."))
    L.append(f"- Machine-readable spec: [`{name}.renderer.json`](./{name}.renderer.json)")
    L.append(f"- `kernelSha256`: `{spec['checksums']['kernelSha256']}`")
    open(f"{d}/{name}.renderer.md","w").write("\n".join(L)+"\n")
    index.append((name,disp,fam,len(channels),lfe,is_stereo))

with open(f"{OUT}/README.md","w") as f:
    f.write("# Sonic Sphere Renderer Specs\n\nEach renderer is a reproducible bundle: source geometry + design math + helpful explanations + the resulting kernel, in machine-readable JSON and human-readable Markdown. See [`DESIGN.md`](./DESIGN.md) and the dome target [`sphere-fey-30.1.json`](./sphere-fey-30.1.json).\n\n")
    f.write("| Layout | Name | Family | ch | LFE | Notes | Spec |\n|---|---|---|--:|--:|---|---|\n")
    for name,disp,fam,n,lfe,st in index:
        note="⭐ parametric L↔R angle 0–180°" if st else ""
        f.write(f"| `{name}` | {disp} | {fam} | {n} | {lfe} | {note} | [json](./{name}/{name}.renderer.json) · [md](./{name}/{name}.renderer.md) |\n")
with open(f"{OUT}/DESIGN.md","w") as f:
    f.write(f"# Renderer design — cosine-power directional panning v{ALGO_VERSION}\n\n{ALGO['summary']}\n\n## Formula\n\n```\n{ALGO['formula']}\n```\n\n## Adjustable parameters\n\n")
    for k,v in PARAMS.items():
        val=v.get("value", v.get("output")); f.write(f"- **`{k}`** = `{val}` — {v['description']}\n")
    f.write(f"\n## Coordinate convention\n\n```json\n{json.dumps(CONV,indent=2)}\n```\n\nThe dome target (30 speakers + sub) is in [`sphere-fey-30.1.json`](./sphere-fey-30.1.json) (sha256 `{SPH_SHA}`).\n\n## Special: the Stereo renderer\n\n`stereo_2_0` is **parametric** — its only control is `angleBetweenLRDegrees` (0–180°, default 90°), the angle between L and R. L is placed at −angle/2 and R at +angle/2, then panned by the engine above. 0° = mono collapse, 60° = classic stereo, 90° = wide, 180° = hard-sides/enveloping. It codegens to a function of the angle rather than a static table.\n")
print(f"generated {len(index)} bundles; files:", sum(len(fs) for _,_,fs in os.walk(OUT)))
