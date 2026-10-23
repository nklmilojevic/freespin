# 02 - Wheel smooth scrolling, inertia and event injection (agent v2.6.944893, arm64)

Binary: `bin/logioptionsplus_agent.arm64`. Disassembly: `otool -arch arm64 -tvV` (full dump used as `all.s` in scratchpad). Addresses below are file VAs (0x1000xxxxx).

Tags: **[ASM]** verified by reading arm64 instructions. **[PSEUDO]** from Hopper pseudocode only, not cross-checked. **[INF]** inferred from naming/usage. **[OPEN]** unresolved.

Caveat for all Hopper-derived names: the pseudocode mangles register reuse across branches. Every ivar offset below was resolved from the assembly, not from Hopper's `r19[...]` indexing. Byte offsets in the injector were resolved from `strb/ldrb [x, #imm]` in asm.

---

## 0. Ivars and constants (gesture_handler_2_finger_scroll, self-relative offsets from `_OBJC_IVAR_$` symbols)

| ivar | type (from store width) | init value [ASM initWithUnit:... 0x10166033c] |
|---|---|---|
| `_microsecondsPerPeriod` | int32 | 16600 (0x40d8) |
| `_lastGestureEventInNanoseconds` | int64 | 0 |
| `_scrollVelocityX`, `_scrollVelocityY` | double | 0 |
| `_scrollVelocityXSmoothedForAccel`, `..YSmoothedForAccel` | double | 0 |
| `_scrollVelocityXSmoothedForSwipe`, `..YSmoothedForSwipe` | double | 0 |
| `_wheelInertiaX`, `_wheelInertiaY` | double | 0 |
| `_wheelVerticalDistance` | double | 0 |
| `_wheelInertiaBoost` | int32 | 0 |
| `_wheelScrollPhase` | int32 | 0 (NSEventPhase-style: 1 began, 2 changed, 4 ended) |
| `_wheelInertiaPhase` | int32 | 0 (momentum phase: 1 begin, 2 continue, 3 end) |
| `_wheelInertiaTerminate` | bool | 0 |
| `_wheelInertiaCallbacksActive` | int32 | 0 |
| `_wheelInertiaCallbackIdentifier` | int32 | 0 |
| `_wheelInertiaCallbackTime` | int64 (ns) | 0 |
| `_localAppCurtainSwipe` | bool | **1** (passed as `pageswipe`) |
| `_scrollingInertia` | bool | **1** |
| `_scrollSpeed` | double | **1.0** |
| `_lastDx`, `_lastDy` | int32 | 0 |
| `_naturalScrolling` | bool | 0 |
| `_horizontalNaturalScrolling` | bool | 0 |
| `_curtainSwipe` | bool | 0 |
| `_exponentialDecay` | double | **1.0** |
| `_nextScrollEventType` | int32 | 0 |
| `_numberTimerInvocationsToStartDecay` | int32 | **5** |
| `_scrollTimer` | id (NSTimer) | nil |
| `_noReportsForHowManyTimerInvocations` | int32 | 0 |
| `_nextScrollDx`, `_nextScrollDy` | int32 | (not initialised) |
| `_pendingSwipeX`, `_pendingSwipeY` | double | (not initialised) |
| `speedMultiplier` | (setter, `setSpeedMultiplier:`) | set to **1.0** in init |

Inherited from `gesture_base` (ivar symbols): `_unitInches` (0xb34), `_widthInches` (0xb38), `_heightInches` (0xb3c), `_resX` (0xb40), `_resY` (0xb44), `_injector` (0xb48).

**[ASM]** init also calls `[gesture_sync_2 instance] setEnable:YES`. The class-ref slot at VA 0x103257078 rebases to `_OBJC_CLASS_$_gesture_sync_2` (via `dyld_info -fixups`). Its methods used here: `+instance`, `setAppCurtainSwipe:`, `Restore`, `setEnable:`.

### Decoded constants (all **[ASM]**, decoded with struct)

