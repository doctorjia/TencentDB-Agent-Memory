#!/usr/bin/env bash
# SWE-bench multi-instance same-session experiment
# Tests: L0-L3 recall ordering, Mermaid creation, code handling
# All instances use SAME session-id to test recall cross-instance behavior

SESSION_ID="swe-bench-multi-001"
LOG_DIR="/tmp/swe-bench-multi-logs"
mkdir -p "$LOG_DIR"

echo "=== SWE-bench Multi-Instance Same-Session Experiment ==="
echo "Session ID: $SESSION_ID"
echo "Time: $(date)"
echo ""

# --- INSTANCE 1: sympy Piecewise bug ---
echo ">>> Instance 1: sympy__sympy-20049 (Piecewise/integrate) <<<"
OPENCLAW_TDAI_DEBUG=1 OPENCLAW_DEBUG=1 openclaw agent \
  --session-id "$SESSION_ID" \
  --message "sympy issue: Piecewise expression incorrectly simplifies when conditions involve relational operators. Example: from sympy import Piecewise, symbols, integrate; x = symbols('x'); f = Piecewise((x**2, x > 0), (0, True)); result = integrate(f, (x, -1, 1)); print(result) gives wrong answer. The integrate function fails to respect the piecewise boundary at x=0. Expected: 1/3, Actual: 0 or error. This affects sympy/integrals/integrals.py in the _eval_integral method when handling Piecewise." \
  2>&1 | tee "$LOG_DIR/instance1-sympy.log"

echo ""
echo "Sleeping 3s..."
sleep 3

# --- INSTANCE 2: matplotlib constrained_layout bug ---
echo ">>> Instance 2: matplotlib__matplotlib-18869 (tight_layout warning) <<<"
OPENCLAW_TDAI_DEBUG=1 OPENCLAW_DEBUG=1 openclaw agent \
  --session-id "$SESSION_ID" \
  --message "matplotlib issue: UserWarning is raised when both tight_layout() and constrained_layout=True are used together. The warning 'tight_layout : falling back to Matplotlib tight_layout' appears even when constrained_layout should take precedence. In matplotlib/figure.py, the draw() method incorrectly triggers tight_layout processing when constrained_layout is already enabled. Fix should suppress the tight_layout call (and warning) when figure.get_constrained_layout() returns True." \
  2>&1 | tee "$LOG_DIR/instance2-matplotlib.log"

echo ""
echo "Sleeping 3s..."
sleep 3

# --- INSTANCE 3: Same domain as prior session (astropy) to test recall ---
echo ">>> Instance 3: astropy__astropy-13236 (WCS coordinate handling) <<<"
OPENCLAW_TDAI_DEBUG=1 OPENCLAW_DEBUG=1 openclaw agent \
  --session-id "$SESSION_ID" \
  --message "astropy issue: WCS.all_pix2world() returns incorrect coordinates when using SIP distortion coefficients with non-square images. The distortion matrix computation in astropy/wcs/wcs.py does not properly handle cases where NAXIS1 != NAXIS2. Expected: correct sky coordinates matching DS9 output. Actual: coordinates offset by several arcseconds. Affects WCS.sip_foc2pix() method." \
  2>&1 | tee "$LOG_DIR/instance3-astropy.log"

echo ""
echo "=== Experiment complete. Logs in $LOG_DIR ==="
