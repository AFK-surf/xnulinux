// A data race ThreadSanitizer must report
#include <pthread.h>
#include <stdio.h>
int shared;
static void *bump(void *arg) { (void)arg; for (int i = 0; i < 1000; i++) shared++; return NULL; }
int main(void) {
    pthread_t a, b;
    pthread_create(&a, NULL, bump, NULL); pthread_create(&b, NULL, bump, NULL);
    pthread_join(a, NULL); pthread_join(b, NULL);
    printf("shared = %d\n", shared);
    return 0;
}
