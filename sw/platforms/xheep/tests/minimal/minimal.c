// minimal.c — simplest possible baremetal test: just write to exit address
#define EXIT_ADDR ((volatile int*)0xF0000000)

int main(void) {
    *EXIT_ADDR = 1;  // EXIT_SUCCESS
    while(1) {}
    return 0;
}