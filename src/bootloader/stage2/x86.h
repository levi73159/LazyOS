#pragma once
#include "stdint.h"

void x86_Video_WriteCharTTY(char c, uint8_t page);
void x86_div64_32(uint64_t dividend, uint32_t divisor, uint64_t* quotientOut, uint32_t* remainderOut);
