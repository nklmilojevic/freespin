# 01 - Wheel input to filtered/accelerated scroll amount (Logi Options+ agent 2.6.944893, arm64)

Scope: wheel_mouse_handler and its helpers (wheel_hysteresis, wheel_ratchet_detect, wheel_disturbance_filter), gesture_scroll_helper, adobe_acrobat_helper, and the hand-off into injector InjectScroll.

## Evidence and method

- Primary source is arm64 disassembly from `otool -arch arm64 -tV -p`, run per symbol (scratch helper `dis.py`). Ivar offsets come from the `_OBJC_IVAR_$` symbols (read from `__objc_ivar`). Double constants were decoded from their 64-bit immediates with python `struct`.
- Hopper pseudocode in `decomp/scroll/*.m` was used only as a cross-check. It mis-tracks ivar offsets and some constants. Log boilerplate (spdlog, backtracer) was ignored.
- Confidence labels: **A** = read directly from asm, with constants decoded. **B** = asm read, but some branches or arguments not fully traced. **C** = inferred from names or Hopper only.
- Address notation: `0x1016xxxx` is the method start, from `bin/symbols.txt`.
- Objective-C ivar offsets are byte offsets from the object base. `int`, `bool`, `float` and `double` types are taken from how the asm uses each slot.

## 1. Data-flow diagram

```
HID wheel report (period count P, deltaV, deltaH, timestamp ts)  [caller: see section 6]
  |
  v
wheel_mouse_handler -onMouseWheelWithPeriod:deltaV:deltaH:timestamp:   0x101686a28  [A]
  - horizontalOnly := (dV==0 && dH!=0)  ; if so dV := dH
  - sign := naturalScroll ? -1 : +1
  - for i in 0..<P:  dV := dV*sign ; postMouseWheel(dV, 0, accelerate, 0, P, i, ts)   <-- see 2.1 BUG NOTE
  |
  v
-postMouseWheel:horizontal:accelerate:scrollphase:pcount:pnum:timestamp:  0x101686d40  [A/B]
  1. dt_total = (ts - G_last)/1e9 (s), G_last = static at 0x1034c3a88
  2. d11 = dt_total / N  (N = max(1,P))  -- per-sub-period time
  3. dt  = clamp(d11, 0.008, 0.1) (s);  (d11>=0.1 also zeroes G_smooth)
  4. unit := 1 / (max(1,W) * 54/7)       W = wheelMultiplier
  5. if pnum == N-1: G_last = ts
  6. raw_in := unit * V                  (V = stepsV, signed, pre-filter)
  7. ratchet.ratchetSteps(V)             (state update; return value discarded in this path)  [B]
  8. V := hysteresis.filterWheelMotion(V)                       (if hysteresis)
  9. V := disturbance.filterWheelMotion(V, periodCount:N)       (if freewheelMode || W>1 || forceDisturbance)
 10. v_ips := (unit*V)/dt                                       (signed inches/s)
 11. G_smooth := 0.95*G_smooth + 0.05*|v_ips|  (global 0x1034c3a80)
 12. s_ips := screenIPSFromFingerIPS(v_ips, smoothed: G_smooth)    <-- acceleration curve, section 3
 13. px := dt * (screenDPI * s_ips)                              (signed pixels)
 14. shift/horizontalOnly flag -> choose axis, inject:
       injector InjectScrollX:Y:XInches:YInches:...yFixedLineFactor:  (0x10167d920)  <-- hand-off, section 5
```

## 2. Classes

### 2.0 Constants used by the pipeline (decoded)

| Name | Address | Raw hex | Decimal | Used in | Conf |
|---|---|---|---|---|---|
| ns per s | 0x101686ee8 literal | 0x41cdcd6500000000 | 1e9 | elapsed time | A |
| K (steps per unit) | 0x1016870b4 | 0x401edb6db6db6db7 | 54/7 = 7.714285714285714 | unit = 1/(W*K) | A |
| dt min | 0x101687034 | 0x3f80624dd2f1a9fc | 0.008 s | clamp of dt | A |
| dt max / reset dt | 0x101687058 | 0x3fb999999999999a | 0.1 s | clamp, initial dt on first event | A |
| G_smooth decay | 0x101687184 | 0x3fee666666666666 | 0.95 | smoothing | A |
| G_smooth gain | 0x101687170 | 0x3fa99999999999a0 | ~0.05 (0.050000000000000044) | smoothing | A |
| curve table divisor (not used) | - | - | - | - | - |
| atan scale (gesture helper) | 0x10166aa18 | 0x40189175a84dbc76 | 6.14205039 | gesture_scroll_helper | A |
| pi-like divisor (gesture helper) | 0x10166aa34 | 0x400921fb60000000 | 3.1415927410125732 | gesture_scroll_helper | A |

Note on the 0.05 constant: the movk chain yields 0x3fa99999999999a0 (not 0x...9a). The value is 0.05 to about 1e-16. Treat it as 0.05.

### 2.1 wheel_mouse_handler

**State (ivars; offsets from `_OBJC_IVAR_$` symbols; init values from `-init` 0x101686430 and `-initWithFilters` 0x1016864e4)**

| Offset | Name | Type | Init | Notes | Conf |
|---|---|---|---|---|---|
| 8 | _adobeAcrobatHelper | id | new adobe_acrobat_helper | | A |
| 16 | _injector | id | newInjectorWithUnit:width:height: (args see 5) | | A/B |
| 24 | _hysteresis | id (wheel_hysteresis) | new (initWithFilters) | | A |
| 32 | _ratchetDetect | id (wheel_ratchet_detect) | new | | A |
| 40 | _disturbanceFilter | id (wheel_disturbance_filter) | new | | A |
| 48 | _naturalScroll | BOOL | 0 | set by setNaturalScroll: | A |
| 56 | _scrollingSpeed | double | 0.5 | setScrollingSpeed: stores d0 | A |
| 64 | _freewheel | (unused in this class) | - | | C |
| 68 | _multiplier | int | (not set) | no accessor use seen | C |
| 72 | _lastScrollTimePoint | time point | now() | | A |
| 80 | _isAdobeAcrobatUnderMouseCursorCached | BOOL | 0 | | A |
| 81 | _isAdobeAcrobatRunningForegroundCached | BOOL | 0 | | A |
| 82 | _accelerate | BOOL | 1 | setAccelerate: strb w2 | A |
| 83 | _horizontalOnly | BOOL | 0 | set inside onMouseWheel | A |
| 84 | _forceWheelDisturbanceFilter | BOOL | 0 | | A |
| 85 | _freewheelMode | BOOL | (not set) | setFreewheelMode: strb, forwards to hysteresis | A |
| 88 | _wheelMultiplier | int | 1 | setWheelMultiplier: forwards to hysteresis, readPreferences, ratchet | A |
| 92 | _screenDPI | int | 100 | setScreenDPI: str w2 | A |
| 96 | _wheelDisturbanceTimeout | float | (from disturbance) | | B |
| 100 | _wheelStopTime | float | (from disturbance) | setWheelStopTime: stores s0, forwards (double) to disturbance.setStopTimeSetting: | A |
| 104 | _yFixedLineFactor | double | 1.0 | setYFixedLineFactor: str d0 | A |

