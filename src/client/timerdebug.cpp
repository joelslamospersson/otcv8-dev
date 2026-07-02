#ifndef TIMERDEBUG_H
#define TIMERDEBUG_H

#include <cstdio>

// ── Master debug switch for the tooltip/timer diagnostic system ──────────
//
// Set TOOLTIP_DEBUG to 1 to enable verbose logging of:
//   - Item duration tick updates (item.cpp)
//   - Feature negotiation (parseFeatures in protocolgameparse.cpp)
//   - Tooltip UI draw attempts (uiitem.cpp)
//   - All [DES] / [RX] deserialization traces (tooltip.lua)
//
// When 0 (default), every timerDebug() call expands to nothing and its
// arguments are never evaluated — zero runtime overhead.  The function
// definition in timerdebug.cpp is compiled but never called.

#define TOOLTIP_DEBUG 0

#if TOOLTIP_DEBUG
void timerDebug(const char* msg);
#else
#define timerDebug(msg) ((void)0)
#endif

#endif
