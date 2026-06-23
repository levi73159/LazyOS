// hello.c
#include <ctype.h>
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
        printf("opened test.msg\n");
        char buf[256];
        while (fgets(buf, sizeof(buf), f)) {
            printf("%s", buf);
        }
        fclose(f);
    } else {
        return -1;
    }

    printf("That crazy!, the filesystem is working for a change\n");
    printf("Yay or nay?\n");
    fgets(buf, sizeof(buf), stdin);
    if (tolower(buf[0]) == 'y') {
        printf("Im glad your happy!\n");
    } else {
        printf("GO FUCKING KILL YOURSELF\n");
    }
    return 0;
}
