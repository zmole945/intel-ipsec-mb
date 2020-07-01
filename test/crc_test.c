/*****************************************************************************
 Copyright (c) 2020, Intel Corporation

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

     * Redistributions of source code must retain the above copyright notice,
       this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of Intel Corporation nor the names of its contributors
       may be used to endorse or promote products derived from this software
       without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*****************************************************************************/

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include <intel-ipsec-mb.h>

#include "utils.h"

int crc_test(struct IMB_MGR *mb_mgr);

static uint32_t m_lut[256];
static struct IMB_MGR *p_mgr;

/**
 * @brief Reflects selected group of bits in \a v
 *
 * @param v value to be reflected
 * @param n size of the bit field to be reflected
 *
 * @return bit reflected value
 */
static uint64_t
reflect(uint64_t v, const uint32_t n)
{
        uint32_t i;
        uint64_t r = 0;

        for (i = 0; i < n; i++) {
                if (i != 0) {
                        r <<= 1;
                        v >>= 1;
                }
                r |= (v & 1);
        }

        return r;
}

/**
 * @brief Initializes reflected look-up-table (LUT) for given 32 bit polynomial
 *
 * @param poly CRC polynomial
 * @param rlut pointer to reflected 256x32bits look-up-table to be initialized
 */
static void
crc32_ref_init_lut(const uint32_t poly, uint32_t *rlut)
{
        uint_fast32_t i, j;

        if (rlut == NULL)
                return;

        for (i = 0; i < 256; i++) {
                /**
                 * i = reflect_8bits(i);
                 * crc = (i << 24);
                 */
                uint_fast32_t crc = (uint32_t) reflect(i, 32);

                for (j = 0; j < 8; j++) {
                        if (crc & 0x80000000UL)
                                crc = (crc << 1) ^ poly;
                        else
                                crc <<= 1;
                }

                rlut[i] = (uint32_t) reflect(crc, 32);
        }
}

/**
 * @brief Calculates 32 bit reflected CRC using LUT method.
 *
 * @param crc CRC initial value
 * @param data pointer to data block to calculate CRC for
 * @param data_len size of data block
 * @param reflected lut 256x32bits look-up-table pointer
 *
 * @return New CRC value
 */
static uint32_t
crc32_ref_calc_lut(const uint8_t *data,
                   uint64_t data_len,
                   uint32_t crc,
                   const uint32_t *rlut)
{
        if (data == NULL || rlut == NULL)
                return crc;

        while (data_len--)
                crc = rlut[(crc ^ *data++) & 0xffL] ^ (crc >> 8);

        return crc;
}

/**
 * @brief Function randomizing buffer contents
 *
 * @param p pointer to the buffer
 * @param len number of bytes to be randomized
 */
static void
randomize_buffer(void *p, size_t len)
{
        uint8_t *p_byte = (uint8_t *) p;

        while (len--)
                *p_byte++ = (uint8_t) rand();
}

/**
 * @brief 32-bit polynomial CRC test function
 *
 * @param fn_crc_setup function to be called before the test for setup purpose
 * @param fn_crc_calc reference function computing CRC value
 * @param fn_crc tested CRC function (against the reference one)
 * @param title string banner printed on the screen
 *
 * @return test status
 * @retval 0 OK
 * @retval 1 error
 */
static int
test_crc_polynomial(void (*fn_crc_setup)(void),
                    uint32_t (*fn_crc_calc)(const void *, uint64_t),
                    uint32_t (*fn_crc)(const void *, uint64_t),
                    const char *title)
{
        uint8_t buffer[2048];
        size_t n;

        if (fn_crc_setup == NULL || fn_crc_calc == NULL ||
            fn_crc == NULL || title == NULL) {
                printf("crc_test: NULL parameter passed!\n");
                return 1;
        }

        printf("Starting CRC Test: %s\n", title);

        fn_crc_setup();

        for (n = 1; n < sizeof(buffer); n++) {
                uint32_t reference_crc, received_crc;

                randomize_buffer(buffer, n);
                reference_crc = fn_crc_calc(buffer, (uint64_t) n);
                received_crc = fn_crc(buffer, (uint64_t) n);

                if (reference_crc != received_crc) {
                        printf("! CRC mismatch for buffer size %lu, "
                               "received = 0x%lx, expected = 0x%lx\n",
                               (unsigned long) n,
                               (unsigned long) received_crc,
                               (unsigned long) reference_crc);
                        hexdump(stdout, "", buffer, n);
                        return 1;
                }
        }

        return 0;
}

/**
 * @brief CRC32 Ethernet FCS setup function
 */
static void
crc32_ethernet_fcs_setup(void)
{
        crc32_ref_init_lut(0x04c11db7UL, m_lut);
}

/**
 * @brief CRC32 Ethernet FCS reference calculation function
 *
 * @param p pointer to the buffer to calculate CRC on
 * @param len size of the buffer
 *
 * @return CRC value
 */
static uint32_t
crc32_ethernet_fcs_ref_calc(const void *p, uint64_t len)
{
        return ~crc32_ref_calc_lut(p, len, 0xffffffffUL, m_lut);
}

/**
 * @brief CRC32 Ethernet FCS tested calculation function
 *
 * @param p pointer to the buffer to calculate CRC on
 * @param len size of the buffer
 *
 * @return CRC value
 */
static uint32_t
crc32_ethernet_fcs_tested_calc(const void *p, uint64_t len)
{
        return IMB_CRC32_ETHERNET_FCS(p_mgr, p, len, NULL);
}

int
crc_test(struct IMB_MGR *mb_mgr)
{
        int errors = 0;

        p_mgr = mb_mgr;

        srand(0x20200701);

        errors += test_crc_polynomial(crc32_ethernet_fcs_setup,
                                      crc32_ethernet_fcs_ref_calc,
                                      crc32_ethernet_fcs_tested_calc,
                                      "CRC32 ETHERNET FCS 0x04c11db7");

	if (0 == errors)
		printf("...Pass\n");
	else
		printf("...Fail\n");

	return errors;
}