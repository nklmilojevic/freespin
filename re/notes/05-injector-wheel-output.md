# 05 - Injector wheel output: applyHysteresis path of InjectScroll

Binary: `bin/logioptionsplus_agent.arm64` (agent v2.6.944893, arm64). Disassembly: `scratchpad/all_main.s` (otool -tV). Addresses are file VAs (0x1000xxxxx).

Tags: **[ASM]** read from arm64 instructions, address given. **[STR]** read from a CFString or log format literal. **[INF]** inferred from naming or from the SDK header. **[OPEN]** not resolved.

Scope: the wheel call only, `scrollphase=0, inertia=0, pageswipe=0, applyHysteresis=1`. Phase 1/2/4 and inertia != 0 paths are not modelled (the Swift model says so).

Files produced:
- This note.
- Swift reference model, embedded in section 9. The same code was compiled and smoke-tested with `swiftc` (Swift 6.4) in `scratchpad/re05/swift/`.

---

## 0. Corrections to the brief

1. **Wheel call site is in `-[wheel_mouse_handler postMouseWheel:horizontal:accelerate:scrollphase:pcount:pnum:timestamp:]` (0x101686d40), call at 0x101687374..0x10168739c [ASM].** Arguments: d0 = `d8`, d1 = `d9`, d2 = `d10`, d3 = `d11`, d4 = `d12 * additionalYFixedLineFactor()`. `x2 = x27` (= caller `scrollphase`, x27 = x5 at 0x101686d78), `w3 = 0` (inertia), `x4 = x21` (timestamp), `w5 = 0` (pageswipe), `w6 = 1` (applyHysteresis). Matches note 01.
2. **The injector factory call is in `-[wheel_mouse_handler init]` (0x101686430), at 0x10168649c, not in `initWithFilters`.** `initWithFilters` (0x1016864e4) only allocates three filter objects (ivars 0x18, 0x20, 0x28) and reads two floats (0x60 disturbanceTimeSetting, 0x64 stopTimeSetting) [ASM]. The `fmov` immediates for the injector are the ones in `init`.
3. **Injector instance for the wheel** is created once in `init` and receives only `setInjectFloatLineValues:` (0x101687334) [ASM]. `setNaturalScrolling:` is never called on it (section 6).
4. **`yFixedLineFactor` is not a constant 1.0 at runtime.** Its setter (0x1016879ec: `str d0,[x0,#0x68]`) is called from `logi::gestures::gestures::scroll(int,int,int,unsigned long long,double)` (0x1016706d0) [ASM]. Value domain is [OPEN].

---

## 1. Call-site arguments (postMouseWheel, 0x101687300..0x1016873a0) [ASM]

Let `w19 = (bit 17 of w22) | horizontal` where `w22` comes from a call at 0x1016872f4 (presumably `[NSEvent modifierFlags]`; bit 17 = Shift is [INF]) and `horizontal` = `w23`.

| Injector arg | vertical (w19 == 0) | horizontal (w19 != 0) | asm |
|---|---|---|---|
| X (d0) | 0 | -d13 (= -px) | 0x101687338..0x101687348 (fcsel d8) |
| Y (d1) | d13 (= px, signed) | 0 | 0x10168734c (fcsel d9) |
| XInches (d2) | 0 | \|d12\| | 0x101687350..0x101687354 (fcsel d10) |
| YInches (d3) | \|d12\| | 0 | 0x101687358 (fcsel d11) |
| yFixedLineFactor (d4) | `yFixedLineFactor()` * `additionalYFixedLineFactor()` | same | 0x101687360..0x101687370 |
| inject `scrollphase` | caller x27 (0 for onMouseWheel, per note 01) | | |
| inject `inertia` | 0 | | 0x10168738c |
| `timestamp` | x21 (not used by the wheel CGEvent, see 3.6) | | 0x101687390 |
| `pageswipe` | 0 | | 0x101687394 |
| `applyHysteresis` | 1 | | 0x101687398 |

`setInjectFloatLineValues:` is called with `w2 = (ivar 0x51 != 0) ? 1 : (ivar 0x50 != 0)` (0x101687310..0x101687328) [ASM]. Ivars 0x50/0x51 are the cached "Adobe under cursor" / "Adobe foreground" flags (from `determineAdobeReaderRunning`, call at 0x101687308).

`additionalYFixedLineFactor` (0x101687978) [ASM]:
```
if ivar51 != 0 { return 0.25 }            // 0x3FD0000000000000
return (ivar50 == 0) ? 1.0 : 0.25         // 1.0 = 0x3FF0000000000000
```
So the factor is 0.25 exactly when Adobe is foreground or under cursor, which is also when float-line values are on.

`yFixedLineFactor` getter (0x1016879e4) returns ivar 0x68 (double). Default is 1.0, set in `init` (0x1016864b8: `0x3FF0000000000000`) [ASM].

---

## 2. Pseudocode: wheel path of `-[injector InjectScrollX:Y:XInches:YInches:scrollphase:inertia:timestamp:pageswipe:applyHysteresis:yFixedLineFactor:]` (0x10167d920)

Names: `X,Y,XI,YI,F` = args d0,d1,d2,d3,d4. `flag` = byte. `H` = global hysteresis (0x1034c3a00). Ivars as in section 4.

