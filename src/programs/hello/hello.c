// hello.c
#include <stdio.h>
#include <stdlib.h>

int main() {
    char buf[256];
    printf("Enter your name: ");
    fflush(stdout);
    fgets(buf, sizeof(buf), stdin);
    printf("Hello, %s", buf);

    FILE *f = fopen("/boot/test/test.msg", "r");
    if (f) {
        char buf[256];
        while (fgets(buf, sizeof(buf), f)) {
            printf("%s", buf);
        }
        fclose(f);
    }
    return 0;
}
