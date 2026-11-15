/* hello for X16 */
#include <stdio.h>
#include "cx16.h"

#define MAXV 0x1F /* max */

/* multi
   line comment */
static unsigned char counter = 42;

int main(void)
{
    char *s = "Hello, \"X16\"!";   // trailing
    uint16_t i;
    for (i = 0; i < 10; ++i) {
        if (s[i] == 'x') return 1;
    }
    return 0;
}