```
zoom = fullScreenZoomModifierPressed()                    // 0x10167d868, 0x10167d8d4 (section 7)
flag = (zoom && ivar70 != 0) ? ivar71 : ivar20           // 0x10167d9d8..d9f4  [ASM]
xEff = (flag != 0) ? X : -X                              // d12, 0x10167d9f8..da00
yEff = (flag != 0) ? -Y : Y                              // d0,  0x10167da04..da08

// applyHysteresis branch, 0x10167da24 .. 0x10167db74
H.progressSecond(|XI| + |YI|)                            // 0x10167db58..db6c
if H.doingFirst { return DISCARD }                       // 0x10167db74..db78 -> 0x10167e0e8

// pending app swipe, 0x10167de00 .. 0x10167df14
if G9F9 == 1 { InjectAppSwipe(actiontime=ts, end=1, deliberateEnd=0, horizontal=G9FA, dx=dy=xIn=yIn=0) }  // 0x10167def0..df14
                                                          // (InjectAppSwipe clears G9F9, 0x10167ef40)

// phase gate, 0x10167e034 .. 0x10167e128   (phase 0, inertia 0)
// dead branch: G9FB==1 -> never true (section 8)
if G9FC != 0 { return DROP }                             // 0x10167e124..e128 -> log, return
G9FC = ((inertia - 1) <u 2) ? 1 : 0 = 0                  // 0x10167e604 (executed on the non-drop path)

// remainder carry (modf), 0x10167e38c .. 0x10167e3f0
tX = xEff + rem28;  intX = trunc(tX);  rem28 = tX - intX        // w22
tY = yEff + rem30;  intY = trunc(tY);  rem30 = tY - intY        // w24

// direction resets, 0x10167e608 .. 0x10167e678 and 0x10167e988 .. 0x10167e9ac
if lastDirX == 0 || ((lastDirX > 0) != (xEff >= 0)) { acc48 = 0; acc58 = 0 }   // 0x10167e634 path
lastDirX = (xEff < 0) ? -1 : +1                                                 // ivar38, 0x10167e64c
if lastDirY == 0 || ((lastDirY > 0) != (yEff >= 0)) { acc50 = 0; acc60 = 0 }   // 0x10167e65c path
lastDirY = (yEff < 0) ? -1 : +1                                                 // ivar40, 0x10167e678

// accumulate, 0x10167e67c .. 0x10167e6c8
acc48 += xEff;  acc50 += yEff;  acc58 += XI;  acc60 += YI

// flush, 0x10167e67c..0x10167e898
thr = zoom ? 0.005f : 0.06f                              // 0x10167e67c..e69c (fcsel s15)
lineXD = 0; lineYD = 0                                   // d11, d10
if intX != 0 && (XI >= 0.02 || acc58 > thr) { lineXD = acc48 / 10;  acc48 = 0; acc58 = 0 }  // 0x10167e808..e840
if intY != 0 && (YI >= 0.02 || acc60 > thr) { lineYD = acc50 / 10;  acc50 = 0; acc60 = 0 }  // 0x10167e854..e884

// integer line values (0x10167e898 .. 0x10167e8d8)
lineX = trunc(lineXD) != 0 ? trunc(lineXD) : (frac(lineXD) != 0 ? lastDirX : 0)   // d9
lineY = trunc(lineYD) != 0 ? trunc(lineYD) : (frac(lineYD) != 0 ? lastDirY : 0)   // d13

// fixed / point values
if ivar22 == 0 {                                         // rounded, 0x10167e9b0
    fixY = roundHalfAway(lineYD) * F                     // frinta, d8
    fixX = roundHalfAway(lineXD)                         // frinta, d10
    pt1  = intY
} else {                                                 // float, 0x10167e954
    fixY = yEff / 10                                     // d8
    fixX = xEff / 10                                     // d10
    s    = Double(intY) * F
    pt1  = (0 < s < 1) ? 1 : ((-1 < s < 0) ? -1 : trunc(s))   // 0x10167e9c0..e9d4
}
pt2 = intX

// CG event, 0x10167e8dc .. 0x10167eb9c
ev = CGEventCreateScrollWheelEvent(NULL, unit=0 /*kCGScrollEventUnitPixel*/, count=2, wheel1=intY, wheel2=intX)
if zoom            { set 55  = 28 }                      // 0x10167e900..e910
                     set 99  = (pageswipe != 0) ? phase : 0  = 0      // 0x10167e914..e928
                     set 123 = inertia = 0               // 0x10167e92c..e938
                     set 137 = flag                      // 0x10167e93c..e948
                     set 11  = trunc(lineY)              // 0x10167e9d8..e9e8
                     set 12  = trunc(lineX)              // 0x10167e9ec..e9fc
                     set 93  = trunc(fixY * 65536)       // 0x10167ea00..ea18
                     set 94  = trunc(fixX * 65536)       // 0x10167ea20..ea34
                     set 96  = pt1                       // 0x10167ea38..ea44
                     set 97  = pt2                       // 0x10167ea48..ea54
CGEventSetTimestamp(ev, upTimeInNanoseconds())           // 0x10167eb60..eb6c  (not the timestamp arg)
if ivar21 (silentPlayback) == 0 { CGEventPost(kCGHIDEventTap=0, ev) }   // 0x10167eb70..eb80
CFRelease(ev)                                            // 0x10167eb8c..eb9c
```

Logs confirm the semantics [STR]: `injecting SCROLL(y:%d, x:%d) LINE(y:%d, x:%d) FIXED(y:%f, x:%f) scrollphase=%d inertia=%d` at 0x10167ea80. Format argument order matches: SCROLL = (wheel1, wheel2), LINE = (field 11, field 12), FIXED = (fixY, fixX).

---

