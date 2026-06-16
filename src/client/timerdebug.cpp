#include "timerdebug.h"
#include <stdio.h>
#include <time.h>

void timerDebug(const char* msg)
{
    static FILE* file = nullptr;
    if (!file) {
        file = fopen("timer_debug.log", "a");
        if (file) {
            // Write a header so we know the file was opened
            fprintf(file, "=== timer_debug initialized ===\n");
            fflush(file);
        }
    }
    if (file) {
        time_t now = time(nullptr);
        char buf[24] = {};
        strftime(buf, sizeof(buf), "%H:%M:%S", localtime(&now));
        fprintf(file, "[%s] %s\n", buf, msg);
        fflush(file);
    }
}
