#ifndef TIMERDEBUG_H
#define TIMERDEBUG_H

#include <cstdio>

// Minimal file-based debug logging — no framework dependencies.
// Writes to timer_debug.log in the current working directory.
// NOT inline — defined in a single .cpp to avoid ODR/static-local issues.
void timerDebug(const char* msg);

#endif