initWithFilters (0x1016864e4) creates hysteresis, ratchet and disturbance filter, then sets `wheelDisturbanceTimeout = (float) disturbance.disturbanceTimeSetting` (ivar 96) and `wheelStopTime = (float) disturbance.stopTimeSetting` (ivar 100). Defaults in the disturbance filter give 0.15 and 0.1 (see 2.4). Confidence A.

**Setters/getters (all A, 0x1016879xx and 0x1016869xx/0x101686c94 region)**
- `setScreenDPI:` (0x1016879a8): `str w2,[self+92]`.
- `setAccelerate:` (0x1016879bc): `strb w2,[self+82]`.
- `setYFixedLineFactor:` (0x1016879ec): `str d0,[self+104]`.
- `setNaturalScroll:` (0x101687700): `strb w2,[self+48]`.
- `setScrollingSpeed:` (0x10168772c): `str d8,[self+56]` (plus logging). No forwarding.
- `setHorizontalOnly:` (0x1016879cc), `setForceWheelDisturbanceFilter:` (0x1016879dc): strb to 83 and 84.
- `setWheelMultiplier:` (0x101686c94): `str w2,[self+88]`; `[hysteresis setWheelMultiplier:]`; `[hysteresis readPreferences]`; `[ratchet setWheelMultiplier:]`.
- `setFreewheelMode:` (0x101686cf4): `strb w2,[self+85]`; `[hysteresis setFreewheelMode:]`.
- `setWheelStopTime:` (0x1016869d4): `str s8,[self+100]`; `[disturbance setStopTimeSetting: (double)s]`.
- `setWheelDisturbanceTimeout:` (0x101686980): analogous to stop time, writes ivar 96; not read in detail (B).

**-onMouseWheelWithPeriod:deltaV:deltaH:timestamp:** (0x101686a28, A)
- Arg types: period P is int (w21), deltaV and deltaH are int32 (w22, w24, used with 32-bit ops; the log format string says %f but the code does not), timestamp is 64-bit unsigned (x20).
- Algorithm:
```
lock(self)
setHorizontalOnly(NO)
if dV == 0 and dH != 0:  setHorizontalOnly(YES); dV = dH       // asm 0x101686a7c..a90
sign = naturalScroll ? -1 : +1                                 // cneg w27 on [self+48]
if P != 0:                                                     // cbz w21 at 0x101686b94
  for i in 0..<P:
     dV = dV * sign                                            // mul w22,w22,w27 is INSIDE the loop (0x101686b9c)
     postMouseWheel(stepsV=dV, stepsH=0, accelerate=self.accelerate,
                    scrollphase=0, pcount=P, pnum=i, timestamp=ts)
unlock(self)
```
- BUG NOTE (A, high priority): the `mul w22,w22,w27` instruction is in the loop body (0x101686b9c, branch back at 0x101686bd4). With natural scrolling (sign=-1) and P>=2, the sign alternates each sub-period: -dV, +dV, -dV ... With sign=+1 it is harmless. P==0 posts nothing (only setHorizontalOnly runs). Please confirm against the Hopper pseudocode for 0x101686a28 before reimplementing; the faithful reproduction is the literal loop above.
- Horizontal: when dV==0, dH!=0, the horizontal delta is substituted into dV and horizontalOnly is set. The H value is never sent as stepsH (always 0).

**-postMouseWheel:horizontal:accelerate:scrollphase:pcount:pnum:timestamp:** (0x101686d40; A for the arithmetic, B for branch details)
Arg map: x2=stepsV (V, int), x3=stepsH (H, int, only in logging), x4=accelerate, x5=scrollphase, x6=pcount (N), x7=pnum (k), stack=timestamp (ts, uint64 ns).

```
N := (P==0) ? 1 : P                                            // csinc on x24
W := max(1, self.wheelMultiplier)                              // csinc on [self+88]  (0x101686ec0)
if G_last != 0:                                                // global 0x1034c3a88
   dtTotal := Double(UInt64(ts - G_last)) / 1e9                // ucvtf: unsigned difference
   d11 := dtTotal / N
   ratchet.timeSinceLastReport(dtTotal)                        // see 2.3
   if d11 < 0.008:  dt := 0.008
   elif d11 < 0.1:  dt := d11
   else:            G_smooth := 0.0 ; dt := 0.1
else:                                                          // first event
   ratchet.reset(); d11 := 0; dtTotal := 0; dt := 0.1
unit := 1.0 / (Double(W) * 54.0/7.0)                           // d9
if k == N-1: G_last := ts                                       // 0x101687064..0x1016870e0
raw := unit * Double(V)                                         // d12 (kept for axis output, see below)
ratchet.ratchetSteps(V)                                         // result unused in this path [B]
if hysteresis != nil:  V := hysteresis.filterWheelMotion(V)
if disturbance != nil and (freewheelMode or W > 1 or forceWheelDisturbanceFilter()):
   V := disturbance.filterWheelMotion(V, periodCount: N)
v := (unit * Double(V)) / dt                                    // d9 = signed inches/s   (0x10168715c..0x101687164)
G_smooth := 0.95*G_smooth + 0.05*|v|                           // global 0x1034c3a80
s := screenIPSFromFingerIPS(v, smoothed: G_smooth)              // section 2.1.1
px := dt * (Double(screenDPI) * s)                              // d13, signed pixels
flags := [NSEvent modifierFlags]
horizMode := horizontalOnly || (flags & (1<<17)) != 0           // bit 17 = Shift (0x20000)
injector.setInjectFloatLineValues:( [self+81] || [self+80] )    // Adobe cached flags
yFix := self.yFixedLineFactor * self.additionalYFixedLineFactor
if !horizMode: (d8,d9,d10,d11) = (0, px, 0, |raw|)
else:          (d8,d9,d10,d11) = (-px, 0, |raw|, 0)
injector.InjectScroll... (doubles d0..d3 = d8..d11, d4 = yFix; ints as in 5)
```
Notes:
- `raw` (d12) is computed before filters, from unit*V_input. It is used only for the d10/d11 values (|raw|). After it, d12 is overwritten by yFixedLineFactor (0x101687364), so the yFix product is d4. Confidence A.
- The first-event path (G_last == 0) uses dt = 0.1 and dtTotal = 0 and does not call timeSinceLastReport. Confidence A.