## 3. Per-field table (wheel path, final values)

### 3.1 CGEventCreateScrollWheelEvent (0x10167e8f0)

| Argument | Value | Note |
|---|---|---|
| source | NULL | `mov x0,#0` |
| units | 0 = kCGScrollEventUnitPixel | SDK CGEventTypes.h: `kCGScrollEventUnitPixel = 0` [ASM+SDK] |
| wheelCount | 2 | `mov w2,#2` |
| wheel1 (x3) | intY (w24 at call time) | pixel Y |
| wheel2 (stack) | intX (w22) | pixel X |

No `CGEventSetDoubleValueField`, no `CGEventSetFlags`, and no `CGEventSetIntegerValueField(88, ...)` call exists in this function [ASM, bl-list check]. Field 88 (kCGScrollWheelEventIsContinuous, SDK) is left at the CoreGraphics default.

### 3.2 CGEventSetIntegerValueField calls (in asm order)

| Field | SDK name | Value | Asm | Status |
|---|---|---|---|---|
| 55 | not in public SDK header | 28 (0x1c) only if `fullScreenZoomModifierPressed` | 0x10167e900..e910 | [ASM], meaning [OPEN] |
| 99 | kCGScrollWheelEventScrollPhase | `pageswipe ? phase : 0` = **0** | 0x10167e914..e928 | [ASM] (csel on w28) |
| 123 | kCGScrollWheelEventMomentumPhase | inertia = **0** | 0x10167e92c..e938 | [ASM] |
| 137 | not in public SDK header | natural flag byte = **0** (section 6) | 0x10167e944..e948 | [ASM], meaning [INF] |
| 11 | kCGScrollWheelEventDeltaAxis1 | trunc(lineY) | 0x10167e9e4 | [ASM] |
| 12 | kCGScrollWheelEventDeltaAxis2 | trunc(lineX) | 0x10167e9f8 | [ASM] |
| 93 | kCGScrollWheelEventFixedPtDeltaAxis1 | trunc(fixY * 65536) | 0x10167ea14 | [ASM] |
| 94 | kCGScrollWheelEventFixedPtDeltaAxis2 | trunc(fixX * 65536) | 0x10167ea34 | [ASM] |
| 96 | kCGScrollWheelEventPointDeltaAxis1 | pt1 | 0x10167ea44 | [ASM] |
| 97 | kCGScrollWheelEventPointDeltaAxis2 | intX | 0x10167ea54 | [ASM] |

SDK names and numbers come from `/Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk/.../CoreGraphics.framework/Versions/A/Headers/CGEventTypes.h` (11, 12, 93, 94, 96, 97, 99, 123, 88 confirmed; 14 is InstantMouser, so 55 and 137 are not that).

### 3.3 Other event calls

- `CGEventSetTimestamp(ev, upTimeInNanoseconds())` at 0x10167eb6c. The `timestamp` argument is overwritten by `x25 = ev` at 0x10167e8f4, so it is unused on this path [ASM].
- `CGEventPost(0 /*kCGHIDEventTap*/, ev)` at 0x10167eb80, gated by `ivar 0x21 == 0` (0x10167eb70) [ASM].
- `CGEventCreateData` / `CFRelease` at 0x10167eb8c..eb9c [ASM], cleanup only.

### 3.4 Wheel1 / wheel2 vs. fields 96 / 97

`wheel1` and `wheel2` are the pixel integers. Fields 96/97 are overwritten after creation, so for the rounded path (ivar 0x22 == 0) they equal `intY` / `intX`. For the float path, field 96 is the clamped `intY * F` (section 2). This is the only way the two can differ.

### 3.5 Hysteresis side effects on this path

- `H.progressSecond(|XI|+|YI|)` runs on every wheel event (section 4).
- `H.doingFirst` gates the event (discard).
- `G9F9` triggers `InjectAppSwipe(end)` before the event. That call's own side effects (it calls `H.endFirst` at 0x10167edd8 and 0x10167f198 on some branch) are not decoded [OPEN].

### 3.6 Timestamp

Only `upTimeInNanoseconds()` reaches the CGEvent [ASM]. The `timestamp` argument is used only for the `InjectAppSwipe(end)` / phase-4 forwarding calls (0x10167df08 and 0x10167e020).

---

## 4. hysteresis_switch (singleton at global 0x1034c3a00)

### 4.1 Ivars [ASM symbol table + offsets]

| ivar | off | meaning (from code) |
|---|---|---|
| `_first` | 0x08 | first-direction progress |
| `_second` | 0x10 | second-direction progress |
| `_lasttime` | 0x18 | mach_absolute_time ticks at last decay |
| `_active` | 0x20 | int32: 0 idle, 1 first wins, 2 second wins |
| `_ratio` | 0x28 | switch ratio |
| `_timeConstant` | 0x30 | decay time constant (seconds) |
| `_priorityRatio` | 0x38 | weight of first-direction progress |

### 4.2 Init (created by the first injector's `initWithUnit:` at 0x10167d56c..0x10167d594) [ASM]

