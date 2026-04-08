// hello.c
#include <stdio.h>

int main() {
    char buf[256];
    printf("Enter your name: ");
    fflush(stdout);
    fgets(buf, sizeof(buf), stdin);
    printf("Hello, %s", buf);
    return 0;
}