**-screenIPSFromFingerIPS:smoothed:** (0x10168742c, A)
Arg map: d0 = fingerIPS (v), d1 = smoothed. Note the caller passes the signed velocity v in d0 and G_smooth in d1.

Inputs: scrollingSpeed s = self.scrollingSpeed (ivar 56). Curves: X = getXAccelerationCurve (0x101687414, returns static 0x1032655b0), Y = getYAccelerationCurve (0x101687420, returns 0x1032655e0). Both are static arrays of six doubles.

Static curve data (read from the binary, A):
- X[0..5] = {0.0, 0.3, 0.6, 60.0, 120.0, -1.0}   (0x1032655b0)
- Y[0..5] = {1.0, 1.0, 12.0, 12.0, 6.0, -1.0}    (0x1032655e0)

Precompute (per call, s = scrollingSpeed): S[k] = 1 + (Y[k] - 1) * s for k=0..5.

Lookup with a = |smoothed| (fabs d9):
```
if a < X[1]: i=1
elif a < X[2]: i=2
elif a < X[3]: i=3
elif a < X[4]: i=4
elif a < X[5]: i=5          // X[5] = -1.0, so never true
else: gain = S[5]           // taken for a >= X[5] (always)
for i in 1..5 (when matched):
   gain = S[i-1] + (a - X[i-1]) / (X[i] - X[i-1]) * (S[i] - S[i-1])
return gain * fingerIPS  (d8 * gain)
```
Important: because X[5] = -1.0, any a >= X[4] = 120 falls through to the constant S[5]. Also i=5 is unreachable.

Concrete gain table (s = scrollingSpeed):
| a (IPS) | gain |
|---|---|
| [0, 0.3)   | 1 -> 1 (S0=1, S1=1), flat 1 |
| [0.3, 0.6) | linear 1 -> 1+11s |
| [0.6, 60)  | flat 1+11s |
| [60, 120)  | linear 1+11s -> 1+5s |
| >= 120     | flat 1-2s |

For s = 0.5 (default): 1, 1 (to 0.3), 6.5, 6.5 (to 60), 3.5 at 120, then -0 (1-2*0.5=0). Note the gain goes to 0 at a>=120 for s=0.5 and goes negative for s>0.5. This is what the asm says. Confidence A for the formula; the physical meaning of the table is open (B).

Linear interpolation formula checked against the asm's fmadd: d2 = S[i-1] + ((a - X[i-1]) / (X[i]-X[i-1])) * (S[i]-S[i-1]).

**getXAccelerationCurve / getYAccelerationCurve** (0x101687414 / 0x101687420, A): return the static array addresses above (no ivar). The curves are not user-editable at runtime in this binary (no setter found in this class).

**additionalYFixedLineFactor** (0x101687978, B): called once per injection; its result is multiplied into yFix. Not decoded in detail.

**determineAdobeReaderRunning** (0x101687914, B): fills the cached flags at offsets 80 and 81 (see adobe_acrobat_helper 2.6).

**screenDPI getter/setter**: see above.

### 2.2 wheel_hysteresis

Ivars (A): _freewheel (BOOL, +8), _multiplier (int, +12, set by setWheelMultiplier: 0x101685dc4 `str w2,[x0,#0xc]`), hysteresis_timestamp (double, +16), hysteresis_positive (int, +24), hysteresis_negative (int, +28), hysteresis_freespin_setting (int, +32), hysteresis_ratchet_setting (int, +36), hysteresis_time_setting (double, +40), hysteresis_freespin_max (int, +48), hysteresis_ratchet_max (int, +52).

**init** (0x101685c0c, A): `[super init]`; `_multiplier = 1`; `[self readPreferences]`.

**readPreferences** (0x101685c68, A). Keys read from `[NSUserDefaults standardUserDefaults]` (C strings decoded from the CFString literals, A):
- `com.logitech.akebono.hysteresisFreespin` (int, k1)
- `com.logitech.akebono.hysteresisRatchet` (int, k2)
- `com.logitech.akebono.hysteresisTime` (double, t)
- `com.logitech.akebono.hysteresisFreespinDamper` (int, k4)
- `com.logitech.akebono.hysteresisRatchetDamper` (int, k5)

Logic:
```
fs = k1 >= 1 ? k1 : (k1 == 0 ? 4 : 0)                          // +32
rs = k2 >= 1 ? k2 : (k2 == 0 ? 1 : 0)                          // +36
time = t > 0 ? t : (t == 0 ? 1.0 : 0.0)                        // +40 (double)
fsMax = k4 >= 1 ? min(2*fs, k4) : (k4 == 0 ? fs : 2*fs)        // +48
rsMax = k5 >= 1 ? min(2*rs, k5) : (k5 == 0 ? rs : 2*rs)        // +52
```
Defaults if keys are absent (integerForKey returns 0 and doubleForKey returns 0): fs=4, rs=1, time=1.0, fsMax=min(8,0)? -> k4==0 path -> fsMax = fs = 4, rsMax = rs = 1. Confidence A.

**setWheelMultiplier:** (0x101685dc4, A) `_multiplier = w2` only (no readPreferences call here; the parent calls it).
**setFreewheelMode:** (0x101685dcc, A) `_freewheel = (BOOL) w2`.

**filterWheelMotion:(int)steps** (0x101685dd4, A for arithmetic, B for control-flow tracing; returns the output steps, i.e. the final w19).