```
if H == nil:
   H = [hysteresis_switch alloc] initWithRatio:2.0 timeConstant:0.3 priorityRatio:4.0
```
- `2.0` = 0x4000000000000000 (fmov #2.0 at 0x10167d588)
- `0.3` = 0x3FD3333333333333 (0x10167d57c..d580)
- `4.0` = 0x4010000000000000 (fmov #4.0 at 0x10167d58c)

Init at 0x10167ca04: `_ratio = d0`, `_timeConstant = d1`, `_priorityRatio = d2`, `_active`, `_first`, `_second`, `_lasttime` are zero from alloc.

### 4.3 Methods [ASM]

```
decay():                                          // 0x10167d174
    numer, denom = mach_timebase_info()
    secPerTick  = numer / (denom * 1e9)           // d8
    now         = mach_absolute_time()
    if now >= lasttime:                           // b.hs 0x10167d2fc
        dt = (now - lasttime) * secPerTick        // d8*d9
        lasttime = now
        f = exp(-dt / timeConstant)               // fnmul/fdiv/bl exp
        first  *= f;  second *= f                 // stp q0 multiply 0x10167d43c
    // else: no change

progressFirst(p):                                 // 0x10167ca60
    decay()
    first += p * priorityRatio                    // fmadd d0,d8,d0,d1 with d0=[0x38]
    if active != 1 && first >= ratio * second:    // 0x10167cb58..cb68
        active = 1                                // 0x10167cc58
    // else: log only

progressSecond(p):                                // 0x10167cdec
    decay()
    second += p                                   // no priorityRatio
    if active != 2 && second >= ratio * first:    // 0x10167ce20..ce28, ceec..cef0
        active = 2                                // 0x10167cfe4..cfe8

endFirst():  first = 0; if active == 1: active = 0    // 0x10167d4a4
endSecond(): second = 0; if active == 2: active = 0   // 0x10167d4bc (no call site in binary: [ASM])
doingFirst:  active == 1                              // 0x10167d4d4
doingSecond: active == 2                              // 0x10167d4e4
```

`progressFirst:` is called from `InjectAppSwipe...` at 0x10167ef28 [ASM]. `progressSecond:` is called from `InjectScroll` at 0x10167db6c [ASM]. `endSecond` has no call site [ASM].

---

## 5. Factory, init and handler constructors

### 5.1 `+[injector_factory newInjectorWithUnit:width:height:]` (0x101683964) [ASM]

```
major = packedOSVersion() >> 16
if major > 0x12:                 return [[injector_1300 alloc] initWithUnit:width:height:]   // class ref 0x103257138 -> _OBJC_CLASS_$_injector_1300
else if packedOSVersion() >= 0x101300:  return [[injector_1013 alloc] initWithUnit:...]     // class ref 0x103257140 -> _OBJC_CLASS_$_injector_1013
else: return nil
```

Neither subclass overrides `InjectScroll`. `injector_1012` overrides `initWithUnit:width:height:` (0x101680438) but is never returned by the factory [ASM]. The wheel path is therefore the base class code above in all cases.

### 5.2 `-[injector initWithUnit:width:height:]` (0x10167d4f4) [ASM]

- `unit` (0x08) = d0, `width` (0x10) = d1, `height` (0x18) = d2 (doubles).
- `injectFloatLineValues` (0x22) = 0.
- `fullScreenZoomLockDirection` (0x70) and `fullScreenZoomLockedDirection` (0x71) = 0 (`strh wzr`).
- 0x28..0x68 zero (`scrollRemainder*`, `*LastDir`, four accumulators).
- Creates the hysteresis global if nil (section 4.2).

### 5.3 `-[wheel_mouse_handler init]` (0x101686430) [ASM]

Creates the wheel injector at 0x10168649c:

```
injector = [injector_factory newInjectorWithUnit:3.0 width:3.0 height:3.0]     // fmov d0/d1/d2 = 3.0 (0x101686490..98)
```

Other fields written:
- screenDPI (0x5c, int32) = 100 (0x64).
- accelerate (0x52) = 1; horizontalOnly (0x53) = 0; forceWheelDisturbanceFilter (0x54) = 0.
- naturalScroll (0x30) = 0.
- scrollingSpeed (0x38, double) = 0.5 (0x3FE0000000000000).
- wheelMultiplier (0x58, int32) = 1.
- yFixedLineFactor (0x68, double) = 1.0 (0x3FF0000000000000).
- lastScrollTimePoint (0x48) = system_clock::now().
- Adobe caches (0x50, 0x51) = 0; adobeAcrobatHelper (0x08) = alloc_init (class ref 0x150).

### 5.4 `-[wheel_mouse_handler initWithFilters]` (0x1016864e4) [ASM]

Allocates filter objects into 0x18 / 0x20 / 0x28 (class refs 0x158 / 0x160 / 0x168), stores `disturbanceTimeSetting` (float, 0x60) and `stopTimeSetting` (float, 0x64). No `fmov` immediates and no injector.

---

## 6. Natural-scrolling flag (field 137) [ASM]

- The flag byte is `flag = (zoomPressed && ivar70 != 0) ? ivar71 : ivar20` (0x10167d9d8..d9f4). It is stored as a full byte (`str x8,[sp,#0x48]`, field 137 at 0x10167e944) and it also drives the sign flip (section 2).
- **ivar 0x20** (`natural`) is written only by `-[injector setNaturalScrolling:]` (0x10167d5b4, `strb w2,[x0,#0x20]`). Its callers are the touchpad gesture inits, not the wheel: `-[gesture_handler_2_finger_scroll_touchpad initWithUnit:...]` (0x1016629bc) and `-[touchpad_gesture_base_implementation initWithUnit:...]` (0x101684728). The wheel injector never receives this call, so **0x20 stays 0** [ASM for callers, INF for "never on wheel"].
- **ivars 0x70/0x71** are written only by `-[injector setFullScreenZoomLock:withNaturalDirection:]` (0x1016803f0). Its only caller is `-[gesture_handler_2_finger_scroll_touchpad setScrollNatural:]` (tail call at 0x101662cb8), again not the wheel injector.

Consequence for the wheel: `flag = 0`, so **field 137 = 0**, `xEff = -X` and `yEff = +Y`. The natural-scrolling reversal for the mouse wheel must therefore happen before the call (for example in `postMouseWheel` via `naturalScroll` ivar 0x30 or the sign of d8/d9, [OPEN]).

Zoom-lock: `fullScreenZoomModifierPressed` (0x10167d868) returns true only when the pref `closeViewScrollWheelToggle` (ivar 0x6a) is set and the modifier combination matches the int pref `closeViewScrollWheelModifiersInt` (ivar 0x6c, default 0x40000 when the key is absent) exactly:
- mask 0x40000 (Control): Control and not Shift (0x20000), Option (0x80000), Command (0x100000), Fn (0x800000).
- mask 0x80000 (Option): Option and not Shift, Control, Command, Fn.
- mask 0x100000 (Command): Command and not Shift, Option, Control, Fn.
- any other mask: false.

---

## 7. Constants (hex and decimal)

| Value | Meaning | Where |
|---|---|---|
| 0x3F947AE147AE147B = 0.02 | inch threshold for flushing | 0x10167e810, 0x10167e858 |
| 0x3D75C28F (float) = 0.06 | flush threshold on accumulated inches (not zoom) | 0x10167e67c..e690 (`s0`) |
| 0x3BA3D70A (float) = 0.005 | same, when zoom modifier pressed | 0x10167e694..e698 (`s1`) |
| 10.0 | pixels per line divisor | 0x10167e844, 0x10167e888, 0x10167e958, 0x10167e95c |
| 65536.0 = 0x40F0000000000000 | 16.16 fixed-point scale | 0x10167ea00 |
| 28 = 0x1c | field 55 value when zoom | 0x10167e90c |
| 0x40000 = 262144 | default `closeViewScrollWheelModifiersInt` (Control) | 0x10167d9c4 |
| 0x20000 / 0x40000 / 0x80000 / 0x100000 / 0x800000 | NSEvent modifier bits Shift / Control / Option / Command / Fn | 0x10167d890..d8b8 |
| 0 | kCGScrollEventUnitPixel, kCGHIDEventTap | 0x10167e8e0, 0x10167eb78 |
| 2 | wheelCount | 0x10167e8e8 |
| 0.5 | scrollingSpeed default | 0x1016864a8 |
| 0.25 / 1.0 | additionalYFixedLineFactor | 0x10168797c, 0x101687994 |
| 0.3 = 0x3FD3333333333333 | hysteresis timeConstant | 0x10167d580 |
| 2.0 | hysteresis ratio | 0x10167d588 |
| 4.0 | hysteresis priorityRatio | 0x10167d58c |
| 3.0 | wheel injector unit/width/height | 0x101686490..98 |
| 100 | screenDPI default | 0x101686464 |

CFString keys [STR]: bool `closeViewScrollWheelToggle` (domain `com.apple.universalaccess`) -> ivar 0x6a; int `closeViewScrollWheelModifiersInt` -> ivar 0x6c. Both are read on every `InjectScroll` call (0x10167d98c..d9c0, 0x10167e33c..e388).

---

## 8. Merged globals (page 0x1034c3000) [ASM]

| Address | Name (inferred) | Writes | Reads |
|---|---|---|---|
| 0x1034c39f8 | frame flag | frameStart (0x10167d5fc) clears; InjectEventType (0x10167d72c) sets | frameEndTime (0x10167d614) |
| 0x1034c39f9 | G9F9 `appSwipeActive` | InjectAppSwipe sets 1 (0x10167f4f4), clears (0x10167ef40) | InjectScroll 0x10167de04; InjectAppSwipe |
| 0x1034c39fa | G9FA `appSwipeHorizontal` | InjectAppSwipe stores w21 (0x10167f4f8) | InjectScroll 0x10167def0 |
| 0x1034c39fb | G9FB (dead flag) | InjectScroll clears to 0 (0x10167e5f4) only | InjectScroll 0x10167dc2c, 0x10167dd18, 0x10167e0f8, 0x10167e10c |
| 0x1034c39fc | G9FC `phaseGate` | InjectScroll writes `(inertia-1) <u 2` (0x10167e604) | InjectScroll 0x10167e124 (gate) |
| 0x1034c3a00 | H (hysteresis singleton) | initWithUnit (only if nil) | InjectScroll, InjectAppSwipe |

G9FB: no store of a non-zero value to 0x1034c39fb exists in the binary; the only store to it is the zero store at 0x10167e5f4. The `G9FB == 1` branches (0x10167dc2c, 0x10167dd18, 0x10167df1c, 0x10167e10c) are dead in this binary [INF, from exhaustive xref of the page]. The Swift model therefore omits them.

G9FC: written by the phase-0/4 path on every call that passes the gate: `value = ((inertia - 1) <u 2)`. Inertia values 1 or 2 set it to 1. The wheel call (inertia 0) then **returns early every time G9FC is 1**, and it clears G9FC to 0 only when it does get past the gate. Only an inertia >= 3 call (or a phase-4 call) clears it while the gate is up. Whether the touchpad momentum path ever leaves G9FC at 1 is [OPEN].

---

## 9. Swift reference model

File: `scratchpad/re05/swift/WheelInjectorMath.swift` (compiled with `swiftc -O`, smoke test in `main.swift`). It is self-contained (imports Foundation only). The code below is the same file.

```swift
import Foundation

// Reference model of -[injector InjectScrollX:Y:XInches:YInches:scrollphase:inertia:timestamp:pageswipe:applyHysteresis:yFixedLineFactor:]
// (Logi Options+ agent v2.6.944893, arm64, 0x10167d920) for the mouse-wheel call made from
// -[wheel_mouse_handler postMouseWheel:...] (0x101687374):
//   scrollphase = caller value (0 for onMouseWheel), inertia = 0, pageswipe = 0, applyHysteresis = 1.
// Only that path is modelled. Phase 1/2/4 and inertia != 0 paths are intentionally not modelled.
// Ivar offsets are from _OBJC_IVAR_$_injector.*; global addresses are the merged globals page 0x1034c39f8.

// MARK: - Hysteresis (hysteresis_switch, singleton at 0x1034c3a00)

struct HysteresisSwitch {
    var ratio: Double = 2.0            // initWithRatio:timeConstant:priorityRatio: from injector init (d0)
    var timeConstant: Double = 0.3     // seconds (d1 = 0x3FD3333333333333)
    var priorityRatio: Double = 4.0    // (d2)
    var first: Double = 0              // ivar 0x08
    var second: Double = 0             // ivar 0x10
    var lastTime: UInt64 = 0           // ivar 0x18, mach_absolute_time ticks
    var active: Int32 = 0              // ivar 0x20: 0 idle, 1 = first wins, 2 = second wins

    /// secondsPerTick = Double(timebase.numer) / (Double(timebase.denom) * 1e9)
    mutating func decay(now: UInt64, secondsPerTick: Double) {
        guard now >= lastTime else { return }
        let dt = Double(now - lastTime) * secondsPerTick
        let f = exp(-dt / timeConstant)
        first *= f
        second *= f
        lastTime = now
    }

    mutating func progressFirst(_ p: Double, now: UInt64, secondsPerTick: Double) {
        decay(now: now, secondsPerTick: secondsPerTick)
        first += p * priorityRatio
        if active != 1 && first >= ratio * second { active = 1 }
    }

    mutating func progressSecond(_ p: Double, now: UInt64, secondsPerTick: Double) {
        decay(now: now, secondsPerTick: secondsPerTick)
        second += p
        if active != 2 && second >= ratio * first { active = 2 }
    }

    mutating func endFirst() {
        first = 0
        if active == 1 { active = 0 }
    }

    mutating func endSecond() {
        second = 0
        if active == 2 { active = 0 }
    }

    var doingFirst: Bool { active == 1 }
    var doingSecond: Bool { active == 2 }
}

// MARK: - Injector state (wheel injector instance) plus merged globals used by InjectScroll

struct WheelInjectorState {
    var naturalFlag: UInt8 = 0            // ivar 0x20 (setNaturalScrolling:). Never set on the wheel injector.
    var zoomLockActive: UInt8 = 0         // ivar 0x70 (setFullScreenZoomLock:withNaturalDirection:)
    var zoomLockNaturalFlag: UInt8 = 0    // ivar 0x71
    var silentPlayback: Bool = false      // ivar 0x21: when non-zero the event is created but not posted
    var floatLineValues: Bool = false     // ivar 0x22 (setInjectFloatLineValues:, Adobe-related)
    var remainderX: Double = 0            // ivar 0x28 scrollRemainderX
    var remainderY: Double = 0            // ivar 0x30 scrollRemainderY
    var lastDirX: Double = 0              // ivar 0x38 scrollXLastDir (+1 / -1 / 0)
    var lastDirY: Double = 0              // ivar 0x40 scrollYLastDir
    var accPxX: Double = 0                // ivar 0x48 scrollXAccumulatedPixelMotion
    var accPxY: Double = 0                // ivar 0x50 scrollYAccumulatedPixelMotion
    var accInX: Double = 0                // ivar 0x58 scrollXAccumulatedWheelInches
    var accInY: Double = 0                // ivar 0x60 scrollYAccumulatedWheelInches
    // Merged globals (0x1034c39f8 page)
    var appSwipeActive: Bool = false      // 0x1034c39f9, set by InjectAppSwipe
    var appSwipeHorizontal: UInt8 = 0     // 0x1034c39fa, set by InjectAppSwipe
    var phaseGate: UInt8 = 0              // 0x1034c39fc, written from the phase-0/4 path

    init() {}
}

// MARK: - Output

struct WheelEvent: Equatable {
    // CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel=0, 2, wheel1, wheel2)
    var wheel1: Int32                 // pixel Y (intY)
    var wheel2: Int32                 // pixel X (intX)
    // CGEventSetIntegerValueField values after creation
    var field11DeltaAxis1: Int32      // line Y
    var field12DeltaAxis2: Int32      // line X
    var field93FixedAxis1: Int32      // Y, 16.16 fixed
    var field94FixedAxis2: Int32      // X, 16.16 fixed
    var field96PointAxis1: Int32      // Y point delta
    var field97PointAxis2: Int32      // X point delta
    var field99ScrollPhase: Int32     // pageswipe ? phase : 0  -> 0 on this path
    var field123MomentumPhase: Int32  // inertia -> 0 on this path
    var field137Natural: Int32        // natural flag byte (0x20 or 0x71)
    var field55: Int32?               // 28 only when fullScreenZoomModifierPressed
}

enum WheelOutcome: Equatable {
    case posted(WheelEvent)            // CGEventPost(kCGHIDEventTap = 0, ...)
    case createdOnly(WheelEvent)       // silentPlayback != 0: created, not posted
    case discardedByHysteresis         // hysteresis.doingFirst == true; progressSecond still applied
    case droppedByPhaseGate            // 0x1034c39fc != 0 at entry; nothing injected, state unchanged
}

struct WheelInjectionResult: Equatable {
    var outcome: WheelOutcome
    /// Non-nil when the InjectAppSwipe(end:1, deliberateEnd:0, horizontal:, all deltas 0) call is issued
    /// before the wheel event (value = horizontal byte at 0x1034c39fa).
    var appSwipeEndHorizontal: UInt8?
}

// MARK: - Helpers (ARM64 instruction semantics)

/// FCVTZS (32-bit): truncate toward zero, saturate, NaN -> 0.
@inline(__always)
func fcvtzs(_ d: Double) -> Int32 {
    if d.isNaN { return 0 }
    if d >= 2147483647.0 { return Int32.max }
    if d <= -2147483648.0 { return Int32.min }
    return Int32(d.rounded(.towardZero))
}

/// -[injector fullScreenZoomModifierPressed] @ 0x10167d868.
/// toggle = CFPreferences closeViewScrollWheelToggle (com.apple.universalaccess), ivar 0x6a.
/// modifierMask = closeViewScrollWheelModifiersInt, ivar 0x6c (default 0x40000 = Control when key absent).
/// flags = raw [NSEvent modifierFlags].
func fullScreenZoomModifierPressed(toggle: Bool, modifierMask: Int32, flags: UInt64) -> Bool {
    guard toggle else { return false }
    let shift = flags & 0x20000 != 0
    let control = flags & 0x40000 != 0
    let option = flags & 0x80000 != 0
    let command = flags & 0x100000 != 0
    let fn = flags & 0x800000 != 0
    switch UInt32(bitPattern: modifierMask) {
    case 0x40000:  return control && !shift && !option && !command && !fn
    case 0x80000:  return option && !shift && !control && !command && !fn
    case 0x100000: return command && !shift && !option && !control && !fn
    default:       return false
    }
}

// MARK: - Wheel path

/// Pure model of InjectScroll for scrollphase=0, inertia=0, pageswipe=0, applyHysteresis=1.
///
/// Inputs as passed by postMouseWheel (0x101687374):
///   vertical:   x = 0,      y = px (signed), xInches = 0,      yInches = |raw inches|
///   horizontal: x = -px,    y = 0,           xInches = |raw|,  yInches = 0
///   yFixedLineFactor = yFixedLineFactor (ivar 0x68, default 1.0) * additionalYFixedLineFactor (0.25 if Adobe, else 1.0)
/// `now` / `secondsPerTick` are mach_absolute_time and the mach timebase ratio (decay uses the same clock).
func injectWheelScroll(
    x: Double,
    y: Double,
    xInches: Double,
    yInches: Double,
    yFixedLineFactor: Double,
    zoomPressed: Bool,
    now: UInt64,
    secondsPerTick: Double,
    injector s: inout WheelInjectorState,
    hysteresis h: inout HysteresisSwitch
) -> WheelInjectionResult {
    // 1. applyHysteresis branch (0x10167da24 .. 0x10167db74)
    h.progressSecond(abs(xInches) + abs(yInches), now: now, secondsPerTick: secondsPerTick)
    if h.doingFirst {
        return WheelInjectionResult(outcome: .discardedByHysteresis, appSwipeEndHorizontal: nil)
    }

    // 2. pending app swipe is ended before the wheel event (0x10167de00 .. 0x10167df14)
    var appSwipeEnd: UInt8? = nil
    if s.appSwipeActive {
        appSwipeEnd = s.appSwipeHorizontal
        s.appSwipeActive = false
    }

    // 3. phase gate (0x10167e10c .. 0x10167e128). Dead G_9FB branch omitted (never set to 1 in binary).
    if s.phaseGate != 0 {
        return WheelInjectionResult(outcome: .droppedByPhaseGate, appSwipeEndHorizontal: appSwipeEnd)
    }
    // inertia == 0 -> (inertia - 1) <u 2 is false, so the gate is cleared (0x10167e5f4 .. 0x10167e604)
    s.phaseGate = 0

    // 4. natural flag byte and sign of the deltas (0x10167d9d8 .. 0x10167da0c)
    let flag: UInt8 = (zoomPressed && s.zoomLockActive != 0) ? s.zoomLockNaturalFlag : s.naturalFlag
    let xEff = flag != 0 ? x : -x
    let yEff = flag != 0 ? -y : y

    // 5. integer pixel parts with remainder carry (modf), phase 0 keeps the remainders (0x10167e38c .. 0x10167e3f0)
    let tX = xEff + s.remainderX
    let intXD = tX.rounded(.towardZero)
    s.remainderX = tX - intXD
    let tY = yEff + s.remainderY
    let intYD = tY.rounded(.towardZero)
    s.remainderY = tY - intYD
    let intX = fcvtzs(intXD)   // wheel2 / point2
    let intY = fcvtzs(intYD)   // wheel1 / point1

    // 6. direction change resets (0x10167e608 .. 0x10167e6a4, 0x10167e988 .. 0x10167e9a8)
    let prevDirX = s.lastDirX
    if prevDirX == 0 || ((prevDirX > 0) != (xEff >= 0)) {
        s.accPxX = 0
        s.accInX = 0
    }
    let dirX: Double = xEff < 0 ? -1 : 1
    s.lastDirX = dirX

    let prevDirY = s.lastDirY
    if prevDirY == 0 || ((prevDirY > 0) != (yEff >= 0)) {
        s.accPxY = 0
        s.accInY = 0
    }
    let dirY: Double = yEff < 0 ? -1 : 1
    s.lastDirY = dirY

    // 7. accumulate (0x10167e6a4 .. 0x10167e6c8)
    s.accPxX += xEff
    s.accPxY += yEff
    s.accInX += xInches
    s.accInY += yInches

    // 8. flush thresholds: 0.02 in (raw), else accumulated inches > 0.06f (0.005f if zoom modifier)
    let thr = Double(zoomPressed ? Float(0.005) : Float(0.06))
    var lineXD = 0.0   // d11, pixel-accumulator / 10 (10 px per line)
    if intX != 0 && (xInches >= 0.02 || s.accInX > thr) {
        lineXD = s.accPxX / 10.0
        s.accPxX = 0
        s.accInX = 0
    }
    var lineYD = 0.0   // d10
    if intY != 0 && (yInches >= 0.02 || s.accInY > thr) {
        lineYD = s.accPxY / 10.0
        s.accPxY = 0
        s.accInY = 0
    }

    // 9. integer line values; a sub-line remainder yields one line in the current direction
    let lx = lineXD.rounded(.towardZero)
    let lineX: Double = lx != 0 ? lx : ((lineXD - lx) != 0 ? dirX : 0)
    let ly = lineYD.rounded(.towardZero)
    let lineY: Double = ly != 0 ? ly : ((lineYD - ly) != 0 ? dirY : 0)

    // 10. fixed / point values
    var fixed1: Double      // d8 before *65536
    var fixed2: Double      // d10 before *65536
    var point1: Int32
    let point2: Int32 = intX
    if !s.floatLineValues {
        // rounded path (0x10167e9b0)
        fixed1 = lineYD.rounded(.toNearestOrAwayFromZero) * yFixedLineFactor
        fixed2 = lineXD.rounded(.toNearestOrAwayFromZero)
        point1 = intY
    } else {
        // float path (0x10167e954)
        fixed1 = yEff / 10.0
        fixed2 = xEff / 10.0
        let sc = Double(intY) * yFixedLineFactor
        if sc > 0 && sc < 1 {
            point1 = 1
        } else if sc > -1 && sc < 0 {
            point1 = -1
        } else {
            point1 = fcvtzs(sc)
        }
    }

    let event = WheelEvent(
        wheel1: intY,
        wheel2: intX,
        field11DeltaAxis1: fcvtzs(lineY),
        field12DeltaAxis2: fcvtzs(lineX),
        field93FixedAxis1: fcvtzs(fixed1 * 65536.0),
        field94FixedAxis2: fcvtzs(fixed2 * 65536.0),
        field96PointAxis1: point1,
        field97PointAxis2: point2,
        field99ScrollPhase: 0,
        field123MomentumPhase: 0,
        field137Natural: Int32(flag),
        field55: zoomPressed ? 28 : nil
    )

    // 11. timestamp = upTimeInNanoseconds() (caller timestamp is not used here); post unless silentPlayback
    let outcome: WheelOutcome = s.silentPlayback ? .createdOnly(event) : .posted(event)
    return WheelInjectionResult(outcome: outcome, appSwipeEndHorizontal: appSwipeEnd)
}
```

Smoke test outputs (checked by hand):
- `y=120, yIn=0.1`: wheel1 = 120, line Y = 12, fixed Y = 786432 (12 * 65536), point Y = 120.
- `y=7.5, yIn=0.01` (next event): wheel1 = 7, line Y = 0 (acc 7.5 < thr, yIn < 0.02).
- `x=-30, xIn=0.03` (horizontal): wheel2 = 30, line X = 3, fixed X = 196608.
- Adobe float path, `y=-3, F=0.25`: wheel1 = -2, point Y = -1 (clamp), fixed Y = -19660.

---

## 10. Open items

1. **Field 55 and field 137 meanings.** Neither is in the public CoreGraphics header on this machine. Names are inferred from the code only [INF].
2. **`yFixedLineFactor` runtime value.** Setter called from `logi::gestures::gestures::scroll` (0x1016706d0) with `d8`. The domain of that `d8` is not decoded.
3. **`H.progressFirst` and the `InjectAppSwipe(end)` side effects.** `InjectAppSwipe` calls `H.endFirst` (0x10167edd8, 0x10167f198) and `H.progressFirst` (0x10167ef28). The branch conditions were not decoded.
4. **G9FC stickiness.** Can a touchpad momentum call (inertia 1/2) leave G9FC = 1 indefinitely and drop every later wheel event? Needs a runtime check or decode of the touchpad inertia callers.
5. **Natural reversal for the wheel.** Field 137 is always 0 for the wheel injector. Where the wheel's natural direction is applied (postMouseWheel, `naturalScroll` ivar 0x30 path) was not decoded in this task.
6. **Modifier word `w22`.** The Shift-bit (bit 17) assumption in section 1 comes from the `ubfx #17` on the value returned by a call at 0x1016872f4 [INF].
7. **Field 88 (IsContinuous).** The injector does not set it. The default that `CGEventCreateScrollWheelEvent` gives it is not verified.
8. **Phase-1/2/4 and inertia != 0 paths** (the 0x10167dc44..e32c region) are not modelled.
9. **Shared hysteresis.** `H` is one process-wide object created by whichever injector is initialised first. Other injector instances share its state (including `progressFirst` from touchpad swipes). Any faithful Swift port must share it the same way.