| VA of use | hex | value | role |
|---|---|---|---|
| init | 0x3ff0000000000000 | 1.0 | defaults |
| increaseLogarithmic 0x10166052c | 0x3fefae147ae147ae | **0.99** | threshold: if decay >= 0.99 -> 1.0 |
| increaseLogarithmic | 0x3fd3333333333333 | **0.3** | growth fraction |
| decreaseExponential 0x101660814 | 0x3fc3333333333333 | **0.15** | per-tick decay multiplier |
| decreaseExponential | 0x3f847ae147ae147b | **0.01** | log-only cutoff (no clamp in code) |
| onGestureScroll (path B) 0x101660ef4 | 0x3f9097ff2474538f | **0.01620482120513916 s** | NSTimer interval (repeats) |
| onGestureScroll / scheduled | 0x4066800000000000 | **180.0** | pixel-to-"inch" divisor for event deltas |
| scheduled 0x1016610a8 | 0x3fd3333333333333 | **0.3** | emit fraction of pending |
| scheduled | 0x3fe999999999999a | 0.8 (SmoothedForSwipe prev weight) | [ASM] |
| scheduled 0x1016610dc | 0.5 (fmov #0.5) | 0.5 | half-emit |
| scheduled | 0x3fc999999999999a | **0.2** | SmoothedForSwipe new-sample weight |
| scheduled 0x10166132c | 0x408f400000000000 | **1000.0** | us->ms, ms->s |
| scheduled 0x1016613fc.. | 0x409f400000000000 | **2000.0** | scale for AppSwipe dx |
| scheduled 0x101661698 | 0x4059000000000000 | **100.0** | screen scale for wheel px |
| scheduled | 0x3fefae147ae147ae / 0x3f847ae147ae147b | 0.99 / 0.01 | accel smoothing (2.4) |
| scheduled 0x1016613bc | 1000 (int) | **1000** | `lastGesture += mpp*1000` |
| scheduled 0x101661734 | 4.0 (fmov #4.0) | **4.0** | inertia gate: X^2+Y^2 > 4.0 |
| scheduled | 5.0 / 10.0 | 5, 10 | boost = min(5*|wvd|, |Y|/10, 10) |
| requestWheelInertiaCallback 0x1016627dc | 0x41cdcd6500000000 | **1e9** | ns->s |
| requestWheelInertiaCallback | 0x3f1a36e2eb1c432d | **1e-4 s** | minimum callback delay |
| requestWheelInertiaCallback caller 0x1016618f4 | w2 = 0x00b71b00 | **12,000,000 ns (12 ms)** | `requestWheelInertiaCallback:12ms curtime:... why:` |
| processWheelInertia 0x101661c30 | 0x3fee8f5c28f5c28f | **0.955** | boost divisor and per-frame decay base K |
| processWheelInertia 0x101661c74..0x101661cb0 | 0x3fb1eb851eb851ec | **0.07** | soft-threshold c in K*|v|/(|v|+c) |
| processWheelInertia 0x101661d08.. | 0xbfa47ae147ae147b / 0x3fa47ae147ae147b | **-0.04 / +0.04** | stop band (terminate when both |X|,|Y| <= 0.04) |
| processWheelInertia 0x101661d60 | 0x4059000000000000 | **100.0** | px scale |
| processWheelInertia 0x101661d78/0x101661ea4 | 0x3f889374bc6a7efa | **0.012** | inch/px conversion for injection |
| processWheelInertia 0x101661d58+ | (both 0.04 and 0.012 used) | - | |
| injector accumulator 0x10167e864.. | 0x3f947ae147ae147b | **0.02** | accumulator threshold |
| injector | float 0x3d75c28f | **0.06 f** | modf fraction threshold |
| injector | float 0x3ba3d70a | **0.005 f** | modf fraction threshold |
| injector 0x10167ea00 | 0x40f0000000000000 | **65536.0** | 16.16 fixed-point |
| injector 0x10167e958 | 0x4024000000000000 | **10.0** | pixels per line |

---

## 1. Scroll-phase state machine (gesture_handler_2_finger_scroll, mouse wheel path)

Inputs to `onGestureScrollEventType:dx:dy:` are `eventType` (1 = begin, 2 = change, 3 = end, [ASM] values from `scheduled` branches on `eventType == 1/2/3`), `dx`, `dy` (int32 wheel deltas from `wheel_mouse_handler`).

```
                      onGestureScrollEventType(t,dx,dy)  [0x101660b80]
                                  |
              timer valid?  --yes-->  store next{t,dx,dy}; pendingX += dx/180; pendingY += dy/180;
                 |                    noReports = 0; increaseLogarithmic(); RETURN   (no injection here)
                 no
                 v
     store next{t,dx,dy}; pendingX = dx/180; pendingY = dy/180; noReports = 0
     exponentialDecay = 1.0
     scheduledGestureScrollEventType(t,dx,dy)   (immediate first tick)
     if t == 1: nextType = 2
     scrollTimer = NSTimer(0.0162048 s, repeats, target self, selector onScrollTimer:)

  NSTimer tick -> onScrollTimer  [0x1016609c8]
     if nextType == 3:                  (end requested)
          invalidate + nil the timer
     else:
          noReports += 1
          if noReports >= 5: decreaseExponential()     (decay *= 0.15 each tick past 5)
     scheduledGestureScrollEventType(nextType, nextDx, nextDy)

  scheduledGestureScrollEventType(t, dx, dy)  [0x10166105c]   (see section 2)
     t == 1 (began):  curtainSwipe -> gesture_sync_2; lastGestureNs = upTimeInNanoSeconds(); firstFlag=1
     t == 2 (change): lastGestureNs += mpp * 1000  (= +16.6 ms per tick, synthetic clock)  [ASM]
     t == 3 (end):    gesture_sync_2 Restore; lastGestureNs += (int32 at offset x22) * 1000   [ANOMALY, see 2.7]
     then velocity/inject logic; inject phase per wheelScrollPhase state (below)

  wheelScrollPhase (ivar) transitions in scheduled (t != 3 path):
     phase' = (phase != 0) ? 2 : 1          // first emitted frame = 1 (began), then 2 (changed)
  wheelScrollPhase (t == 3 path):
     if phase != 0: inject phase=4 (ended) ; phase = 0

  Momentum (wheelInertiaPhase), processWheelInertia (see 3):
     1 = momentum begin (first inertial frame; phase<=1 -> phase+1)
     2 = momentum continue (phase stays 2)
     3 = momentum end (set when terminating)
```

Timer periods: NSTimer 0.0162048212 s (repeats) for the wheel tick; inertia via `performSelector:withObject:afterDelay:` with delay = max(ns/1e9, 1e-4) (12 ms requested). Both are NSRunLoop based **[ASM]**; the thread that owns the run loop is not determined here **[OPEN]**.

Concurrency: `processWheelInertiaCallback:` does `objc_sync_enter(self)` around its body **[ASM 0x101662..0x1016620d8]**. The timer path does not take that lock **[OPEN]**: a potential race between timer tick and inertia callback.

---

## 2. Velocity model and injection (scheduledGestureScrollEventType:dx:dy:, 0x10166105c, 0x1016.. .. 0x101661a84)

### 2.1 Pending emit (0x1016610a4-0x1016610d8, **[ASM]**)
```
a = 0.3 * pendingX;  pendingX -= a        // pending decays to 70% per tick
b = 0.3 * pendingY;  pendingY -= b
emitX = (horizNatural ? -0.5*a : +0.5*a)   // d8
emitY = (natural      ? -0.5*b : +0.5*b)   // d9
```
`emitX/emitY` are used only for the **page-swipe** call (2.6). The wheel path below overwrites d8/d9 before the scroll injection.

### 2.2 lastDx/lastDy (**[ASM]** 0x101661264-0x101661298, for t != 3)
```
m  = speedMultiplier()                                        // [self speedMultiplier]
dxS = (horizNatural ? -1 : +1) * m * dx                        // d11 (double)
lastDx = Int32(dxS)                                            // fcvtzs (trunc)
lastDy = naturalScrolling ? -dy : dy                           // cneg
```
For t == 3 the code instead uses `d11 = Double(lastDx)` and `lastDy` unchanged (0x101661124-0x101661140) **[ASM]**.

### 2.3 Velocity (**[ASM]** 0x1012a8-0x101340, 0x1016614..)
```
decay = exponentialDecay
resX, resY, W=widthInches, H=heightInches (gesture_base)
Vx_in = (Double(lastDx) * decay / resX) / max(W, H)          // [ASM: fdiv by max(W,H)]
Vy_in = (Double(lastDy) * decay / resY) / W                  // [ASM: fdiv by W, NOT max]  ** asymmetry **
period_s = (Double(mpp) / 1000.0) / 1000.0                   // mpp = _microsecondsPerPeriod = 16600 -> 0.0166 s
vX = (period_s != 0) ? Vx_in / period_s : 0                   // stored at [sp+0x18]
vY = (period_s != 0) ? Vy_in / period_s : 0                   // stored at [sp+0x20]
```
Note the Y normalisation uses the *width* not max(W,H). [ASM 0x101661308 `fdiv d0,d0,d2` with d2=widthInches]. Likely intentional or a real quirk; confirm dynamically.

Sanity: `period_s` (0.0166 s) differs from timer interval (0.0162048 s); mpp is 16.6 ms.

### 2.4 Per-axis gating and smoothing (**[ASM]** 0x101661468-0x101661650)
```
horizDominant = |lastDx| > |lastDy|     (fabs of double values)
scrollVelocityX = horizDominant ? vX * unitInches : 0
scrollVelocityY = !horizDominant ? vY * unitInches : 0
```
Smoothing (applied to the raw velocities above):
```
// accel: peak-hold with 0.99 decay
accelX = accelX * 0.99 + scrollVelocityX * 0.01
if |accelX| < |scrollVelocityX| then accelX = scrollVelocityX
accelY: same with Y

// swipe: EMA alpha 0.2
swipeX = swipeX * 0.8 + scrollVelocityX * 0.2
swipeY = swipeY * 0.8 + scrollVelocityY * 0.2
```
Checked: 0x3fe999999999999a = 0.8, 0x3fc999999999999a = 0.2, 0x3fefae147ae147ae = 0.99, 0x3f847ae147ae147b = 0.01 **[ASM]**.

Then (**[ASM]** 0x101661650-0x101661688):
```
mult = +[gesture_scroll_helper multiplierBasedOnOrthagonalityAndSpeedWithX:scrollVelocityX Y:scrollVelocityY]
scrollVelocityX *= mult ; scrollVelocityY *= mult
```
Then screen conversion (**[ASM]** 0x101661688-0x1016616c0):
```
fX = +[gesture_scroll_helper screenIPSFromFingerIPS:scrollVelocityX smoothed:accelX scrollSpeed:scrollSpeed]
fY = ... same with (scrollVelocityY, accelY, scrollSpeed)
X_px = 100.0 * period_s * fX      // d8 (overwrites emit)
Y_px = 100.0 * period_s * fY      // d9
```
Helper bodies are outside this scope (gesture_scroll_helper, other agent).

### 2.5 Inject frame, wheel path (t != 3, **[ASM]** 0x101661900-0x101661a54)
```
if X_px == 0 && Y_px == 0: skip
if wheelInertiaCallbackTime != 0: skip (inertia owns the stream)   // [ASM 0x101661910-0x1016619c8]
phase = (wheelScrollPhase != 0) ? 2 : 1 ; wheelScrollPhase = phase
Inject(X: X_px, Y: Y_px, XInches: |period_s * scrollVelocityX|, YInches: |period_s * scrollVelocityY|,
       scrollphase: phase, inertia: 0, timestamp: lastGestureNs, pageswipe: localAppCurtainSwipe, applyHysteresis: true)
```

### 2.6 Page swipe (t reached the AppSwipe call, **[ASM]** 0x101661400-0x101661420)
```
if |emitX| > |emitY|  horizontal = true  (fcmp d12,d14 -> cset gt)     [note: uses |0.5a|, |0.5b|]
deliberateEnd = end = (t == 3)
actiontime = lastGestureNs (after update)
[injector InjectAppSwipeWithActiontime:actiontime end:end deliberateEnd:end horizontal:h
    dx: 2000.0 * emitX, dy: 2000.0 * emitY, xInches: emitX, yInches: emitY]
```
Only called with the emit values, before the `curtain`/inertia code. (Asm: `bl _objc_msgSend$InjectAppSwipeWithActiontime:...` at 0x101661420, args `d0=d8*2000`, `d1=d9*2000`, `d2=d8`, `d3=d9`, `x4=end`, `x3=end`, `x2=actiontime`, `w5 horizontal`.)

After the call, (**[ASM]** 0x101661424-0x1016614a4) when t reached the reset path (`firstFlag` from t==1 is set): `scrollVelocityX/Y`, `accelX/Y`, `wheelInertiaX/Y`, `wheelVerticalDistance` are zeroed. (Zeroing only if firstFlag, via w24.)

### 2.7 Anomaly on the end branch (t == 3)
At 0x101661358-0x1016613b8 the end branch executes `ldr w8, [x19, x22]` where `x22` is not the lastGesture offset (x22 holds dy or log state at that point). The result is then multiplied by 1000 and added to `lastGestureNs`. The arm64 is unambiguous, but the intent is unclear. **[OPEN]** Verify dynamically: does lastGestureNs jump at end?

### 2.8 wheelVerticalDistance and boost
`wvd` (ivar 0xb74) is updated in the non-zeroed path (0x101661488-0x101661504, **[ASM]** but control flow ambiguous). Summary:
```
d13 = (|dx| > |dy|) ? 0 : decay * Double(lastDy)  (fcsel gt)
if d13 != 0: s = sign(d13) in {+1,-1}; wvd = (sign conditions, see asm) ; wvd += s * unitInches
```
**[OPEN]** The sign-reset condition at 0x101661488-0x1016614e0 is ambiguous (positive d13 appears to zero wvd, negative accumulates). Confirm dynamically before relying on it.

Boost (**[ASM]** 0x101661778-0x1016617a0), only on the end path with inertia:
```
boostCand = Int32(min(5.0*|wvd|, |Y_px|/10.0, 10.0))
wheelInertiaBoost = max(wheelInertiaBoost, boostCand)     // only raised, reset elsewhere
```

---

## 3. Inertia (end path, requestWheelInertiaCallback and processWheelInertia)

### 3.1 Entry (end, t == 3, **[ASM]** 0x101661730-0x101661a5c)
```
if scrollingInertia && (X_px^2 + Y_px^2) > 4.0:
    wheelInertiaX = X_px ; wheelInertiaY = Y_px ; boost = max(boost, boostCand)
    if wheelInertiaCallbackTime == 0:
        if wheelScrollPhase != 0: Inject(0,0,0,0, phase 4, inertia 0, ts lastGestureNs, pageswipe, hyst)  ; wheelScrollPhase = 0
        wheelInertiaTerminate = false ; wheelInertiaPhase = 0
        requestWheelInertiaCallback(12_000_000 ns, curtime: lastGestureNs, why: "...")
```
Phase-4 end inject with real displacements also happens earlier (0x101661708-0x10166171c, only if wheelScrollPhase != 0).

### 3.2 requestWheelInertiaCallback:curtime:why: (0x101662518, **[ASM]**)
```
delayS = (delayNs / 1e9) > 0 ? delayNs/1e9 : 1e-4
if callbackTime != 0: log "Abandoning"; identifier += 1
callbacksActive += 1
callbackTime = curtime + delayNs
performSelector(@selector(processWheelInertiaCallback:), withObject: @(identifier), afterDelay: delayS)
```
Note: `callbackTime` is set even if one was already pending.

### 3.3 processWheelInertiaCallback:(NSNumber id) (0x101661f90, **[ASM]**)
```
objc_sync_enter(self)
now = upTimeInNanoSeconds()
if id.intValue == identifier:
    if callbackTime == 0: log "...callbacktime is set to 0"; (no processing)
    else:
        due = callbackTime ; callbackTime = 0 ; identifier = id + 1
        processWheelInertia(due, curtime: now)          // first arg = due (old callbackTime)
        callbacksActive -= 1
else: log "Ignoring ... callbackid is now"
objc_sync_exit
```
Stale callbacks are rejected by identifier, so the identifier is the cancellation token.

### 3.4 processWheelInertia:curtime: (0x101661ac4, **[ASM]**)
```
// due = first arg (x19), now = curtime
if wheelInertiaPhase <= 1: wheelInertiaPhase += 1        // 0->1, 1->2, stays 2
if boost > 0:
    boost -= 1
    X /= 0.955 ; Y /= 0.955                               // boost keeps speed up
else:
    X = X * (0.955 * |X| / (|X| + 0.07))                  // soft-threshold decay
    Y = Y * (0.955 * |Y| / (|Y| + 0.07))
// terminate test (two-branch: stop-band or wheelInertiaTerminate)
if wheelInertiaTerminate: terminate = true
else if (-0.04 <= X <= 0.04) && (-0.04 <= Y <= 0.04): terminate = true
if !terminate:
    Inject(X: 100*X*0.012, Y: 100*Y*0.012, XInches: |X|*0.012, YInches: |Y|*0.012,
           scrollphase: 0, inertia: wheelInertiaPhase, timestamp: due, pageswipe: localAppCurtain, hyst: true)
    requestWheelInertiaCallback(12ms, curtime: due, why)
else:
    wheelInertiaPhase = 3
    Inject(X: 0, Y: 0, XInches: |X|*0.012, YInches: |Y|*0.012, scrollphase: 0, inertia: 3, timestamp: due, ...)
    (no further request -> momentum ends)
```
Constants: all **[ASM]**. The `scrollphase` 0 and `inertia` = momentum phase index is the key contract for the injector (see section 4).

**[INF]** the ~12 ms request after `due` gives roughly one callback per 12 ms; the stepping is `due`-anchored (not `now`-anchored).

**[OPEN]** Where `wheelInertiaTerminate` is set to true (grep for writes to offset 0xb84 across the binary). The wheel path only clears it. Likely set by a user-interrupt path (e.g. a new scroll begins while inertia runs).

---

## 4. Injector: `-[injector InjectScrollX:Y:XInches:YInches:scrollphase:inertia:timestamp:pageswipe:applyHysteresis:yFixedLineFactor:]` (0x10167d920, **[ASM]**)

Arguments: d0 = X, d1 = Y, d2 = XInches, d3 = YInches, d4 = yFixedLineFactor (the 5-arg variant without it is 0x10167d918 which forwards with factor 1.0 in the caller **[INF]**). x2 = scrollphase, x3 = inertia, x4 = timestamp, x5 = pageswipe, x6 = applyHysteresis.

Prologue mapping: `d11=X, d10=Y, d9=YInches, d8=yFixedLineFactor, q2 stored at [sp+0x50] (XInches), x23=scrollphase, x20=inertia, x25=timestamp, x28=pageswipe, x24=hyst`.

### 4.1 Preference and flag reads
- `CFPreferencesGetAppBooleanValue("closeViewScrollWheelToggle", "com.apple.universalaccess")` -> ivar 0x6a. 
- `CFPreferencesGetAppIntegerValue("closeViewScrollWheelModifiersInt", ...)` -> ivar 0x6c, default `0x40000` (kCGEventFlagMaskControl) when toggle is off. **[ASM]**
- `fullScreenZoomModifierPressed` (0x10167d868): if ivar 0x6a and modifierFlags match the stored mask -> zoom is "pressed" -> byte 0x71 is used instead of 0x20 for the natural flag and field 0x37 is set. **[PSEUDO+ASM]**

### 4.2 Event construction (single CGEvent per call, **[ASM]** 0x10167e8dc-0x10167ea54)
```
ev = CGEventCreateScrollWheelEvent(NULL, units: 0 (kCGScrollEventUnitPixel), wheelCount: 2, wheel1: w24, wheel2: w22)
if fullScreenZoomModifierPressed:  SetIntegerField(ev, 55 (0x37), 28)
SetIntegerField(ev, 99 (0x63), pageswipe ? Int64(scrollphase) : 0)    // ScrollPhase
SetIntegerField(ev, 123 (0x7b), Int64(inertia))                       // MomentumPhase (1/2/3)
SetIntegerField(ev, 137 (0x89), naturalFlagByte)                      // see 4.1 (0x20 or 0x71)
  -- axis 1 (vertical) and 2 (horizontal) line / fixed / point fields --
SetIntegerField(ev, 11 (0xb),  Int64(lineY))                          // DeltaAxis1 (line)
SetIntegerField(ev, 12 (0xc),  Int64(lineX))                          // DeltaAxis2 (line)
SetIntegerField(ev, 93 (0x5d), Int64(trunc(65536.0 * roundY * yFixedLineFactor)))   // FixedPtDeltaAxis1
SetIntegerField(ev, 94 (0x5e), Int64(trunc(65536.0 * roundX)))                       // FixedPtDeltaAxis2
SetIntegerField(ev, 96 (0x60), Int64(pointY))                         // PointDeltaAxis1
SetIntegerField(ev, 97 (0x61), Int64(pointX))                         // PointDeltaAxis2
```
The FixedPt fields are written with the Integer setter (not SetDoubleValueField), value = `fcvtzs` then `sxtw`. **[ASM]**

`roundY = frinta(Y)`, `roundX = frinta(X)` (round half away) in the non-hysteresis branch **[ASM 0x10167e9b0-0x10167e9b4]**. In the hysteresis branch the values come from the accumulator section (4.4).

Units: `CGEventCreateScrollWheelEvent` is called with **pixel** units and wheel1/wheel2 as initial values, then every field is overwritten by the Set calls above. The effective payload is the field values, not the constructor values. **[ASM]**

### 4.3 Timestamp, post, and CreateData (**[ASM]** 0x10167eb48-0x10167eba4)
```
CGEventSetTimestamp(ev, upTimeInNanoSeconds())                // NOT the timestamp argument
if ivar 0x21 (silent) == 0: CGEventPost(kCGHIDEventTap = 0, ev)
data = CGEventCreateData(NULL, ev); CFRelease(data)           // created and immediately released
CFRelease(ev)
```
The `timestamp` argument is used only for logs and in the caller-supplied `lastGestureNs` channel; it does not become the CGEvent timestamp in this function **[ASM]**.

Event tap: `kCGHIDEventTap` (0). Event source: `NULL` (`CGEventCreateScrollWheelEvent(0x0,...)`). **[ASM]**

### 4.4 Accumulators and remainder (**[PSEUDO]**, partially decoded)
Ivars (byte offsets, **[ASM]** from init/set): `0x28` (double, two doubles 0x28/0x30 zeroed), `0x38` (LastDir X ±1.0), `0x40` (LastDir Y ±1.0), `0x48` (accum pixels X), `0x50` (accum pixels Y), `0x58` (accum inch X), `0x60` (accum inch Y).
- Direction reset: when accum sign and the new sign differ (or `LastDir` changes), the pixel and inch accumulators for that axis are zeroed. **[PSEUDO]**
- `accumX += dxPixels; accumY += dyPixels` (pixel), `accumInchX/Y += inches`.
- Line emit: when the inch accumulator exceeds `0.02` (double 0x3f947ae147ae147b) **and** the modf fraction is below the float thresholds `0.06f/0.005f`, the integer line count is `trunc(accumPixels / 10.0)` (10 px per line, double 0x4024000000000000), and that axis accumulator is cleared. **[PSEUDO]**
- `modf` split: integer part -> line/point delta; fraction carried. **[PSEUDO]**

Status: the exact composition of `PointDeltaAxis1/2` (w24/w22) and `LineY/LineX` (`d13`/`d9`) from these accumulators is **[OPEN]**; the hysteresis branch (applyHysteresis, global `hysteresis_switch` at 0x1034c3a00) also feeds into it. The pseudo has too many duplicated branches to decode safely in this pass.

### 4.5 Hysteresis
`applyHysteresis` selects the hysteresis path; `hysteresis_switch` is a global singleton created in `-[injector initWithUnit:width:height:]` (0x10167d4f4) with `initWithRatio:timeConstant:priorityRatio:` **[ASM/PSEUDO]**. Its per-axis state machine is outside this scope (another agent).

### 4.6 Silent flag and debug
`setSilent:` sets ivar 0x21. `setInjectFloatLineValues:` sets 0x22. `setNaturalScrolling:` sets 0x20. `SetSamePointsInNextEvent:` sets 0x68. **[ASM]**

---

## 5. Page swipe / gesture injection (`-[injector InjectAppSwipeWithActiontime:...]`, 0x10167ec98) and InjectEventType

- `InjectAppSwipeWithActiontime:end:deliberateEnd:horizontal:dx:dy:xInches:yInches:` drives a `hysteresis_switch` (`doingFirst`, `doingSecond`, `progressFirst:`, `endFirst`) and calls `[self InjectEventType:0x1d subtype:... begend:... actiontime: ... fingertime: ... swipemask: ... motion: ... dx dy progress vx vy cx cy]`. **[ASM]** (asm symbols at 0x10167ec98, 719 lines).
- `InjectEventType:0x1d` = NSEventTypeGesture (29). Subtypes seen: 0x6 (dock swipe), 0x0 (plain gesture frame). begend values: 0x0 (begin/change), 0x3d and 0x3e (end variants), per Hopper call sites **[PSEUDO]**.
- The base class `-[injector InjectEventType:...]` (0x10167d724) is a **no-op** that sets the global byte `0x1034c39f8 = 1` **[ASM]**. Real work is in `-[injector_1012 InjectEventType:...]` (**[PSEUDO]**). injector_1013 and injector_1300 do not override InjectEventType (only `injectNotificationCenterToggle`/`isNotificationCenterOpen`), so they inherit the 1012 behaviour (inheritance chain to confirm **[OPEN]**).
- `injector_1012 InjectEventType` builds a **raw CFData** with `CFDataCreateMutable`, then appends fixed-width records (`CFDataAppendBytes`): 2-byte marker `0x0100` (big-endian per `rev` on float fields), 1-byte fields from stack, 4-byte big-endian float32 (`fcvt s, d` then `rev w`) for dx/dy/progress/vx/vy/cx/cy, and per-touch records of 0x1c (28) bytes. Event is then `CGEventCreateFromData(NULL, data)`, `CGEventSetTimestamp(upTimeInNanoSeconds())`, `CGEventPost(0, ev)` unless `silentPlayback`. **[PSEUDO]** The exact byte layout of each record is not fully decoded here **[OPEN]** (needed for a Swift port of dock-swipe).
- `frameStart` clears the global byte 0x1034c39f8 (0x10167d5f8). `frameEndTime:fingertime:unit:width:height:fingers:fingercount:` averages finger velocities into globals at 0x1034c3a08 and calls `InjectEventType:0x1d subtype:0 begend:0` as a frame marker **[PSEUDO]**.

---

## 6. Per-macOS injector selection (`+[injector_factory newInjectorWithUnit:width:height:]`, 0x101683964, **[ASM+PSEUDO]**)

```
v = [system_version_util packedOSVersion]     // appears BCD-like: major<<16 | minor<<8 | patch  [INF]
if (v >> 16) >= 0x12:  injector_1300   // macOS 12+ by BCD reading [INF]
elif v >= 0x101300:    injector_1013   // macOS 10.13 .. 11.x     [INF]
else:                  nil             // older                  [INF]
```
Consequences **[INF]**:
- `injector_1012` is never created by the factory (dead unless another path allocates it). Its InjectEventType is therefore only reachable through inheritance.
- Subclass differences (1013 vs 1300) are only the notification-centre code:
  - `injector_1013 injectNotificationCenterToggle` (0x101682f84): `AXIsProcessTrustedWithOptions` prompt, then `NSAppleScript` "click menu bar item 1 of menu bar 1 of application process SystemUIServer" in System Events.
  - `injector_1300 isNotificationCenterOpen` (0x10168324c): spdlog-logged query; uses the 1012 base for everything else.
- Base injector and 1012 share everything else in this scope.

**[OPEN]** Confirm `packedOSVersion` encoding by running `[system_version_util packedOSVersion]` in a sandbox, or by reading its implementation.

---

## 7. C++ glue (decomp/glue, **[PSEUDO]** but simple)

| function | VA | behaviour |
|---|---|---|
| `logi::gestures::gestures::set_smooth_scrolling(bool)` | 0x10166ee08 | writer lock; stores byte at `gestures+0x8c` |
| `logi::gestures::gestures::smooth_scrolling()` | 0x101673410 | reader lock; reads byte `gestures+0x8c` |
| `logi::gestures::gestures::set_wheel_stop_time(float)` | 0x1016742c0 | `post_main_run_loop_job` (wheel stop time set on main run loop) |
| `logi::gestures::gestures::wheel_stop_time()` | 0x101674394 | on main thread: `[wheelHandler wheelStopTime]`; else `dispatch_sync(main)` |
| `logi::gestures::gestures::scroll(int, int, int, uint64, double)` | 0x101670570 | logs `gestures::scroll (dx, dy)`; `[wheelHandler setYFixedLineFactor:d0]`; `[wheelHandler onMouseWheelWithPeriod:a3 deltaV:a2 deltaH:a1 timestamp:ts]` |
| `logi::scrolling::scroll_manager::simulate_mouse_vertical_wheel_input(...)` | 0x101bf9188 | `set_scroll_speed`, `set_smooth_scrolling`, `set_wheel_multiplier` (if flag), then `gestures::scroll(...)` |
| `logi::siminput::endpoint_impl::on_scroll_inertia(request)` | 0x1011f0698 | replies `BoolValue(scroll_touchpad_inertia_active())` |

Interface notes **[PSEUDO]**:
- `gestures::scroll` argument order: the caller's `(w22, w23)` vs callee `(a1, a2)` mapping to `deltaH`/`deltaV` is not unambiguous from the pseudocode. Verify against the caller before implementing.
- The `smooth_scrolling` flag is read from `gestures+0x8c`. `simulate_mouse_vertical_wheel_input` sets it from `r25[0x1d]` (decompiler mangling; exact field to verify).

### Per-application exceptions found
- `adobe_acrobat_helper` (`gestures/adobe_acrobat_helper_*.m`): recognises `com.adobe.Reader` and `com.adobe.Acrobat.Pro` via `isAdobeAcrobat` and `isAdobeAcrobatRunningForeground` (uses scroll manager's foreground process info). The wheel handler has `determineAdobeReaderRunning` / `forceWheelDisturbanceFilter` (other agent).
- `set_foreground_process_info` (glue) feeds the foreground process to `siminput` **[PSEUDO]**.
- No browser-specific branch found in this scope.

---

## 8. Per-platform/touchpad notes (only where shared)
- `gesture_handler_2_finger_scroll_touchpad` has its own `initInertia:`, `processWheelInertia:`, `requestWheelInertiaCallback:`, and `stopScrollInertia`. Not expanded here. The touchpad inertia model (`convertDistanceToInertia:`) was not inspected in this pass **[OPEN]**.
- `injectFakePhasedScrolling:` exists on the touchpad class and likely calls the same `InjectScrollX...` selector **[INF]**.

---

## 9. CGEvent field table (scroll wheel injector, per call)

| field (dec / hex) | name (CG) [INF unless noted] | value | notes |
|---|---|---|---|
| 11 / 0xb | ScrollWheelEventDeltaAxis1 (line, vertical) [INF] | trunc of line accum | [ASM set]; value [PSEUDO] |
| 12 / 0xc | ScrollWheelEventDeltaAxis2 (line, horizontal) [INF] | trunc of line accum | [ASM set]; value [PSEUDO] |
| 55 / 0x37 | (unknown) | 28 | only when fullScreenZoomModifierPressed |
| 93 / 0x5d | ScrollWheelEventFixedPtDeltaAxis1 [INF] | trunc(65536 * roundY * yFixedLineFactor) | non-hyst branch [ASM] |
| 94 / 0x5e | ScrollWheelEventFixedPtDeltaAxis2 [INF] | trunc(65536 * roundX) | non-hyst branch [ASM] |
| 96 / 0x60 | ScrollWheelEventPointDeltaAxis1 [INF] | pointY (w24) | [ASM set]; value [OPEN] |
| 97 / 0x61 | ScrollWheelEventPointDeltaAxis2 [INF] | pointX (w22) | [ASM set]; value [OPEN] |
| 99 / 0x63 | ScrollPhase | pageswipe ? scrollphase : 0 | [ASM] (1 began, 2 changed, 4 ended; 0 momentum) |
| 123 / 0x7b | MomentumPhase | inertia (1 begin, 2 continue, 3 end) | [ASM] |
| 137 / 0x89 | (natural/inverted flag) [INF] | byte injector+0x20 (or +0x71 under zoom) | [ASM] |
| 137? / 138 | not set in this function | - | user note said 137/138; only 137 observed here |

Event creation: `CGEventCreateScrollWheelEvent(NULL, 0 (pixel), 2, w24, w22)`. Post: `CGEventSetTimestamp(upTimeInNanoSeconds())` then `CGEventPost(kCGHIDEventTap=0)` unless silent. **[ASM]**

Gesture (dock swipe) events: built as raw CFData, `CGEventCreateFromData`, `CGEventSetTimestamp`, `CGEventPost(0)`. Field layout **[OPEN]**.

---

## 10. Open questions / to verify dynamically
1. `scheduled` end-branch `x22` load (2.7): does `lastGestureNs` jump on end?
2. `wheelVerticalDistance` sign/reset logic (2.8).
3. Y normalisation uses width, not max(W,H) (2.3). Intended?
4. Writers of `wheelInertiaTerminate` (0xb84). Not found in this scope.
5. Thread model: NSTimer and `performSelector:afterDelay:` on which run loop? `objc_sync` only protects the callback.
6. Injector accumulator composition (4.4) and the `PointDelta*` / line values (needs a second pass with the full `InjectScroll` asm, lines ~1-960 of `asm/injscroll_yflf.s`).
7. CFData byte layout for dock-swipe (5). Needed for a faithful Swift port of page swipe.
8. `packedOSVersion` encoding (6).
9. Selector identity for the NSTimer target (`scheduledTimerWithTimeInterval:target:selector:` in `onGestureScrollEventType`, selref at 0x103255038) is assumed to be `onScrollTimer:`. Not resolved **[INF]**.

## 11. Swift skeleton (direct transcription of verified parts)

```swift
// Constants (all verified in asm)
let kMicrosecondsPerPeriodDefault: Int32 = 16600
let kTimerInterval: TimeInterval = 0.01620482120513916
let kDivisor: Double = 180.0
let kDecayFactor: Double = 0.15
let kGrowThreshold: Double = 0.99
let kGrowFraction: Double = 0.3
let kNoReportsForDecay: Int32 = 5
let kEmitFraction: Double = 0.3
let kInertiaK: Double = 0.955
let kInertiaC: Double = 0.07
let kStopBand: Double = 0.04
let kPxScale: Double = 100.0
let kInertiaInchScale: Double = 0.012
let kInertiaCallbackNs: UInt64 = 12_000_000
let kMinCallbackS: Double = 1e-4
let kFixedPt: Double = 65536.0
let kLinePixels: Double = 10.0
```

Swift algorithm for `scheduled` (wheel, t != 3) and inertia, in the order above, is a direct port of sections 2.1-2.5 and 3.3-3.4. Port the velocity model (2.3) with the Y/W normalisation kept as in asm until dynamic verification.