```
filterWheelMotion(s):
  if s == 0 or _multiplier < 4: return s                        // 0x101685e00, 0x101685e0c
  now := [NSDate date].timeIntervalSince1970                     // d8
  if _freewheel && _multiplier > 7:                              // 0x101685e24..0x101685e34
      maxV := fsMax (+48);  X := fs (+32)
  else:
      maxV := rsMax (+52);  X := rs (+36)
  elapsed := now - hysteresis_timestamp (+16)
  if elapsed >= time_setting (+40):                              // else skip the relax step
      n := Int(elapsed / time_setting)                           // fcvtzs (truncate)
      pos := positive (+24); neg := negative (+28)
      newPos := (pos >= X) ? max(pos - n, X) : min(pos + n, X)
      newNeg := (neg >= X) ? max(neg - n, X) : min(neg + n, X)
      positive, negative = newPos, newNeg                        // stp at 0x101685ff0
  // (A) the timestamp is stored in both paths
  hysteresis_timestamp := now                                    // str d8,[x20,#0x10] at 0x10168610c
  if s >= 1:                                                     // 0x101686214
      // consume the positive bucket with the forward motion
      negative := min(negative + s, maxV)                        // csel ... lt at 0x101686224..0x101686228
      take := min(positive, s)
      positive := positive - take
      s := s - take
  else:                                                          // s <= -1 (s != 0)
      positive := min(positive - s, maxV)                        // csel ... lt at 0x1016863b0
      take := min(negative, -s)                                  // csneg at 0x1016863bc
      negative := negative - take
      s := s + take
  return s
```
Notes:
- In the s<1 branch, the code is `cmp w8,w25; csel w8,w8,w25,lt`, so `positive := min(positive - s, maxV)` (A). `take` for the negative case: `neg w10,w19; cmp w9,w10; csneg w10,w9,w19,lt` gives `take = min(negative, -s)` (A).
- The relax step's use of `n` in `max/min` comes from `csel`s at 0x101685fb0..0x101685fec (A).
- The sign of the output: positive steps are reduced by the positive bucket. Negative steps are reduced by the negative bucket (the `take`). This is the hysteresis (deadband) behaviour.
- Freewheel multiplier threshold: `_multiplier > 7` selects the freespin pair; `>= 4` is the minimum for any filtering.
- 0 steps return immediately without changing the timestamp (0x101685e00), and the same is true for multiplier < 4 (B wording: the timestamp is not updated in those cases).

### 2.3 wheel_ratchet_detect

Ivars (A): _multiplier (int, +8; init 1), ratchet_pos (int, +12; init 0).

- **init** (0x101687a24, A): `[super init]`; stores double constant at 0x102c24000+0x768, whose low 4 bytes are 1 -> _multiplier = 1.
- **setWheelMultiplier:(int m)** (0x101687a68, A): if m == _multiplier: no-op. Otherwise ratchet_pos := 0; _multiplier := m (logs).
- **reset** (0x101687ba0, A): ratchet_pos := 0.
- **timeSinceLastReport:(double dt)** (0x101687ccc, A): if dt >= 2.0: ratchet_pos := 0 (the reset path, log only). Constant 2.0 is `fmov d1,#2.0`. Otherwise nothing.
- **ratchetSteps:(int s)** (0x101687e04, A):
```
if _multiplier == 1: return s                                  // 0x101687e28 b.eq -> return steps
m := _multiplier;  pos := ratchet_pos (+12)
h := (m + (m < 0 ? 1 : 0)) >> 1                                // asr after cinc: trunc(m/2)
total := pos + s
A := ((total - h) % m) + h                                     // C remainder, sign follows dividend
B := ((total + (h - 1)) % m) - (h - 1)
newPos := (total < 0) ? A : B                                  // tst w23, #0x80000000 ; csel ne
ratchet_pos := newPos
return total - newPos        // a multiple of m (quantized)
```
- The return value is the quantized step count. In postMouseWheel the return value is discarded (7 in section 2.1, B). The ratchet's state change still happens.
- Constant: `_multiplier` default is the integer 1.

### 2.4 wheel_disturbance_filter

Ivars (A): action (BOOL, +8), actionTime (double, +16), spinning (double, +24), spinTime (double, +32), eventMonitor (+40), disturbanceTimeSetting (double, +48), stopTimeSetting (double, +56).

- **init** (0x101684ec0, A): disturbanceTimeSetting = 0.15, stopTimeSetting = 0.1 (the two doubles stored from the constant at 0x102cbe000+0xb90, decoded as (0.15, 0.1)); action = NO; actionTime = 0; then `[self watchMiddleButtonStart]`.
- **setDisturbanceTimeSetting:, setStopTimeSetting:, disturbanceTimeSetting, stopTimeSetting** (0x101685bf4 to 0x101685c04, A): trivial accessors.
- **wheelDisturbance** (0x101684f60, A): if disturbanceTimeSetting == 0: log "disabled" and return. Otherwise action := YES; actionTime := now (NSDate timeIntervalSince1970). Void.
- **filterWheelMotion:(int V) periodCount:(int N)** (0x1016851a8, B). Verified gating:
  - if N == 0 or V == 0 or action == NO: return V (B on the exact return path).
  - elapsed := now - actionTime; if elapsed >= disturbanceTimeSetting, the code takes the timeout/spin branch (0x10168545c). Otherwise it takes the disturbance branch (0x101685220).
  - The spin and stop branches compare `now - spinTime` and `now - actionTime` against stopTimeSetting; the spinning field is a double (0 = not spinning). Both branches return an adjusted V and rewrite spinning/spinTime, and they use `sdiv V/N` to split a period. The exact state machine was not fully traced (open question 1).
- **watchMiddleButtonStart / watchMiddleButtonStop** (0x101685b10 / 0x101685bb8, B): install and remove an NSEvent monitor (eventMonitor). The monitor calls wheelDisturbance on middle-button activity. Event masks not read.

### 2.5 hysteresis_switch

Used by injector hand-off (InjectScroll applyHysteresis). Not part of the wheel_mouse_handler path itself. Not fully decoded in this pass. Ivars (A): _first, _second (+8/+16), _lasttime (+24), _active (+32), _ratio (+40, double), _timeConstant (+48, double), _priorityRatio (+56, double). Methods: progressFirst:, progressSecond:, decay, endFirst, endSecond, doingFirst, doingSecond. Confidence C for the algorithm; see the next stage's notes.

### 2.6 gesture_scroll_helper (class methods, A for the decoded one)

**+multiplierBasedOnOrthagonalityAndSpeedWithX:Y:** (0x10166a9d0):
```
r = sqrt(x*x + y*y); if r == 0: return 0
t = | |x| - |y| | / r
a = atan( (2 - 1/r) * 6.14205039 ) / 3.1415927410125732 + 0.5
return a + t * (1 - a)
```

**+screenIPSFromFingerIPS:smoothed:scrollSpeed:** (0x10166aa64): not decoded in this pass (C). The instance method on wheel_mouse_handler (2.1.1) is the decoded counterpart with the same curves.

### 2.7 adobe_acrobat_helper

