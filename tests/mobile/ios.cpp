#include <stdio.h>
extern "C" const char *hxRunLibrary();
extern "C" void hxcpp_set_top_of_stack();
int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    hxcpp_set_top_of_stack();
    const char *error = hxRunLibrary();
    if (error) { fprintf(stderr, "%s\n", error); return 1; }
    return 0;
}
