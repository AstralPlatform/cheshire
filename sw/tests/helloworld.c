// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Nicole Narr <narrn@student.ethz.ch>
// Christopher Reinwardt <creinwar@student.ethz.ch>
//
// Simple payload to test bootmodes

#include "regs/cheshire.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "util.h"

int main(void) {
    char str[] = "Hello World!\r\n";
    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, reset_freq, 115200);
    uart_write_str(&__base_uart, str, sizeof(str));
    

    char rtn[] = "\r\n";

    // Read USB Host Version (offset 11'h000)
    uint32_t* ver_reg = (uint32_t*)0x01001000;
    uint32_t ver = *ver_reg;
    for (int32_t i = 31; i >= 0; --i) {
        uart_write(&__base_uart, (uint8_t)(48 + ((ver >> i) % 2)));
    }
    uart_write_str(&__base_uart, rtn, sizeof(rtn));

    // Read USB Host Vendor ID (offset 11'h040)
    uint32_t* VID_reg = (uint32_t*)0x01001040;
    uint32_t VID = *VID_reg;
    for (int32_t i = 31; i >= 0; --i) {
        uart_write(&__base_uart, (uint8_t)(48 + ((VID >> i) % 2)));
    }
    uart_write_str(&__base_uart, rtn, sizeof(rtn));

    // Read Bus ID (offset 11'h01c)
    uint32_t* BID_reg = (uint32_t*)0x0100101c;
    uint32_t BID = *BID_reg;
    for (int32_t i = 31; i >= 0; --i) {
        uart_write(&__base_uart, (uint8_t)(48 + ((BID >> i) % 2)));
    }
    uart_write_str(&__base_uart, rtn, sizeof(rtn));


    // Test HCControl registers (set and clear) OHCI Spec 5.7

    // Set bits 31, 29, 23, 18, 17 to one
    uint32_t set = 0xA0860620; // 10100000 10000110 00000000 00000000

    uint32_t* HCCset = 0x01001050; // Set register offset 11'h050

    *HCCset = set;

    // Print HCControl
    uint32_t HCC = *HCCset;
    for (int32_t i = 31; i >= 0; --i) {
        uart_write(&__base_uart, (uint8_t)(48 + ((HCC >> i) % 2)));
    }
    uart_write_str(&__base_uart, rtn, sizeof(rtn));


    // Reset bit 29 to zero
    uint32_t clear = 0x80000000; // 10000000 00000000 00000000 00000000

    uint32_t* HCCclear = 0x01001054; // Clear register offset 11'h054

    *HCCclear = clear;

    // Print HCControl
    HCC = *HCCset;
    for (int32_t i = 31; i >= 0; --i) {
        uart_write(&__base_uart, (uint8_t)(48 + ((HCC >> i) % 2)));
    }
    uart_write_str(&__base_uart, rtn, sizeof(rtn));


    uart_write_flush(&__base_uart);
    return 0;
}