- `-isAdobeAcrobat:` (0x10165c588), `-isAdobeAcrobatRunningForeground` (0x10165c5d4), `-isAdobeAcrobatUnderMouseCursor` (0x10165c804): not decoded in this pass (B/C). Effect as seen from the caller: the injector gets `setInjectFloatLineValues:` set when the cached "running foreground" flag (+81) or "under mouse cursor" flag (+80) is true, and the cache is refreshed by `determineAdobeReaderRunning` on each postMouseWheel.

## 3. Acceleration summary and parameter entry points

- Per-period time `dt` = clamp((ts - G_last)/1e9/N, 0.008, 0.1). The 0.1 clamp zeroes G_smooth.
- Velocity `v` (IPS) = unit * V_filtered / dt, unit = 1/(max(1,W) * 54/7).
- Smoothed magnitude G_smooth = 0.95 G + 0.05 |v|.
- Gain = curve(G_smooth; scrollingSpeed) (section 2.1). Output inches/s = gain * v.
- Pixels per sub-period = dt * screenDPI * (gain * v) (`px`).
- So the total pixels for a sub-period are roughly (V/(W*K)) * gain * screenDPI, with dt cancelling except inside the gain input.
- screenDPI default 100. setScreenDPI is the only writer seen in this class.

## 4. Settings mapping (partial; C++ callers pending)

| Setting / proto field (as named in the task) | Agent parameter | Effect | Conf |
|---|---|---|---|
| naturalScroll (UI direction) | WMH naturalScroll is always NO in production (ctor @0x10166e804). Natural direction is applied upstream by the devio layer (dir enum NATURAL=1 -> flag, devio_feature_scroll_wheel::set_params @0x100984aac), not via WMH naturalScroll | WMH sign stays +1 in production | A |
| SensitivityScrollWheel sensitivity (proto wheel+0x30; siminput) | scrollingSpeed = 0.06 + ((sens+1)/2)*1.14 (lambda $_27, @0x101679c9c) | slope of gain curve S[k]=1+(Y[k]-1)s; unclamped on this side (proto speed clamped to [-1,1] only in devio _set_speed) | A |
| wheelMultiplier / Sensitivity | setWheelMultiplier: -> [self+88], forwarded to hysteresis/ratchet | unit = 1/(W*K) and ratchet quantum | A |
| freewheel / SmartShift freespin | setFreewheelMode: -> [self+85], hysteresis [+8] | freespin pair selected when W > 7 | A |
| SmartShift ratchet | ratchet multiplier via setWheelMultiplier: | quantizes steps to multiples of W | A |
| hysteresisFreespin, hysteresisRatchet, hysteresisTime, *Damper (NSUserDefaults, com.logitech.akebono.*) | readPreferences in wheel_hysteresis | sets X, time, max | A |
| screenDPI | setScreenDPI: -> [self+92] | px = dt * DPI * gain*v | A (default 100) |
| yFixedLineFactor | setYFixedLineFactor: -> [self+104] | multiplied with additionalYFixedLineFactor (d4) for the line-based path | A |
| wheelStopTime | setWheelStopTime: -> [self+100] and disturbance stopTimeSetting | disturbance filter, default 0.1 s; test path only | A |
| wheelDisturbanceTimeout | setWheelDisturbanceTimeout: -> [self+96] and disturbance disturbanceTimeSetting | disturbance window, default 0.15 s; test path only | A |
| disable_acceleration | setAccelerate: = !disable_acceleration (lambda @0x101679c80) | production disable=false -> accelerate=1; passed as postMouseWheel accelerate arg (x4) | A |
| Shift modifier | flags bit 17 in postMouseWheel | forces horizontal axis | A |
| MacOsScrollWheelParameters.mac_min_scroll_speed / max (Input.MouseWheel field 10) | not consumed on the production set_scroll_speed route (min/max are constants -1, 1 on the float side; a/b are 0.06/1.2) | none | A |
| screenDPI (production) | constant 100 in set_scroll_speed lambda (0x101679c8c) | 100 | A |
| line_factor (wheel+0x48) | passed as lineFactor to gestures::scroll; device path uses constant 1.0 | yFixedLineFactor | A |

## 5. Hand-off to the next stage (injector)

- Call (A, 0x101687388..0x10168739c): `[injector InjectScrollX:Y:XInches:YInches:scrollphase:inertia:timestamp:pageswipe:applyHysteresis:yFixedLineFactor:]` with:
  - doubles d0=d8, d1=d9, d2=d10, d3=d11, d4=yFixedLineFactor*additionalYFixedLineFactor
  - ints as set in registers: x2 = scrollphase (arg4 = 0 from onMouseWheel), w3 = 0, x4 = ts, w5 = 0, w6 = 1 (remaining int args not set in this block; mapping open)
- Axis selection (A): horizMode false -> (d8, d9, d10, d11) = (0, px, 0, |raw|); horizMode true -> (-px, 0, |raw|, 0).
- injector decompile header (`decomp/scroll/injector_InjectScroll...`) assigns arg doubles to locals d11 (d0), d10 (d1), d9 (d3), d8 (d4), so the injector's exact XInches/YInches/yFix naming needs the next-stage agent's confirmation (open question 4).

## 6. Callers and entry points (from call-site report, A unless marked)

Object graph: gestures::gestures() @0x10166e73c allocates one wheel_mouse_handler via `[WMH initWithFilters]` (0x10166e7dc; the only WMH allocation). The impl object holds the WMH at impl+0x0. gesture_handler_discrete_scroll_left_right (superclass wheel_mouse_handler) sits at impl+0x30; a gesture_handler_free_pan object at impl+0x28 (class inferred).

