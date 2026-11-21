cd /tmp
xcrun clang -O1 va.c -o va && ./va
xcrun clang -g -fsanitize=thread tsan.c -o tsan 2>&1 | tail -2; ./tsan > /tmp/tsan.out 2>&1; echo "tsan rc=$?"; grep -E "WARNING: ThreadSanitizer|SUMMARY|shared =|FATAL|failed" /tmp/tsan.out | head -5
xcrun clang -g -fsanitize=address -x c - -o asan <<'C' 2>&1 | tail -2
#include <stdlib.h>
int main(void) { char *p = malloc(8); p[8] = 1; return p[0]; }
C
./asan > /tmp/asan.out 2>&1; echo "asan rc=$?"; grep -E "ERROR: AddressSanitizer|SUMMARY" /tmp/asan.out | head -3
