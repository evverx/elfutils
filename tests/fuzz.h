#ifndef _FUZZ_H
#define _FUZZ_H	1

#include <stddef.h>
#include <stdint.h>

int LLVMFuzzerTestOneInput (const uint8_t *data, size_t size);

#endif /* fuzz.h */