Entry points into the WMH:
- Proto/siminput vertical path: virtual_input_osx::simulate_mouse_input @0x1011fe27c -> scroll_manager vtable+0x10 = simulate_mouse_vertical_wheel_input(bool smooth, uint m, double dV, double dH, double speed, double lineFactor, int period, int ts32) @0x101bf9188 -> gestures::scroll @0x1016706d0/0x1016706e8 -> onMouseWheelWithPeriod:deltaV:deltaH:timestamp:.
- Field mapping from Input.MouseWheel (A, _InternalParse 0x10261a050): +0x18 delta_x, +0x20 delta_y, +0x2c period_count (u32), +0x30 sensitivity, +0x3c smooth_scrolling, +0x40 timestamp (u64), +0x48 line_factor; ScrollMultiplier at Input+0x48 supplies m. Vertical path call: smooth=wheel+0x3c, m=ScrollMultiplier (0 -> default), dV=delta_y, dH=delta_x, speed=sensitivity, lineFactor=wheel+0x48, period=period_count, ts=timestamp.
- Device path: devio_feature_2121_gesture::onWheelMovement(bool, uint period, int dV, int dH) @0x10093036c reads speed (_get_speed_cached, gesture_handler+0xe8, clamped to [-1,1] in _set_speed) and smooth (+0xf0), multiplier = fcvtzu(vtable+0xc0()), negates dV/dH when [this+0x254]&1, then calls simulate_mouse_vertical with lineFactor = 1.0. The bool is used only for logging. Upstream HID++ parsing not traced.
- Settings source: devio_feature_scroll_wheel::set_params @0x100984aac: speed = ScrollWheelSettings field 1 (double +0x20) -> _set_speed; dir enum (NATURAL=1, STANDARD=2) -> natural flag = dir != STANDARD; isSmooth (bool +0x2c) -> _set_smooth.
- Discrete path: gesture_handler_discrete_scroll_left_right scroll: @0x101669164 sends the 3-part selector `onMouseWheelWithPeriod:deltaV:deltaH:` (period=1, deltaV=0, deltaH=+/-2). That selector is NOT implemented on WMH (only the 4-part form exists). Likely an unrecognized-selector exception on horizontal left/right; verify at runtime.

Setter call sites (receiver / value source):
- setScrollingSpeed: set_scroll_speed lambda $_27 @0x101679c9c (WMH) and @0x101679dc4 (discrete, impl+0x30). Value: frac = (v - min)/(max - min) in float; out = a + frac*(b - a) in double, rounded to float, stored raw (no clamp on this side). Production constants: min=-1.0f, max=1.0f, v=(float)sensitivity, a=0.06, b=1.2 (verified). So scrollingSpeed = 0.06 + ((sens+1)/2)*1.14. Test path uses the same a/b but min/max come from the FloatSetting proto.
- set_free_pan_speed lambda $_34 @0x10167b854 (impl+0x28): 0.06f + ((v-min)/(max-min))*1.14f, no clamp.
- Discrete init @0x101669118: constant 0.1505 (0x3FC34395810624DD).
- setAccelerate: set_scroll_speed lambda @0x101679c80: value = !disable_acceleration (cset eq). Production: disable_acceleration=false -> accelerate=1. Discrete init: NO.
- setScreenDPI: lambda @0x101679c8c, uint dpi; production dpi=100. Discrete init: 15.
- setWheelMultiplier: (a) gestures::set_wheel_multiplier(uint m) @0x10166f274: WMH value = smooth ? m : 1 (impl+0x8c = smooth flag, csinc at 0x10166eed0), skipped when equal to the current getter. (b) WMH.setWheelMultiplier: @0x101686cb8 stores +0x58, forwards to hysteresis (+0x18) setter, then hysteresis readPreferences (0x101686cc0), then ratchet (+0x20) setter (0x101686ccc).
- setFreewheelMode: (a) lambda $_28 of set_ratchet_state @0x101679f24: value = !ratchet (cset eq). (b) WMH.setFreewheelMode: @0x101686d18 forwards the same value to hysteresis (+0x8). Not inverted at that step.
- setYFixedLineFactor: gestures::scroll @0x1016706d0, lineFactor passed through as double.
- setHorizontalOnly: inside WMH onMouseWheel @0x101686a78 (NO) and @0x101686a8c (YES, when dV==0 && dH!=0).
- setWheelDisturbanceTimeout: lambda $_35 @0x10167b934 (float). setWheelStopTime: lambda $_36 @0x10167ba14 (float). Both reached from the test path only. Forward to disturbance filter setters (+0x30 and +0x38 in the helper's offset numbering; my table lists disturbance ivars at +48 and +56, which corresponds to the same two slots; re-verify before coding).
- setForceWheelDisturbanceFilter: no send site. Ivar +0x54 stays zero.
- setNaturalScroll: constant NO at the ctor (0x10166e804) and discrete init (0x1016690fc). Production WMH naturalScroll = NO; natural direction is handled elsewhere in the pipeline.

Other callers:
- set_ratchet_state: virtual_input_osx::start @0x1011fb1e0 (constant true), siminput endpoint @0x1011efdb4 (RatchetSwitch.ratchet), test path.
- set_smooth_scrolling: virtual_input_osx::start @0x1011fb1d0 (constant false), vertical path (wheel+0x3c), test path.
- set_wheel_multiplier: gestures ctor (impl+0x90, initially 0), siminput @0x1011efb30 (ScrollMultiplier), virtual_input_osx::start @0x1011fb1dc (constant 8; effective 1 unless smooth), vertical path (m if nonzero), test path.
- set_scroll_speed: vertical path and test path only.

## 6a. Hazards found in the call-site pass

- Timestamp truncation (A): simulate_mouse_vertical does `mov x20,x4` and later `sxtw x4,w20` before gestures::scroll. The 64-bit timestamp is cut to its low 32 bits and sign-extended. It wraps about every 4.29 s and goes negative when bit 31 is set. WMH uses it as ts in dt = (ts - G_last)/1e9, so dt is wrong after the wrap. This affects postMouseWheel's timing directly.
- Period: period==0 (Input.MouseWheel.period_count unset) produces no postMouseWheel calls (cbz w21 at 0x101686b94).
- Argument order conflict (UNRESOLVED): my reading of onMouseWheelWithPeriod:deltaV:deltaH:timestamp: (0x101686a28) is period in x2 (`mov x21,x2`), deltaV in x3, deltaH in x4, ts in x5. The helper reports the caller at 0x1016706e8 puts period in x3 and deltaV in x2. One of the two readings is wrong. Check the caller's register setup in disassembly before reimplementing.
- MacOsScrollWheelParameters (Input.MouseWheel field 10) is not consumed on the production set_scroll_speed route. My earlier note that min/max come from it was wrong.
- The vertical path passes d0/d1 as dV/dH (int-converted before the constants overwrite d0/d1), d2 as speed, d3 as lineFactor.

## 8. Corrections to earlier sections (from call-site pass)

- Section 4 earlier said scrollingSpeed range (0..1) was inferred; it is now confirmed as the formula above with production inputs.
- Section 4 earlier mapped naturalScroll to WMH+48 as a live sign; in production it stays NO.
- Section 6 previously said the caller was pending; it is now filled in above, with the argument-order conflict flagged.

## 7. Open questions

1. wheel_disturbance_filter filterWheelMotion:periodCount: full state machine (spin/stop branches, return path at 0x101685340). Needs a full trace of 0x1016851a8..0x101685b10.
2. The loop-scope `mul` in onMouseWheel (section 2.1): confirm literal behaviour (alternating sign with natural scroll and P>=2) against the Hopper decompile and against captured behaviour.
3. Ratchet return value discarded in postMouseWheel: confirm there is no later use of d0 from that call.
4. Injector argument mapping for InjectScroll (ints x2..x8 and doubles). The exact selector argument order should be checked against the injector's own disassembly.
5. gesture_scroll_helper +screenIPSFromFingerIPS:smoothed:scrollSpeed: (0x10166aa64) and the adobe_acrobat_helper methods were not decoded.
6. setWheelDisturbanceTimeout: (0x101686980) read only partially (only test-path callers found).
7. The injector init FP immediates (`fmov d0,d1,d2` = 3.0 per otool) for newInjectorWithUnit:width:height: need decoding to know unit/width/height.
8. The gain table for scrollingSpeed > 0.5 becomes negative beyond a=120 IPS. Production scrollingSpeed = 0.06 + ((sens+1)/2)*1.14 ranges over [0.06, 1.2], so this is reachable; confirm the intended behaviour.
9. Resolve the onMouseWheelWithPeriod argument order conflict (section 6a).
10. Confirm the discrete horizontal path's 3-part selector failure at runtime (section 6).

## 9. wheel_disturbance_filter (full decode)

Method: static disassembly only (otool -tV output, binary symbols). Double constants were read from the Mach-O file with a parser, not from Hopper. spdlog calls (default_logger, backtracer::enabled, log_it_, log_msg) were treated as no-ops for control flow; their message strings are listed so the branches can be matched against logs. Every branch below is [ASM] unless tagged otherwise. Addresses are the first instruction of each branch.

### 9.1 Ivars [ASM]

Read from the `_OBJC_IVAR_$_wheel_disturbance_filter.*` globals (0x103257e48..0x103257e60), which hold the offsets directly.

| ivar | offset | type | used by |
|---|---|---|---|
| action | +8 | BOOL | wheelDisturbance, filterWheelMotion, init |
| actionTime | +16 | double | wheelDisturbance (store), filter (dt) |
| spinning | +24 | double | filter (read/write), 0.0 = not spinning |
| spinTime | +32 | double | filter (stop check, store) |
| eventMonitor | +40 | id | watchMiddleButtonStart/Stop |
| disturbanceTimeSetting | +48 | double | getter/setter 0x101685bec/0x101685bf4 |
| stopTimeSetting | +56 | double | getter/setter 0x101685bfc/0x101685c04 |

The §2.4 offsets and types are correct (spinning and spinTime are doubles).

### 9.2 Constants [ASM]

- Defaults (init, 0x101684ec0 .. 0x101684f10): one 16-byte load `ldr q0,[0x102cbe000+0xb90]` (address 0x102cbeb90) stored to +48 (low lane) and +56 (high lane). Low lane = 0x3FC3333333333333 = 0.15 (exact value 0.1499999999999999944...), high lane = 0x3FB999999999999A = 0.1 (0.1000000000000000055...).
- Mouse mask in watchMiddleButtonStart: `mov w2, #0x6000000` = 0x06000000 = (1<<25) | (1<<26), i.e. NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp. OtherMouseDragged (1<<27) is not included. [INF] for the enum values, which are the standard AppKit ones.
- Middle button test in the monitor block: `cmp x0,#2` on `[event buttonNumber]`. NSEvent buttonNumber is 0-based, so 2 is the middle button. [INF] on the 0-based convention, which is the documented AppKit one.
- Stack block descriptor for the monitor block: flags word 0xC2000000 at block+8 (bits 25, 30, 31), reserved 0, invoke 0x101685b7c, descriptor 0x103140ec0, captured self at block+32. [INF] for the named bits.
- The `fmov` immediates are exact: `#1.0`, `#-1.0`, `#0.5`, and `fcmp ..,#0.0` for zero tests.

### 9.3 Method bodies

**-init** (0x101684ec0, [ASM]): `[super init]` via objc_msgSendSuper2. If non-nil: store the default pair at +48/+56 (9.2), action = NO, actionTime = 0, spinning = 0, spinTime = 0 (`stp xzr,xzr,[x19,#0x18]`, `str xzr,[x19,#0x10]`), then `[self watchMiddleButtonStart]`. eventMonitor is not written, so it is nil from alloc.

**-deInit** (0x101684f28): tail-jumps to `-watchMiddleButtonStop`. Called from 0x1016864e0 (tail call) [ASM].

**-dealloc** (0x101684f2c): `objc_msgSendSuper2` with the selector at 0x103253000+0xa30 (not resolved; [INF] it is `dealloc`). It does not call watchMiddleButtonStop, so the monitor is not removed on dealloc unless deInit ran first. [INF]

**-disturbanceTimeSetting / -stopTimeSetting / setters** (0x101685bec .. 0x101685c08): plain d0 load and store at +48 and +56. [ASM]

**-watchMiddleButtonStart** (0x101685b10, [ASM]):
```
eventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:0x6000000 handler:^(NSEvent *e){ ... }];
```
Global monitor only, no local monitor. The block is on the stack, captures self (not a copy of the ivar), and is invoked with the NSEvent as its argument. The start is not idempotent: a second call overwrites eventMonitor without removing the first monitor. init is the only caller in this binary.

**block: ___50-[wheel_disturbance_filter watchMiddleButtonStart]_block_invoke** (0x101685b7c, [ASM]):
```
void block(event) {
  if ([event buttonNumber] == 2)   // 0x101685b94 cmp x0,#2
      [self wheelDisturbance];     // 0x101685ba8 tail call
}
```
It fires on both down and up of any "other" mouse button, so a middle-button press arms the window on the down and again on the up. Events from all apps are seen (global monitor).

**-watchMiddleButtonStop** (0x101685bb8, [ASM]): if eventMonitor != nil: `[NSEvent removeMonitor:eventMonitor]`, then eventMonitor = nil.

**-wheelDisturbance** (0x101684f60, [ASM]):
```
@synchronized(self) {
  if (disturbanceTimeSetting == 0.0) {        // 0x101684f84 fcmp d0,#0; b.ne
      log "wheel_disturbance_filter disabled"; return;
  }
  log "wheel_disturbance_filter disturbance"; // 0x101685068
  actionTime = [NSDate date].timeIntervalSince1970;   // 0x101685140..0x101685150
  action = YES;                               // 0x101685154
}
```
The test is `!= 0`, so negative and NaN settings arm the filter. Callers: the block above, and wheel_mouse_handler `-wheelDisturbance` (0x1016878d4), which forwards to its filter at handler+0x28 [ASM].

**-filterWheelMotion:(int)V periodCount:(int)N** (0x1016851a8 .. 0x101685a40, [ASM]). Pseudocode with each branch's entry address:

```
int filterWheelMotion(int V, int N) {           // x2 = V, x3 = N; w-form ops on both
  @synchronized(self) {                         // 0x1016851d8
    // no effect                                // 0x101685340
    if (N == 0 || V == 0 || !action) return V;  // 0x1016851dc, 0x1016851e0, 0x1016851e8

    now = [NSDate date].timeIntervalSince1970;  // 0x1016851ec..0x1016851fc  (d8)
    dt  = now - actionTime;                     // d9 = [+16]                 0x101685200..0x10168520c

    if (dt < disturbanceTimeSetting) {          // 0x101685214 b.pl skips when >=
        // "spinning before disturbance timeout, amount=%d"
        spinning = (double)(V / N);             // sdiv w8,w20,w21 (32-bit)   0x10168532c
        spinTime = now;                         // stp d0,d8,[+24]
        return 0;                               // w20 = 0                    0x101685338
    }

    // post-window: dt >= disturbanceTime       // 0x10168545c
    if (spinning != 0.0) {                      // 0x101685460 b.eq -> 0x101685564
        if (now - spinTime > stopTimeSetting)   // 0x101685474..0x10168547c b.le -> 0x101685560
            return CLEAR(V);                    // log "spin has stopped due to long time since last report"
    }

    if (spinning != 0.0) {                      // 0x101685564 b.eq -> 0x101685580
        bool motionPos = V > 0;                 // cmp w20,#0; cset gt
        bool spinNonPos = spinning <= 0;        // fcmp d9,#0; cset le
        if (motionPos == spinNonPos)            // eor; tbz bit0 -> 0x101685818
            return CLEAR(V);                    // log "respin detected from direction change"
    }

    if (spinning == 0.0)                        // 0x101685580 -> 0x10168561c -> 0x1016856d0 -> 0x101685938
        return ACTION_STOP(V);                  // log "action has stopped"

    q = (double)(V / N);                        // sdiv again                  0x101685588 / 0x101685624

    if (spinning > 0) {                         // 0x101685584 fall-through
        if (spinning + 1.0 < q)                 // fadd d1,d9,#1.0; fcmp d1,d0; b.pl skips when >=
            return CLEAR(V);                    // log "respin detected from speed increase, spinning=%f, motion=%d"  (0x1016855a0 block)
    } else {                                    // 0x10168561c, spinning < 0
        if (spinning - 1.0 > q)                 // fadd d1,d9,#-1.0; fcmp d1,d0; b.le skips when <=
            return CLEAR(V);                    // same log, second copy at 0x101685644
    }

    // still spinning                           // 0x1016856d0
    spinning = (spinning + q) * 0.5;            // fadd d0,d9,d0; fmul by #0.5
    // log "still spinning after disturbance timeout, spinning=%f, motion=%d, newvalue=%f"
    spinTime = now;                             // stp d9,d8,[+24]             0x10168580c
    return 0;                                   // w20 = 0
  }
}

CLEAR(V):        // 0x101685934
    spinning = 0.0;                             // str xzr,[+24]
    ACTION_STOP(V)
ACTION_STOP(V):  // 0x101685938
    log "wheel_disturbance_filter action has stopped"
    action = NO;                                // strb wzr,[+8]               0x101685a10
    return V;                                   // x20 unchanged
```

Notes on the trace:
- The return value is x20, the 64-bit input V on every pass-through path and 0 on every suppressed path. All compares and sdiv use the 32-bit w form, so the arithmetic is C `int` (truncating division; the INT_MIN / -1 case yields INT_MIN, not a trap). [ASM]
- The stop test happens only when spinning != 0 (0x10168545c). The direction test is also skipped when spinning == 0. A zero spin therefore goes straight to ACTION_STOP on the first post-window motion, so the stop time is not consulted. [ASM]
- Spin and spinTime are only written in two places: the window branch (overwrite, not accumulate) and the still-spinning branch (smoothing). CLEAR writes only spinning. spinTime is not reset. [ASM]
- The stop test uses `now - spinTime`. §2.4 says the stop branch compares `now - actionTime`; that is only the window test. [ASM]
- dt uses actionTime, so the window is measured from the last middle-button event, not from the last motion. [ASM]

### 9.4 Behaviour summary [INF]

While armed, all motion inside `disturbanceTime` of the last button event is swallowed, and the per-period rate V/N is recorded. After the window, motion stays suppressed while it keeps the sign of the recorded rate and is not a sudden change. Suppression ends (motion is released and the filter disarms) when: the rate is 0 at window end, the wheel has been quiet for more than stopTime, the sign flips, or the rate jumps by more than one step per period. Otherwise the recorded rate is averaged with the new rate (half-weight) and motion stays suppressed.

### 9.5 Port changes (WheelFilters.swift)

- `disturbance(now:)` now arms on any non-zero setting, not only positive ones.
- `filter` now follows 9.3 exactly. The earlier "lastMotion" model was wrong: it had no spinning state, used the wrong stop reference, and never released motion on direction change or respin.
- The Swift type keeps the fields in the same roles as the ivars (action, actionTime, spinning, spinTime). The monitor is not ported (see 9.6).

### 9.6 Open items

- [OPEN] The NSEvent global monitor (mask 0x6000000, buttonNumber == 2 gate) has no Swift counterpart. No code in Sources calls `disturbance(now:)`, so the window never opens in the current port unless something else arms it. The monitor belongs in whichever layer owns event taps, and it needs Input Monitoring permission [INF].
- [OPEN] The original runs `filter` and `wheelDisturbance` under @synchronized(self). The Swift struct is not synchronised, so the owner must confine it to one thread (or lock it) when the monitor and the scroll path run on different threads. Which thread the monitor's handler runs on in Options+ was not determined.
- [OPEN] The selector used to call `filterWheelMotion:periodCount:` is not a named stub in all_main.s, so its callers in the binary were not enumerated.
- [OPEN] Whether `-deInit` (0x1016864e0 tail call) runs on the wheel_mouse_handler teardown path and whether the monitor is removed there was not traced.
