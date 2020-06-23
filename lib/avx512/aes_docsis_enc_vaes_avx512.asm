;;
;; Copyright (c) 2019-2020, Intel Corporation
;;
;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions are met:
;;
;;     * Redistributions of source code must retain the above copyright notice,
;;       this list of conditions and the following disclaimer.
;;     * Redistributions in binary form must reproduce the above copyright
;;       notice, this list of conditions and the following disclaimer in the
;;       documentation and/or other materials provided with the distribution.
;;     * Neither the name of Intel Corporation nor the names of its contributors
;;       may be used to endorse or promote products derived from this software
;;       without specific prior written permission.
;;
;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
;; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
;; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
;; DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
;; FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
;; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
;; CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
;; OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
;; OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;

;;; DOCSIS SEC BPI (AES128-CBC + AES128-CFB) encryption
;;; stitched together with CRC32

%use smartalign

%include "include/os.asm"
%include "imb_job.asm"
%include "mb_mgr_datastruct.asm"
%include "include/reg_sizes.asm"
%include "include/const.inc"
%include "include/clear_regs.asm"
%include "include/aes_common.asm"

%define APPEND(a,b) a %+ b

%define CRC_LANE_STATE_TO_START    0x01
%define CRC_LANE_STATE_DONE        0x00
%define CRC_LANE_STATE_IN_PROGRESS 0xff

struc STACK
_gpr_save:      resq    8
_rsp_save:      resq    1
_idx:           resq    1
_len:           resq    1
endstruc

%ifdef LINUX
%define arg1    rdi
%define arg2    rsi
%define TMP2    rcx
%define TMP3    rdx
%else
%define arg1    rcx
%define arg2    rdx
%define TMP2    rdi
%define TMP3    rsi
%endif

%define TMP0    r11
%define TMP1    rbx
%define TMP4    rbp
%define TMP5    r8
%define TMP6    r9
%define TMP7    r10
%define TMP8    rax
%define TMP9    r12
%define TMP10   r13
%define TMP11   r14
%define TMP12   r15

section .data
default rel

align 16
dupw:
        dq 0x0100010001000100, 0x0100010001000100

align 16
len_masks:
        dq 0x000000000000FFFF, 0x0000000000000000
        dq 0x00000000FFFF0000, 0x0000000000000000
        dq 0x0000FFFF00000000, 0x0000000000000000
        dq 0xFFFF000000000000, 0x0000000000000000
        dq 0x0000000000000000, 0x000000000000FFFF
        dq 0x0000000000000000, 0x00000000FFFF0000
        dq 0x0000000000000000, 0x0000FFFF00000000
        dq 0x0000000000000000, 0xFFFF000000000000

one:    dq  1
two:    dq  2
three:  dq  3
four:   dq  4
five:   dq  5
six:    dq  6
seven:  dq  7

;;; Precomputed constants for CRC32 (Ethernet FCS)
;;;   Details of the CRC algorithm and 4 byte buffer of
;;;   {0x01, 0x02, 0x03, 0x04}:
;;;     Result     Poly       Init        RefIn  RefOut  XorOut
;;;     0xB63CFBCD 0x04C11DB7 0xFFFFFFFF  true   true    0xFFFFFFFF
align 16
rk1:
        dq 0x00000000ccaa009e, 0x00000001751997d0

align 16
rk5:
        dq 0x00000000ccaa009e, 0x0000000163cd6124

align 16
rk7:
        dq 0x00000001f7011640, 0x00000001db710640

align 16
pshufb_shf_table:
        ;;  use these values for shift registers with the pshufb instruction
        dq 0x8786858483828100, 0x8f8e8d8c8b8a8988
        dq 0x0706050403020100, 0x000e0d0c0b0a0908

align 16
init_crc_value:
        dq 0x00000000FFFFFFFF, 0x0000000000000000

align 16
mask:
        dq 0xFFFFFFFFFFFFFFFF, 0x0000000000000000

align 16
mask2:
        dq 0xFFFFFFFF00000000, 0xFFFFFFFFFFFFFFFF
align 16
mask3:
        dq 0x8080808080808080, 0x8080808080808080

align 16
mask_out_top_bytes:
        dq 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF
        dq 0x0000000000000000, 0x0000000000000000

;;; partial block read/write table
align 64
byte_len_to_mask_table:
        dw      0x0000, 0x0001, 0x0003, 0x0007,
        dw      0x000f, 0x001f, 0x003f, 0x007f,
        dw      0x00ff, 0x01ff, 0x03ff, 0x07ff,
        dw      0x0fff, 0x1fff, 0x3fff, 0x7fff,
        dw      0xffff

section .text

;; ===================================================================
;; ===================================================================
;; CRC multiply before XOR against data block
;; ===================================================================
%macro CRC_CLMUL 4
%define %%XCRC_IN_OUT   %1 ; [in/out] XMM with CRC (can be anything if "no_crc" below)
%define %%XCRC_MUL      %2 ; [in] XMM with CRC constant  (can be anything if "no_crc" below)
%define %%XCRC_DATA     %3 ; [in] XMM with data block
%define %%XTMP          %4 ; [clobbered] temporary XMM

        vpclmulqdq      %%XTMP, %%XCRC_IN_OUT, %%XCRC_MUL, 0x01
        vpclmulqdq      %%XCRC_IN_OUT, %%XCRC_IN_OUT, %%XCRC_MUL, 0x10
        vpternlogq      %%XCRC_IN_OUT, %%XTMP, %%XCRC_DATA, 0x96 ; XCRC = XCRC ^ XTMP ^ DATA
%endmacro

;; ===================================================================
;; ===================================================================
;; CRC32 calculation on 16 byte data
;; ===================================================================
%macro CRC_UPDATE16 6
%define %%INP           %1  ; [in/out] GP with input text pointer or "no_load"
%define %%XCRC_IN_OUT   %2  ; [in/out] XMM with CRC (can be anything if "no_crc" below)
%define %%XCRC_MUL      %3  ; [in] XMM with CRC multiplier constant
%define %%TXMM1         %4  ; [clobbered|in] XMM temporary or data in (no_load)
%define %%TXMM2         %5  ; [clobbered] XMM temporary
%define %%CRC_TYPE      %6  ; [in] "first_crc" or "next_crc" or "no_crc"

        ;; load data and increment in pointer
%ifnidn %%INP, no_load
        vmovdqu64       %%TXMM1, [%%INP]
        add             %%INP,  16
%endif

        ;; CRC calculation
%ifidn %%CRC_TYPE, next_crc
        CRC_CLMUL %%XCRC_IN_OUT, %%XCRC_MUL, %%TXMM1, %%TXMM2
%endif
%ifidn %%CRC_TYPE, first_crc
        ;; in the first run just XOR initial CRC with the first block
        vpxorq          %%XCRC_IN_OUT, %%TXMM1
%endif

%endmacro

;; ===================================================================
;; ===================================================================
;; Barrett reduction from 128-bits to 32-bits modulo Ethernet FCS polynomial
;; ===================================================================
%macro CRC32_REDUCE_128_TO_32 5
%define %%CRC   %1         ; [out] GP to store 32-bit Ethernet FCS value
%define %%XCRC  %2         ; [in/clobbered] XMM with CRC
%define %%XT1   %3         ; [clobbered] temporary xmm register
%define %%XT2   %4         ; [clobbered] temporary xmm register
%define %%XT3   %5         ; [clobbered] temporary xmm register

%define %%XCRCKEY %%XT3

        ;;  compute crc of a 128-bit value
        vmovdqa64       %%XCRCKEY, [rel rk5]

        ;; 64b fold
        vpclmulqdq      %%XT1, %%XCRC, %%XCRCKEY, 0x00
        vpsrldq         %%XCRC, %%XCRC, 8
        vpxorq          %%XCRC, %%XCRC, %%XT1

        ;; 32b fold
        vpslldq         %%XT1, %%XCRC, 4
        vpclmulqdq      %%XT1, %%XT1, %%XCRCKEY, 0x10
        vpxorq          %%XCRC, %%XCRC, %%XT1

%%_crc_barrett:
        ;; Barrett reduction
        vpandq          %%XCRC, [rel mask2]
        vmovdqa64       %%XT1, %%XCRC
        vmovdqa64       %%XT2, %%XCRC
        vmovdqa64       %%XCRCKEY, [rel rk7]

        vpclmulqdq      %%XCRC, %%XCRCKEY, 0x00
        vpxorq          %%XCRC, %%XT2
        vpandq          %%XCRC, [rel mask]
        vmovdqa64       %%XT2, %%XCRC
        vpclmulqdq      %%XCRC, %%XCRCKEY, 0x10
        vpternlogq      %%XCRC, %%XT2, %%XT1, 0x96 ; XCRC = XCRC ^ XT2 ^ XT1
        vpextrd         DWORD(%%CRC), %%XCRC, 2 ; 32-bit CRC value
        not             DWORD(%%CRC)
%endmacro

;; ===================================================================
;; ===================================================================
;; Barrett reduction from 64-bits to 32-bits modulo Ethernet FCS polynomial
;; ===================================================================
%macro CRC32_REDUCE_64_TO_32 5
%define %%CRC   %1         ; [out] GP to store 32-bit Ethernet FCS value
%define %%XCRC  %2         ; [in/clobbered] XMM with CRC
%define %%XT1   %3         ; [clobbered] temporary xmm register
%define %%XT2   %4         ; [clobbered] temporary xmm register
%define %%XT3   %5         ; [clobbered] temporary xmm register

%define %%XCRCKEY %%XT3

        ;; Barrett reduction
        vpandq          %%XCRC, [rel mask2]
        vmovdqa64       %%XT1, %%XCRC
        vmovdqa64       %%XT2, %%XCRC
        vmovdqa64       %%XCRCKEY, [rel rk7]

        vpclmulqdq      %%XCRC, %%XCRCKEY, 0x00
        vpxorq          %%XCRC, %%XT2
        vpandq          %%XCRC, [rel mask]
        vmovdqa64       %%XT2, %%XCRC
        vpclmulqdq      %%XCRC, %%XCRCKEY, 0x10
        vpternlogq      %%XCRC, %%XT2, %%XT1, 0x96 ; XCRC = XCRC ^ XT2 ^ XT1
        vpextrd         DWORD(%%CRC), %%XCRC, 2 ; 32-bit CRC value
        not             DWORD(%%CRC)
%endmacro

;; ===================================================================
;; ===================================================================
;; ETHERNET FCS CRC
;; ===================================================================
%macro ETHERNET_FCS_CRC 9
%define %%p_in          %1  ; [in] pointer to the buffer (GPR)
%define %%bytes_to_crc  %2  ; [in] number of bytes in the buffer (GPR)
%define %%ethernet_fcs  %3  ; [out] GPR to put CRC value into (32 bits)
%define %%xcrc          %4  ; [in] initial CRC value (xmm)
%define %%tmp           %5  ; [clobbered] temporary GPR
%define %%xcrckey       %6  ; [clobbered] temporary XMM / CRC multiplier
%define %%xtmp1         %7  ; [clobbered] temporary XMM
%define %%xtmp2         %8  ; [clobbered] temporary XMM
%define %%xtmp3         %9  ; [clobbered] temporary XMM

        ;; load CRC constants
        vmovdqa64       %%xcrckey, [rel rk1] ; rk1 and rk2 in xcrckey

        cmp             %%bytes_to_crc, 32
        jae             %%_at_least_32_bytes

        ;; less than 32 bytes
        cmp             %%bytes_to_crc, 16
        je              %%_exact_16_left
        jl              %%_less_than_16_left

        ;; load the plain-text
        vmovdqu64       %%xtmp1, [%%p_in]
        vpxorq          %%xcrc, %%xtmp1   ; xor the initial crc value
        add             %%p_in, 16
        sub             %%bytes_to_crc, 16
        jmp             %%_crc_two_xmms

%%_exact_16_left:
        vmovdqu64       %%xtmp1, [%%p_in]
        vpxorq          %%xcrc, %%xtmp1 ; xor the initial CRC value
        jmp             %%_128_done

%%_less_than_16_left:
        lea             %%tmp, [rel byte_len_to_mask_table]
        kmovw           k1, [%%tmp + %%bytes_to_crc*2]
        vmovdqu8        %%xtmp1{k1}{z}, [%%p_in]

        vpxorq          %%xcrc, %%xtmp1 ; xor the initial CRC value

        cmp             %%bytes_to_crc, 4
        jb              %%_less_than_4_left

        lea             %%tmp, [rel pshufb_shf_table]
        vmovdqu64       %%xtmp1, [%%tmp + %%bytes_to_crc]
        vpshufb         %%xcrc, %%xtmp1
        jmp             %%_128_done

%%_less_than_4_left:
        ;; less than 4 bytes left
        cmp             %%bytes_to_crc, 3
        jne             %%_less_than_3_left
        vpslldq         %%xcrc, 5
        jmp             %%_do_barret

%%_less_than_3_left:
        cmp             %%bytes_to_crc, 2
        jne             %%_less_than_2_left
        vpslldq         %%xcrc, 6
        jmp             %%_do_barret

%%_less_than_2_left:
        vpslldq         %%xcrc, 7

%%_do_barret:
        CRC32_REDUCE_64_TO_32 %%ethernet_fcs, %%xcrc, %%xtmp1, %%xtmp2, %%xcrckey
        jmp             %%_64_done

%%_at_least_32_bytes:
        CRC_UPDATE16 %%p_in, %%xcrc, %%xcrckey, %%xtmp1, %%xtmp2, first_crc
        sub             %%bytes_to_crc, 16

%%_main_loop:
        cmp             %%bytes_to_crc, 16
        jb              %%_exit_loop
        CRC_UPDATE16 %%p_in, %%xcrc, %%xcrckey, %%xtmp1, %%xtmp2, next_crc
        sub             %%bytes_to_crc, 16
        jz              %%_128_done
        jmp             %%_main_loop

%%_exit_loop:

        ;; Partial bytes left - complete CRC calculation
%%_crc_two_xmms:
        lea             %%tmp, [rel pshufb_shf_table]
        vmovdqu64       %%xtmp2, [%%tmp + %%bytes_to_crc]
        vmovdqu64       %%xtmp1, [%%p_in - 16 + %%bytes_to_crc]  ; xtmp1 = data for CRC
        vmovdqa64       %%xtmp3, %%xcrc
        vpshufb         %%xcrc, %%xtmp2  ; top num_bytes with LSB xcrc
        vpxorq          %%xtmp2, [rel mask3]
        vpshufb         %%xtmp3, %%xtmp2 ; bottom (16 - num_bytes) with MSB xcrc

        ;; data num_bytes (top) blended with MSB bytes of CRC (bottom)
        vpblendvb       %%xtmp3, %%xtmp1, %%xtmp2

        ;; final CRC calculation
        CRC_CLMUL %%xcrc, %%xcrckey, %%xtmp3, %%xtmp1

%%_128_done:
        CRC32_REDUCE_128_TO_32 %%ethernet_fcs, %%xcrc, %%xtmp1, %%xtmp2, %%xcrckey
%%_64_done:
%endmacro

;; =====================================================================
;; =====================================================================
;; Creates stack frame and saves registers
;; =====================================================================
%macro FUNC_ENTRY 0
        mov     rax, rsp
        sub     rsp, STACK_size
        and     rsp, -16

        mov     [rsp + _gpr_save + 8*0], rbx
        mov     [rsp + _gpr_save + 8*1], rbp
        mov     [rsp + _gpr_save + 8*2], r12
        mov     [rsp + _gpr_save + 8*3], r13
        mov     [rsp + _gpr_save + 8*4], r14
        mov     [rsp + _gpr_save + 8*5], r15
%ifndef LINUX
        mov     [rsp + _gpr_save + 8*6], rsi
        mov     [rsp + _gpr_save + 8*7], rdi
%endif
        mov     [rsp + _rsp_save], rax  ; original SP

%endmacro       ; FUNC_ENTRY

;; =====================================================================
;; =====================================================================
;; Restores registers and removes the stack frame
;; =====================================================================
%macro FUNC_EXIT 0
        mov     rbx, [rsp + _gpr_save + 8*0]
        mov     rbp, [rsp + _gpr_save + 8*1]
        mov     r12, [rsp + _gpr_save + 8*2]
        mov     r13, [rsp + _gpr_save + 8*3]
        mov     r14, [rsp + _gpr_save + 8*4]
        mov     r15, [rsp + _gpr_save + 8*5]
%ifndef LINUX
        mov     rsi, [rsp + _gpr_save + 8*6]
        mov     rdi, [rsp + _gpr_save + 8*7]
%endif
        mov     rsp, [rsp + _rsp_save]  ; original SP

%ifdef SAFE_DATA
       clear_all_zmms_asm
%endif ;; SAFE_DATA

%endmacro

;; =====================================================================
;; =====================================================================
;; CRC32 computation round
;; =====================================================================
%macro CRC32_ROUND 17-18
%define %%FIRST         %1      ; [in] "first_possible" or "no_first"
%define %%LAST          %2      ; [in] "last_possible" or "no_last"
%define %%ARG           %3      ; [in] GP with pointer to OOO manager / arguments
%define %%LANEID        %4      ; [in] numerical value with lane id
%define %%XDATA         %5      ; [in] an XMM (any) with input data block for CRC calculation
%define %%XCRC_VAL      %6      ; [clobbered] temporary XMM (xmm0-15)
%define %%XCRC_DAT      %7      ; [clobbered] temporary XMM (xmm0-15)
%define %%XCRC_MUL      %8      ; [clobbered] temporary XMM (xmm0-15)
%define %%XCRC_TMP      %9      ; [clobbered] temporary XMM (xmm0-15)
%define %%XCRC_TMP2     %10     ; [clobbered] temporary XMM (xmm0-15)
%define %%IN            %11     ; [clobbered] temporary GPR (last partial only)
%define %%IDX           %12     ; [in] GP with data offset (last partial only)
%define %%OFFS          %13     ; [in] numerical offset (last partial only)
%define %%GT8           %14     ; [clobbered] temporary GPR (last partial only)
%define %%GT9           %15     ; [clobbered] temporary GPR (last partial only)
%define %%CRC32         %16     ; [clobbered] temporary GPR (last partial only)
%define %%LANEDAT       %17     ; [in/out] CRC cumulative sum
%define %%SUBLEN        %18     ; [in/optional] if "dont_subtract_len" length not subtracted

        cmp             byte [%%ARG + _docsis_crc_args_done + %%LANEID], CRC_LANE_STATE_DONE
        je              %%_crc_lane_done

%ifnidn %%FIRST, no_first
        cmp             byte [%%ARG + _docsis_crc_args_done + %%LANEID], CRC_LANE_STATE_TO_START
        je              %%_crc_lane_first_round
%endif  ; !no_first

%ifnidn %%LAST, no_last
        cmp             word [%%ARG + _docsis_crc_args_len + 2*%%LANEID], 16
        jb              %%_crc_lane_last_partial
%endif  ; no_last

        ;; The most common case: next block for CRC
        vmovdqa64       %%XCRC_VAL, %%LANEDAT
        CRC_CLMUL       %%XCRC_VAL, %%XCRC_MUL, %%XDATA, %%XCRC_TMP
        vmovdqa64       %%LANEDAT, %%XCRC_VAL
%ifnidn %%SUBLEN, dont_subtract_len
        sub             word [%%ARG + _docsis_crc_args_len + 2*%%LANEID], 16
%endif
%ifidn %%LAST, no_last
%ifidn %%FIRST, no_first
        ;; no jump needed - just fall through
%else
        jmp             %%_crc_lane_done
%endif  ; no_first
%else
        jmp             %%_crc_lane_done
%endif  ; np_last

%ifnidn %%LAST, no_last
%%_crc_lane_last_partial:
        ;; Partial block case (the last block)
        ;; - last CRC round is specific
        ;; - followed by CRC reduction and write back of the CRC
        vmovdqa64       %%XCRC_VAL, %%LANEDAT
        movzx           %%GT9, word [%%ARG + _docsis_crc_args_len + %%LANEID*2] ; GT9 = bytes_to_crc
        lea             %%GT8, [rel pshufb_shf_table]
        vmovdqu64       %%XCRC_TMP, [%%GT8 + %%GT9]
        mov             %%IN, [%%ARG + _aesarg_in + 8*%%LANEID]
        lea             %%GT8, [%%IN + %%IDX + %%OFFS]
        vmovdqu64       %%XCRC_DAT, [%%GT8 - 16 + %%GT9]  ; XCRC_DAT = data for CRC
        vmovdqa64       %%XCRC_TMP2, %%XCRC_VAL
        vpshufb         %%XCRC_VAL, %%XCRC_TMP  ; top bytes_to_crc with LSB XCRC_VAL
        vpxorq          %%XCRC_TMP, [rel mask3]
        vpshufb         %%XCRC_TMP2, %%XCRC_TMP ; bottom (16 - bytes_to_crc) with MSB XCRC_VAL

        vpblendvb       %%XCRC_DAT, %%XCRC_TMP2, %%XCRC_DAT, %%XCRC_TMP

        CRC_CLMUL       %%XCRC_VAL, %%XCRC_MUL, %%XCRC_DAT, %%XCRC_TMP
        CRC32_REDUCE_128_TO_32 %%CRC32, %%XCRC_VAL, %%XCRC_TMP, %%XCRC_DAT, %%XCRC_TMP2

        ;; save final CRC value in init
        vmovd           %%LANEDAT,  DWORD(%%CRC32)

        ;; write back CRC value into source buffer
        movzx           %%GT9, word [%%ARG + _docsis_crc_args_len + %%LANEID*2]
        lea             %%GT8, [%%IN + %%IDX + %%OFFS]
        mov             [%%GT8 + %%GT9], DWORD(%%CRC32)

        ;; reload the data for cipher (includes just computed CRC) - @todo store to load
        vmovdqu64       %%XDATA, [%%IN + %%IDX + %%OFFS]

        mov             word [%%ARG + _docsis_crc_args_len + 2*%%LANEID], 0
        ;; mark as done
        mov             byte [%%ARG + _docsis_crc_args_done + %%LANEID], CRC_LANE_STATE_DONE
%ifnidn %%FIRST, no_first
        jmp             %%_crc_lane_done
%endif  ; no_first
%endif  ; no_last

%ifnidn %%FIRST, no_first
%%_crc_lane_first_round:
        ;; Case of less than 16 bytes will not happen here since
        ;; submit code takes care of it.
        ;; in the first round just XOR initial CRC with the first block
        vpxorq          %%LANEDAT, %%LANEDAT, %%XDATA
        ;; mark first block as done
        mov             byte [%%ARG + _docsis_crc_args_done + %%LANEID], CRC_LANE_STATE_IN_PROGRESS
        sub             word [%%ARG + _docsis_crc_args_len + 2*%%LANEID], 16
%endif  ; no_first

%%_crc_lane_done:
%endmacro       ; CRC32_ROUND

;; =====================================================================
;; =====================================================================
;; Transforms and inserts AES expanded keys into OOO data structure
;; =====================================================================
%macro INSERT_KEYS 7
%define %%ARG     %1 ; [in] pointer to OOO structure
%define %%KP      %2 ; [in] GP reg with pointer to expanded keys
%define %%LANE    %3 ; [in] GP reg with lane number
%define %%NROUNDS %4 ; [in] number of round keys (numerical value)
%define %%COL     %5 ; [clobbered] GP reg
%define %%ZTMP    %6 ; [clobbered] ZMM reg
%define %%IA0     %7 ; [clobbered] GP reg

%assign ROW (16*16)

        mov             %%COL, %%LANE
        shl             %%COL, 4
        lea             %%IA0, [%%ARG + _aes_args_key_tab]
        add             %%COL, %%IA0

        vmovdqu64       %%ZTMP, [%%KP + (0 * 16)]
        vextracti64x2   [%%COL + ROW*0], %%ZTMP, 0
        vextracti64x2   [%%COL + ROW*1], %%ZTMP, 1
        vextracti64x2   [%%COL + ROW*2], %%ZTMP, 2
        vextracti64x2   [%%COL + ROW*3], %%ZTMP, 3

        vmovdqu64       %%ZTMP, [%%KP + (4 * 16)]
        vextracti64x2   [%%COL + ROW*4], %%ZTMP, 0
        vextracti64x2   [%%COL + ROW*5], %%ZTMP, 1
        vextracti64x2   [%%COL + ROW*6], %%ZTMP, 2
        vextracti64x2   [%%COL + ROW*7], %%ZTMP, 3

%if %%NROUNDS == 9
        ;; 128-bit key (11 keys)
        vmovdqu64       YWORD(%%ZTMP), [%%KP + (8 * 16)]
        vextracti64x2   [%%COL + ROW*8], YWORD(%%ZTMP), 0
        vextracti64x2   [%%COL + ROW*9], YWORD(%%ZTMP), 1
        vmovdqu64       XWORD(%%ZTMP), [%%KP + (10 * 16)]
        vmovdqu64       [%%COL + ROW*10], XWORD(%%ZTMP)
%else
        ;; 192-bit key or 256-bit key (13 and 15 keys)
        vmovdqu64       %%ZTMP, [%%KP + (8 * 16)]
        vextracti64x2   [%%COL + ROW*8], %%ZTMP, 0
        vextracti64x2   [%%COL + ROW*9], %%ZTMP, 1
        vextracti64x2   [%%COL + ROW*10], %%ZTMP, 2
        vextracti64x2   [%%COL + ROW*11], %%ZTMP, 3

%if %%NROUNDS == 11
        ;; 192-bit key (13 keys)
        vmovdqu64       XWORD(%%ZTMP), [%%KP + (12 * 16)]
        vmovdqu64       [%%COL + ROW*12], XWORD(%%ZTMP)
%else
        ;; 256-bit key (15 keys)
        vmovdqu64       YWORD(%%ZTMP), [%%KP + (12 * 16)]
        vextracti64x2   [%%COL + ROW*12], YWORD(%%ZTMP), 0
        vextracti64x2   [%%COL + ROW*13], YWORD(%%ZTMP), 1
        vmovdqu64       XWORD(%%ZTMP), [%%KP + (14 * 16)]
        vmovdqu64       [%%COL + ROW*14], XWORD(%%ZTMP)
%endif
%endif

%endmacro

;; =====================================================================
;; =====================================================================
;; Clear IVs and AES round key's in NULL lanes
;; =====================================================================
%macro CLEAR_IV_KEYS_IN_NULL_LANES 5
%define %%ARG           %1 ; [in] pointer to OOO structure
%define %%NULL_MASK     %2 ; [clobbered] GP to store NULL lane mask
%define %%XTMP          %3 ; [clobbered] temp XMM reg
%define %%MASK_REG      %4 ; [in] mask register
%define %%NROUNDS       %5 ; [in] number of AES rounds (9, 11 and 13)

%assign NUM_KEYS (%%NROUNDS + 2)

        vpxorq          %%XTMP, %%XTMP
        kmovw           DWORD(%%NULL_MASK), %%MASK_REG


        ;; outer loop to iterate through lanes
%assign k 0
%rep 8
        bt              %%NULL_MASK, k
        jnc             %%_skip_clear %+ k

        ;; clear lane IV buffers
        vmovdqa64       [%%ARG + _aes_args_IV + (k*16)], %%XTMP
        mov             qword [%%ARG + _aes_args_keys + k*8], 0
        vmovdqa64       [%%ARG + _docsis_crc_args_init + k*16], %%XTMP

        ; inner loop to iterate through round keys
%assign j 0
%rep NUM_KEYS
        vmovdqa64       [%%ARG + _aesarg_key_tab + j + (k*16)], %%XTMP
%assign j (j + 256)

%endrep
%%_skip_clear %+ k:
%assign k (k + 1)
%endrep
%endmacro

;; =====================================================================
;; =====================================================================
;; AES128/256-CBC encryption combined with CRC32 operations
;; =====================================================================
%macro AES_CBC_ENC_CRC32_PARALLEL 48
%define %%ARG   %1      ; [in/out] GPR with pointer to arguments structure (updated on output)
%define %%LEN   %2      ; [in/clobbered] number of bytes to be encrypted on all lanes
%define %%GT0   %3      ; [clobbered] GP register
%define %%GT1   %4      ; [clobbered] GP register
%define %%GT2   %5      ; [clobbered] GP register
%define %%GT3   %6      ; [clobbered] GP register
%define %%GT4   %7      ; [clobbered] GP register
%define %%GT5   %8      ; [clobbered] GP register
%define %%GT6   %9      ; [clobbered] GP register
%define %%GT7   %10     ; [clobbered] GP register
%define %%GT8   %11     ; [clobbered] GP register
%define %%GT9   %12     ; [clobbered] GP register
%define %%GT10  %13     ; [clobbered] GP register
%define %%GT11  %14     ; [clobbered] GP register
%define %%GT12  %15     ; [clobbered] GP register
%define %%ZT0   %16     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT1   %17     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT2   %18     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT3   %19     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT4   %20     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT5   %21     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT6   %22     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT7   %23     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT8   %24     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT9   %25     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT10  %26     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT11  %27     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT12  %28     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT13  %29     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT14  %30     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT15  %31     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT16  %32     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT17  %33     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT18  %34     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT19  %35     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT20  %36     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT21  %37     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT22  %38     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT23  %39     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT24  %40     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT25  %41     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT26  %42     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT27  %43     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT28  %44     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT29  %45     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT30  %46     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT31  %47     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%NROUNDS %48   ; [in] Number of rounds (9 or 13, based on key size)

;; %define %%KEYS0 %%GT0
;; %define %%KEYS1 %%GT1
;; %define %%KEYS2 %%GT2
;; %define %%KEYS3 %%GT3
;; %define %%KEYS4 %%GT4
;; %define %%KEYS5 %%GT5
;; %define %%KEYS6 %%GT6
;; %define %%KEYS7 %%GT7

%define %%GP1   %%GT10
%define %%CRC32 %%GT11
%define %%IDX   %%GT12

;; used for IV and AES rounds
%xdefine %%ZCIPH0 %%ZT0
%xdefine %%ZCIPH1 %%ZT1
%xdefine %%ZCIPH2 %%ZT2
%xdefine %%ZCIPH3 %%ZT3

%xdefine %%XCIPH0 XWORD(%%ZCIPH0)
%xdefine %%XCIPH1 XWORD(%%ZCIPH1)
%xdefine %%XCIPH2 XWORD(%%ZCIPH2)
%xdefine %%XCIPH3 XWORD(%%ZCIPH3)

;; used for per lane CRC multiply
%xdefine %%ZCRC_MUL %%ZT4
%xdefine %%XCRC_MUL XWORD(%%ZCRC_MUL)
%xdefine %%XCRC_TMP XWORD(%%ZT5)
%xdefine %%XCRC_DAT XWORD(%%ZT6)
%xdefine %%XCRC_VAL XWORD(%%ZT7)
%xdefine %%XCRC_TMP2 XWORD(%%ZT8)
%xdefine %%XTMP  %%XCRC_TMP2

;; used for loading plain text
%xdefine %%ZDATA0 %%ZT9
%xdefine %%ZDATA1 %%ZT10
%xdefine %%ZDATA2 %%ZT11
%xdefine %%ZDATA3 %%ZT12

%xdefine %%XDATA0 XWORD(%%ZDATA0)
%xdefine %%XDATA1 XWORD(%%ZDATA1)
%xdefine %%XDATA2 XWORD(%%ZDATA2)
%xdefine %%XDATA3 XWORD(%%ZDATA3)

;; used for current CRC sums
%xdefine %%ZDATB0 %%ZT13
%xdefine %%ZDATB1 %%ZT14
%xdefine %%ZDATB2 %%ZT15
%xdefine %%ZDATB3 %%ZT16

%xdefine %%XDATB0 XWORD(%%ZDATB0)
%xdefine %%XDATB1 XWORD(%%ZDATB1)
%xdefine %%XDATB2 XWORD(%%ZDATB2)
%xdefine %%XDATB3 XWORD(%%ZDATB3)


        xor             %%IDX, %%IDX

        vbroadcasti32x4 %%ZCRC_MUL, [rel rk1]

        vmovdqu64       %%ZCIPH0, [%%ARG + _aesarg_IV + 16*0]
        vmovdqu64       %%ZCIPH1, [%%ARG + _aesarg_IV + 16*4]

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; Pipeline start

        ;; CRC32 rounds on all lanes - first and last cases are possible
        ;; - load current CRC sum
        ;; - load plain text block
        ;; - do the initial CRC round
        ;; - keep CRC lane status in K register (lanes 0 to 6)
        vmovdqu64       %%ZDATB0, [%%ARG + _docsis_crc_args_init + (16 * 0)]
        vmovdqu64       %%ZDATB1, [%%ARG + _docsis_crc_args_init + (16 * 4)]

        mov             %%GT8, [%%ARG + _aesarg_in + (8 * 0)]
        mov             %%GT9, [%%ARG + _aesarg_in + (8 * 1)]
        vmovdqu64       %%ZDATA0, [%%GT8 + %%IDX]
        vinserti32x4    %%ZDATA0, [%%GT9 + %%IDX], 1
        mov             %%GT8, [%%ARG + _aesarg_in + (8 * 2)]
        mov             %%GT9, [%%ARG + _aesarg_in + (8 * 3)]
        vinserti32x4    %%ZDATA0, [%%GT8 + %%IDX], 2
        vinserti32x4    %%ZDATA0, [%%GT9 + %%IDX], 3

        mov             %%GT8, [%%ARG + _aesarg_in + (8 * 4)]
        mov             %%GT9, [%%ARG + _aesarg_in + (8 * 5)]
        vmovdqu64       %%ZDATA1, [%%GT8 + %%IDX]
        vinserti32x4    %%ZDATA1, [%%GT9 + %%IDX], 1
        mov             %%GT8, [%%ARG + _aesarg_in + (8 * 6)]
        mov             %%GT9, [%%ARG + _aesarg_in + (8 * 7)]
        vinserti32x4    %%ZDATA1, [%%GT8 + %%IDX], 2
        vinserti32x4    %%ZDATA1, [%%GT9 + %%IDX], 3


%assign crc_lane 0
%rep 8

%if crc_lane < 4
        vextracti32x4   XWORD(%%ZT17), %%ZDATA0, crc_lane
        vextracti32x4   XWORD(%%ZT18), %%ZDATB0, crc_lane
%else
        vextracti32x4   XWORD(%%ZT17), %%ZDATA1, crc_lane - 4
        vextracti32x4   XWORD(%%ZT18), %%ZDATB1, crc_lane - 4
%endif

        CRC32_ROUND     first_possible, last_possible, %%ARG, crc_lane, \
                        XWORD(%%ZT17), %%XCRC_VAL, %%XCRC_DAT, \
                        %%XCRC_MUL, %%XCRC_TMP, %%XCRC_TMP2, \
                        %%GP1, %%IDX, 0, %%GT8, %%GT9, %%CRC32, XWORD(%%ZT18)

%if crc_lane < 4
        vinserti32x4    %%ZDATB0, XWORD(%%ZT18), crc_lane
        vinserti32x4    %%ZDATA0, XWORD(%%ZT17), crc_lane
%else
        vinserti32x4    %%ZDATB1, XWORD(%%ZT18), crc_lane - 4
        vinserti32x4    %%ZDATA1, XWORD(%%ZT17), crc_lane - 4
%endif

%assign crc_lane (crc_lane + 1)
%endrep

        ;; lanes 0 to 3 use k1
        ;; lanes 4 to 7 use k2
        kmovd           k1, [%%ARG + _docsis_crc_args_done + 0]
        kmovd           k2, [%%ARG + _docsis_crc_args_done + 4]

        ;; check if only 16 bytes in this execution
        sub             %%LEN, 16
        je              %%_encrypt_the_last_block

%%_main_enc_loop:
        ;; if 16 bytes left (for CRC) then
        ;; go to the code variant where CRC last block case is checked
        cmp             %%LEN, 16
        je              %%_encrypt_and_crc_the_last_block

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; - use ternary logic for: plain-text XOR IV and AES ARK(0)
        ;;      - IV = XCIPHx
        ;;      - plain-text = XDATAx
        ;;      - ARK = [%%KEYSx + 16*0]

        vpternlogq      %%ZCIPH0, %%ZDATA0, [%%ARG + _aesarg_key_tab + (16 * 0)], 0x96
        vpternlogq      %%ZCIPH1, %%ZDATA1, [%%ARG + _aesarg_key_tab + (16 * 4)], 0x96

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; AES ROUNDS 1 to NROUNDS (9 or 13)
%assign crc_lane 0
%assign i 1
%rep %%NROUNDS
%assign key_offset (i * (16 * 16))

        vaesenc         %%ZCIPH0, %%ZCIPH0, [%%ARG + _aesarg_key_tab + key_offset + (16 * 0)]
        vaesenc         %%ZCIPH1, %%ZCIPH1, [%%ARG + _aesarg_key_tab + key_offset + (16 * 4)]

%if (i == 2)
        ;; don't start with AES round 1
        mov             %%GP1, [%%ARG + _aesarg_in + (8 * 0)]
        mov             %%GT8, [%%ARG + _aesarg_in + (8 * 1)]
        vmovdqu64       %%XDATA0, [%%GP1 + %%IDX + 16]
        vinserti32x4    %%ZDATA0, [%%GT8 + %%IDX + 16], 1
        mov             %%GP1, [%%ARG + _aesarg_in + (8 * 2)]
        mov             %%GT8, [%%ARG + _aesarg_in + (8 * 3)]
        vinserti32x4    %%ZDATA0, [%%GP1 + %%IDX + 16], 2
        vinserti32x4    %%ZDATA0, [%%GT8 + %%IDX + 16], 3
%elif (i == 3)
        ;; The most common case: next block for CRC
        vpclmulqdq      %%ZT19, %%ZDATB0, %%ZCRC_MUL, 0x01
        vpclmulqdq      %%ZT20, %%ZDATB0, %%ZCRC_MUL, 0x10
        vpternlogq      %%ZT20, %%ZT19, %%ZDATA0, 0x96 ; XCRC = XCRC ^ XTMP ^ DATA
        vmovdqu16       %%ZDATB0{k1}, %%ZT20
%elif (i == 4)
        mov             %%GP1, [%%ARG + _aesarg_in + (8 * 4)]
        mov             %%GT8, [%%ARG + _aesarg_in + (8 * 5)]
        vmovdqu64       %%XDATA1, [%%GP1 + %%IDX + 16]
        vinserti32x4    %%ZDATA1, [%%GT8 + %%IDX + 16], 1
        mov             %%GP1, [%%ARG + _aesarg_in + (8 * 6)]
        mov             %%GT8, [%%ARG + _aesarg_in + (8 * 7)]
        vinserti32x4    %%ZDATA1, [%%GP1 + %%IDX + 16], 2
        vinserti32x4    %%ZDATA1, [%%GT8 + %%IDX + 16], 3
%elif (i == 5)
        ;; The most common case: next block for CRC
        vpclmulqdq      %%ZT19, %%ZDATB1, %%ZCRC_MUL, 0x01
        vpclmulqdq      %%ZT20, %%ZDATB1, %%ZCRC_MUL, 0x10
        vpternlogq      %%ZT20, %%ZT19, %%ZDATA1, 0x96 ; XCRC = XCRC ^ XTMP ^ DATA
        vmovdqu16       %%ZDATB1{k2}, %%ZT20
%endif

%assign i (i + 1)
%endrep

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; AES ROUNDS 10 or 14
%assign key_offset (i * (16 * 16))

        vaesenclast     %%ZCIPH0, %%ZCIPH0, [%%ARG + _aesarg_key_tab + key_offset + (16 * 0)]
        vaesenclast     %%ZCIPH1, %%ZCIPH1, [%%ARG + _aesarg_key_tab + key_offset + (16 * 4)]

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; store cipher text
        ;; - XCIPHx is an IV for the next block

        mov             %%GT8, [%%ARG + _aesarg_out + 8*0]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*1]
        vmovdqu64       [%%GT8 + %%IDX], %%XCIPH0
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH0, 1
        mov             %%GT8, [%%ARG + _aesarg_out + 8*2]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*3]
        vextracti32x4   [%%GT8 + %%IDX], %%ZCIPH0, 2
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH0, 3
        mov             %%GT8, [%%ARG + _aesarg_out + 8*4]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*5]
        vmovdqu64       [%%GT8 + %%IDX], %%XCIPH1
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH1, 1
        mov             %%GT8, [%%ARG + _aesarg_out + 8*6]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*7]
        vextracti32x4   [%%GT8 + %%IDX], %%ZCIPH1, 2
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH1, 3

        add             %%IDX, 16
        sub             %%LEN, 16

        jmp             %%_main_enc_loop

%%_encrypt_and_crc_the_last_block:
        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; Main loop doesn't subtract lengths to save cycles
        ;; - all subtracts get accumulated and are done below
        vmovdqa64       %%XCRC_TMP, [%%ARG + _docsis_crc_args_len + 2*0]
        vpbroadcastw    %%XCRC_TMP2, WORD(%%IDX)
        vpsubw          %%XCRC_TMP, %%XCRC_TMP, %%XCRC_TMP2
        vmovdqa64       [%%ARG + _docsis_crc_args_len + 2*0], %%XCRC_TMP

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; - load key pointers to perform AES rounds
        ;; - use ternary logic for: plain-text XOR IV and AES ARK(0)
        ;;      - IV = XCIPHx
        ;;      - plain-text = XDATAx
        ;;      - ARK = [%%KEYSx + 16*0]

        vpternlogq      %%ZCIPH0, %%ZDATA0, [%%ARG + _aesarg_key_tab + (16 * 0)], 0x96
        vpternlogq      %%ZCIPH1, %%ZDATA1, [%%ARG + _aesarg_key_tab + (16 * 4)], 0x96

                ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
                ;; CRC: load new data
                mov             %%GP1, [%%ARG + _aesarg_in + (8 * 0)]
                mov             %%GT8, [%%ARG + _aesarg_in + (8 * 1)]
                vmovdqu64       %%XDATA0, [%%GP1 + %%IDX + 16]
                vinserti32x4    %%ZDATA0, [%%GT8 + %%IDX + 16], 1
                mov             %%GP1, [%%ARG + _aesarg_in + (8 * 2)]
                mov             %%GT8, [%%ARG + _aesarg_in + (8 * 3)]
                vinserti32x4    %%ZDATA0, [%%GP1 + %%IDX + 16], 2
                vinserti32x4    %%ZDATA0, [%%GT8 + %%IDX + 16], 3

                mov             %%GP1, [%%ARG + _aesarg_in + (8 * 4)]
                mov             %%GT8, [%%ARG + _aesarg_in + (8 * 5)]
                vmovdqu64       %%XDATA1, [%%GP1 + %%IDX + 16]
                vinserti32x4    %%ZDATA1, [%%GT8 + %%IDX + 16], 1
                mov             %%GP1, [%%ARG + _aesarg_in + (8 * 6)]
                mov             %%GT8, [%%ARG + _aesarg_in + (8 * 7)]
                vinserti32x4    %%ZDATA1, [%%GP1 + %%IDX + 16], 2
                vinserti32x4    %%ZDATA1, [%%GT8 + %%IDX + 16], 3

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; AES ROUNDS 1 to NROUNDS (9 or 13)
%assign crc_lane 0
%assign i 1
%rep %%NROUNDS
%assign key_offset (i * (16 * 16))

        vaesenc         %%ZCIPH0, %%ZCIPH0, [%%ARG + _aesarg_key_tab + key_offset + (16 * 0)]
        vaesenc         %%ZCIPH1, %%ZCIPH1, [%%ARG + _aesarg_key_tab + key_offset + (16 * 4)]

%if (crc_lane < 4)
        vextracti32x4   XWORD(%%ZT19), %%ZDATA0, crc_lane
        vextracti32x4   XWORD(%%ZT20), %%ZDATB0, crc_lane
        CRC32_ROUND     no_first, last_possible, %%ARG, crc_lane, \
                        XWORD(%%ZT19), %%XCRC_VAL, %%XCRC_DAT, \
                        %%XCRC_MUL, %%XCRC_TMP, %%XCRC_TMP2, \
                        %%GP1, %%IDX, 16, %%GT8, %%GT9, %%CRC32, XWORD(%%ZT20)
        vinserti32x4    %%ZDATB0, XWORD(%%ZT20), crc_lane
        vinserti32x4    %%ZDATA0, XWORD(%%ZT19), crc_lane
%elif (crc_lane < 8)
        vextracti32x4   XWORD(%%ZT19), %%ZDATA1, crc_lane - 4
        vextracti32x4   XWORD(%%ZT20), %%ZDATB1, crc_lane - 4
        CRC32_ROUND     no_first, last_possible, %%ARG, crc_lane, \
                        XWORD(%%ZT19), %%XCRC_VAL, %%XCRC_DAT, \
                        %%XCRC_MUL, %%XCRC_TMP, %%XCRC_TMP2, \
                        %%GP1, %%IDX, 16, %%GT8, %%GT9, %%CRC32, XWORD(%%ZT20)
        vinserti32x4    %%ZDATB1, XWORD(%%ZT20), crc_lane - 4
        vinserti32x4    %%ZDATA1, XWORD(%%ZT19), crc_lane - 4
%endif

%assign crc_lane (crc_lane + 1)
%assign i (i + 1)
%endrep

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; AES ROUNDS 10 or 14
%assign key_offset (i * (16 * 16))

        vaesenclast     %%ZCIPH0, %%ZCIPH0, [%%ARG + _aesarg_key_tab + key_offset + (16 * 0)]
        vaesenclast     %%ZCIPH1, %%ZCIPH1, [%%ARG + _aesarg_key_tab + key_offset + (16 * 4)]

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; store cipher text
        ;; - XCIPHx is an IV for the next block

        mov             %%GT8, [%%ARG + _aesarg_out + 8*0]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*1]
        vmovdqu64       [%%GT8 + %%IDX], %%XCIPH0
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH0, 1
        mov             %%GT8, [%%ARG + _aesarg_out + 8*2]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*3]
        vextracti32x4   [%%GT8 + %%IDX], %%ZCIPH0, 2
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH0, 3
        mov             %%GT8, [%%ARG + _aesarg_out + 8*4]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*5]
        vmovdqu64       [%%GT8 + %%IDX], %%XCIPH1
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH1, 1
        mov             %%GT8, [%%ARG + _aesarg_out + 8*6]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*7]
        vextracti32x4   [%%GT8 + %%IDX], %%ZCIPH1, 2
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH1, 3

        add             %%IDX, 16
        sub             %%LEN, 16

%%_encrypt_the_last_block:
        ;; NOTE: XDATA[0-7] preloaded with data blocks from corresponding lanes

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; - load key pointers to perform AES rounds
        ;; - use ternary logic for: plain-text XOR IV and AES ARK(0)
        ;;      - IV = XCIPHx
        ;;      - plain-text = XDATAx
        ;;      - ARK = [%%KEYSx + 16*0]

        vpternlogq      %%ZCIPH0, %%ZDATA0, [%%ARG + _aesarg_key_tab + (16 * 0)], 0x96
        vpternlogq      %%ZCIPH1, %%ZDATA1, [%%ARG + _aesarg_key_tab + (16 * 4)], 0x96

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; AES ROUNDS 1 to NROUNDS (9 or 13)
%assign i 1
%rep %%NROUNDS
%assign key_offset (i * (16 * 16))

        vaesenc         %%ZCIPH0, %%ZCIPH0, [%%ARG + _aesarg_key_tab + key_offset + (16 * 0)]
        vaesenc         %%ZCIPH1, %%ZCIPH1, [%%ARG + _aesarg_key_tab + key_offset + (16 * 4)]
%assign i (i + 1)
%endrep

                ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
                ;; CRC: CRC sum from registers back into the context structure
                vmovdqu64       [%%ARG + _docsis_crc_args_init + (16 * 0)], %%ZDATB0
                vmovdqu64       [%%ARG + _docsis_crc_args_init + (16 * 4)], %%ZDATB1

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; AES ROUNDS 10 or 14
%assign key_offset (i * (16 * 16))

        vaesenclast     %%ZCIPH0, %%ZCIPH0, [%%ARG + _aesarg_key_tab + key_offset + (16 * 0)]
        vaesenclast     %%ZCIPH1, %%ZCIPH1, [%%ARG + _aesarg_key_tab + key_offset + (16 * 4)]

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; store cipher text
        ;; - XCIPHx is an IV for the next block

        mov             %%GT8, [%%ARG + _aesarg_out + 8*0]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*1]
        vmovdqu64       [%%GT8 + %%IDX], %%XCIPH0
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH0, 1
        mov             %%GT8, [%%ARG + _aesarg_out + 8*2]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*3]
        vextracti32x4   [%%GT8 + %%IDX], %%ZCIPH0, 2
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH0, 3
        mov             %%GT8, [%%ARG + _aesarg_out + 8*4]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*5]
        vmovdqu64       [%%GT8 + %%IDX], %%XCIPH1
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH1, 1
        mov             %%GT8, [%%ARG + _aesarg_out + 8*6]
        mov             %%GP1, [%%ARG + _aesarg_out + 8*7]
        vextracti32x4   [%%GT8 + %%IDX], %%ZCIPH1, 2
        vextracti32x4   [%%GP1 + %%IDX], %%ZCIPH1, 3

        add             %%IDX, 16

%%_enc_done:
        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; update IV
        vmovdqu64       [%%ARG + _aesarg_IV + 16*0], %%ZCIPH0
        vmovdqu64       [%%ARG + _aesarg_IV + 16*4], %%ZCIPH1

        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        ;; update IN and OUT pointers
        vpbroadcastq    %%ZT0, %%IDX
        vpaddq          %%ZT1, %%ZT0, [%%ARG + _aesarg_in]
        vpaddq          %%ZT2, %%ZT0, [%%ARG + _aesarg_out]
        vmovdqu64       [%%ARG + _aesarg_in], %%ZT1
        vmovdqu64       [%%ARG + _aesarg_out], %%ZT2

%endmacro       ; AES_CBC_ENC_CRC32_PARALLEL

;; =====================================================================
;; =====================================================================
;; DOCSIS SEC BPI + CRC32 SUBMIT / FLUSH macro
;; =====================================================================
%macro SUBMIT_FLUSH_DOCSIS_CRC32 49
%define %%STATE %1      ; [in/out] GPR with pointer to arguments structure (updated on output)
%define %%JOB   %2      ; [in] number of bytes to be encrypted on all lanes
%define %%GT0   %3      ; [clobbered] GP register
%define %%GT1   %4      ; [clobbered] GP register
%define %%GT2   %5      ; [clobbered] GP register
%define %%GT3   %6      ; [clobbered] GP register
%define %%GT4   %7      ; [clobbered] GP register
%define %%GT5   %8      ; [clobbered] GP register
%define %%GT6   %9      ; [clobbered] GP register
%define %%GT7   %10     ; [clobbered] GP register
%define %%GT8   %11     ; [clobbered] GP register
%define %%GT9   %12     ; [clobbered] GP register
%define %%GT10  %13     ; [clobbered] GP register
%define %%GT11  %14     ; [clobbered] GP register
%define %%GT12  %15     ; [clobbered] GP register
%define %%ZT0   %16     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT1   %17     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT2   %18     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT3   %19     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT4   %20     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT5   %21     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT6   %22     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT7   %23     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT8   %24     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT9   %25     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT10  %26     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT11  %27     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT12  %28     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT13  %29     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT14  %30     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT15  %31     ; [clobbered] ZMM register (zmm0 - zmm15)
%define %%ZT16  %32     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT17  %33     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT18  %34     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT19  %35     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT20  %36     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT21  %37     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT22  %38     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT23  %39     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT24  %40     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT25  %41     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT26  %42     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT27  %43     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT28  %44     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT29  %45     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT30  %46     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%ZT31  %47     ; [clobbered] ZMM register (zmm16 - zmm31)
%define %%SUBMIT_FLUSH %48 ; [in] "submit" or "flush"; %%JOB ignored for "flush"
%define %%NROUNDS %49   ; [in] Number of rounds (9 or 13, based on key size)

%define %%idx           %%GT0
%define %%unused_lanes  %%GT3
%define %%job_rax       rax
%define %%len2          arg2

%ifidn %%SUBMIT_FLUSH, submit
        ;; /////////////////////////////////////////////////
        ;; SUBMIT

; idx needs to be in rbp
%define %%len           %%GT0
%define %%tmp           %%GT0
%define %%lane          %%GT1
%define %%iv            %%GT2

        mov             %%unused_lanes, [%%STATE + _aes_unused_lanes]
        mov             %%lane, %%unused_lanes
        and             %%lane, 0xF
        shr             %%unused_lanes, 4
        mov             [%%STATE + _aes_unused_lanes], %%unused_lanes

        mov             [%%STATE + _aes_job_in_lane + %%lane*8], %%JOB

        mov             %%len, [%%JOB + _msg_len_to_cipher_in_bytes]
        ;; DOCSIS may pass size unaligned to block size
        and             %%len, -16
        vmovdqa         xmm0, [%%STATE + _aes_lens]
        XVPINSRW        xmm0, xmm1, %%tmp, %%lane, %%len, scale_x16
        vmovdqa         [%%STATE + _aes_lens], xmm0

        ;; Insert expanded keys
        mov             %%tmp, [%%JOB + _enc_keys]
        mov             [%%STATE + _aes_args_keys + %%lane*8], %%tmp
        INSERT_KEYS     %%STATE, %%tmp, %%lane, %%NROUNDS, %%GT8, zmm2, %%GT9

        ;; Update input pointer
        mov             %%tmp, [%%JOB + _src]
        add             %%tmp, [%%JOB + _cipher_start_src_offset_in_bytes]
        mov             [%%STATE + _aes_args_in + %%lane*8], %%tmp

        ;; Update output pointer
        mov             %%tmp, [%%JOB + _dst]
        mov             [%%STATE + _aes_args_out + %%lane*8], %%tmp

        ;; Set default CRC state
        mov             byte [%%STATE + _docsis_crc_args_done + %%lane], CRC_LANE_STATE_DONE

        ;; Set IV
        mov             %%iv, [%%JOB + _iv]
        vmovdqu         xmm0, [%%iv]
        shl             %%lane, 4       ; multiply by 16
        vmovdqa64       [%%STATE + _aes_args_IV + %%lane], xmm0

        cmp             qword [%%JOB + _msg_len_to_hash_in_bytes], 14
        jb              %%_crc_complete

        ;; there is CRC to calculate - now in one go or in chunks
        ;; - load init value into the lane
        vmovdqa64       XWORD(%%ZT0), [rel init_crc_value]
        vmovdqa64       [%%STATE + _docsis_crc_args_init + %%lane], XWORD(%%ZT0)
        shr             %%lane, 4

        mov             %%GT6, [%%JOB + _src]
        add             %%GT6, [%%JOB + _hash_start_src_offset_in_bytes]

        vmovdqa64       XWORD(%%ZT1), [rel rk1]

        cmp             qword [%%JOB + _msg_len_to_cipher_in_bytes], (2 * 16)
        jae             %%_crc_in_chunks

        ;; this is short message - compute whole CRC in one go
        mov             %%GT5, [%%JOB + _msg_len_to_hash_in_bytes]
        mov             [%%STATE + _docsis_crc_args_len + %%lane*2], WORD(%%GT5)

        ;; GT6 - ptr, GT5 - length, ZT1 - CRC_MUL, ZT0 - CRC_IN_OUT
        ETHERNET_FCS_CRC %%GT6, %%GT5, %%GT7, XWORD(%%ZT0), %%GT2, \
                         XWORD(%%ZT1), XWORD(%%ZT2), XWORD(%%ZT3), XWORD(%%ZT4)

        mov             %%GT6, [%%JOB + _src]
        add             %%GT6, [%%JOB + _hash_start_src_offset_in_bytes]
        add             %%GT6, [%%JOB + _msg_len_to_hash_in_bytes]
        mov             [%%GT6], DWORD(%%GT7)
        shl             %%lane, 4
        mov             [%%STATE + _docsis_crc_args_init + %%lane], DWORD(%%GT7)
        shr             %%lane, 4
        jmp             %%_crc_complete

%%_crc_in_chunks:
        ;; CRC in chunks will follow
        mov             %%GT5, [%%JOB + _msg_len_to_cipher_in_bytes]
        sub             %%GT5, 4
        mov             [%%STATE + _docsis_crc_args_len + %%lane*2], WORD(%%GT5)
        mov             byte [%%STATE + _docsis_crc_args_done + %%lane], CRC_LANE_STATE_TO_START

        ;; now calculate only CRC on bytes before cipher start
        mov             %%GT5, [%%JOB + _cipher_start_src_offset_in_bytes]
        sub             %%GT5, [%%JOB + _hash_start_src_offset_in_bytes]

        ;; GT6 - ptr, GT5 - length, ZT1 - CRC_MUL, ZT0 - CRC_IN_OUT
        ETHERNET_FCS_CRC %%GT6, %%GT5, %%GT7, XWORD(%%ZT0), %%GT2, \
                         XWORD(%%ZT1), XWORD(%%ZT2), XWORD(%%ZT3), XWORD(%%ZT4)

        not             DWORD(%%GT7)
        vmovd           xmm8, DWORD(%%GT7)
        shl             %%lane, 4
        vmovdqa64       [%%STATE + _docsis_crc_args_init + %%lane], xmm8
        shr             %%lane, 4

%%_crc_complete:
        cmp             %%unused_lanes, 0xf
        je              %%_load_lens
        xor             %%job_rax, %%job_rax    ; return NULL
        jmp             %%_return

%%_load_lens:
        ;; load lens into xmm0
        vmovdqa64       xmm0, [%%STATE + _aes_lens]

%else
        ;; /////////////////////////////////////////////////
        ;; FLUSH

%define %%tmp1             %%GT1
%define %%good_lane        %%GT2
%define %%tmp              %%GT3
%define %%tmp2             %%GT4
%define %%tmp3             %%GT5

        ; check for empty
        mov             %%unused_lanes, [%%STATE + _aes_unused_lanes]
        bt              %%unused_lanes, 32+3
        jnc             %%_find_non_null_lane

        xor             %%job_rax, %%job_rax    ; return NULL
        jmp             %%_return

%%_find_non_null_lane:
        ; find a lane with a non-null job
        xor             %%good_lane, %%good_lane
        cmp             qword [%%STATE + _aes_job_in_lane + 1*8], 0
        cmovne          %%good_lane, [rel one]
        cmp             qword [%%STATE + _aes_job_in_lane + 2*8], 0
        cmovne          %%good_lane, [rel two]
        cmp             qword [%%STATE + _aes_job_in_lane + 3*8], 0
        cmovne          %%good_lane, [rel three]
        cmp             qword [%%STATE + _aes_job_in_lane + 4*8], 0
        cmovne          %%good_lane, [rel four]
        cmp             qword [%%STATE + _aes_job_in_lane + 5*8], 0
        cmovne          %%good_lane, [rel five]
        cmp             qword [%%STATE + _aes_job_in_lane + 6*8], 0
        cmovne          %%good_lane, [rel six]
        cmp             qword [%%STATE + _aes_job_in_lane + 7*8], 0
        cmovne          %%good_lane, [rel seven]

        ; copy good_lane to empty lanes
        mov             %%tmp1, [%%STATE + _aes_args_in + %%good_lane*8]
        mov             %%tmp2, [%%STATE + _aes_args_out + %%good_lane*8]
        mov             %%tmp3, [%%STATE + _aes_args_keys + %%good_lane*8]
        mov             WORD(%%GT6), [%%STATE + _docsis_crc_args_len + %%good_lane*2]
        mov             BYTE(%%GT7), [%%STATE + _docsis_crc_args_done + %%good_lane]
        shl             %%good_lane, 4 ; multiply by 16
        vmovdqa64       xmm2, [%%STATE + _aes_args_IV + %%good_lane]
        vmovdqa64       xmm3, [%%STATE + _docsis_crc_args_init + %%good_lane]
        vmovdqa64       xmm0, [%%STATE + _aes_lens]

        vmovdqa64       xmm10, [%%STATE + _aesarg_key_tab + %%good_lane + (0 * (16 * 16))]
        vmovdqa64       xmm11, [%%STATE + _aesarg_key_tab + %%good_lane + (1 * (16 * 16))]
        vmovdqa64       xmm12, [%%STATE + _aesarg_key_tab + %%good_lane + (2 * (16 * 16))]
        vmovdqa64       xmm13, [%%STATE + _aesarg_key_tab + %%good_lane + (3 * (16 * 16))]
        vmovdqa64       xmm14, [%%STATE + _aesarg_key_tab + %%good_lane + (4 * (16 * 16))]
        vmovdqa64       xmm15, [%%STATE + _aesarg_key_tab + %%good_lane + (5 * (16 * 16))]
        vmovdqa64       xmm16, [%%STATE + _aesarg_key_tab + %%good_lane + (6 * (16 * 16))]
        vmovdqa64       xmm17, [%%STATE + _aesarg_key_tab + %%good_lane + (7 * (16 * 16))]
        vmovdqa64       xmm18, [%%STATE + _aesarg_key_tab + %%good_lane + (8 * (16 * 16))]
        vmovdqa64       xmm19, [%%STATE + _aesarg_key_tab + %%good_lane + (9 * (16 * 16))]
        vmovdqa64       xmm20, [%%STATE + _aesarg_key_tab + %%good_lane + (10 * (16 * 16))]
        vmovdqa64       xmm21, [%%STATE + _aesarg_key_tab + %%good_lane + (11 * (16 * 16))]
        vmovdqa64       xmm22, [%%STATE + _aesarg_key_tab + %%good_lane + (12 * (16 * 16))]
        vmovdqa64       xmm23, [%%STATE + _aesarg_key_tab + %%good_lane + (13 * (16 * 16))]
        vmovdqa64       xmm24, [%%STATE + _aesarg_key_tab + %%good_lane + (14 * (16 * 16))]

%assign I 0
%rep 8
        cmp             qword [%%STATE + _aes_job_in_lane + I*8], 0
        jne             APPEND(%%_skip_,I)
        mov             [%%STATE + _aes_args_in + I*8], %%tmp1
        mov             [%%STATE + _aes_args_out + I*8], %%tmp2
        mov             [%%STATE + _aes_args_keys + I*8], %%tmp3
        mov             [%%STATE + _docsis_crc_args_len + I*2], WORD(%%GT6)
        mov             [%%STATE + _docsis_crc_args_done + I], BYTE(%%GT7)
        vmovdqa64       [%%STATE + _aes_args_IV + I*16], xmm2
        vmovdqa64       [%%STATE + _docsis_crc_args_init + I*16], xmm3
        vporq           xmm0, xmm0, [rel len_masks + 16*I]

        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (0 * (16 * 16))], xmm10
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (1 * (16 * 16))], xmm11
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (2 * (16 * 16))], xmm12
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (3 * (16 * 16))], xmm13
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (4 * (16 * 16))], xmm14
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (5 * (16 * 16))], xmm15
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (6 * (16 * 16))], xmm16
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (7 * (16 * 16))], xmm17
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (8 * (16 * 16))], xmm18
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (9 * (16 * 16))], xmm19
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (10 * (16 * 16))], xmm20
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (11 * (16 * 16))], xmm21
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (12 * (16 * 16))], xmm22
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (13 * (16 * 16))], xmm23
        vmovdqa64       [%%STATE + _aesarg_key_tab + (16 * I) + (14 * (16 * 16))], xmm24

APPEND(%%_skip_,I):
%assign I (I+1)
%endrep

%endif  ;; SUBMIT / FLUSH

%%_find_min_job:
        ;; Find min length (xmm0 includes vector of 8 lengths)
        ;; vmovdqa64       xmm0, [%%STATE + _aes_lens] => not needed xmm0 already loaded with lengths
        vphminposuw     xmm1, xmm0
        vpextrw         DWORD(%%len2), xmm1, 0  ; min value
        vpextrw         DWORD(%%idx), xmm1, 1   ; min index (0...7)
        cmp             %%len2, 0
        je              %%_len_is_0

        vpshufb         xmm1, xmm1, [rel dupw]   ; duplicate words across all lanes
        vpsubw          xmm0, xmm0, xmm1
        vmovdqa64       [%%STATE + _aes_lens], xmm0

        mov             [rsp + _idx], %%idx

        AES_CBC_ENC_CRC32_PARALLEL %%STATE, %%len2, \
                        %%GT0, %%GT1, %%GT2, %%GT3, %%GT4, %%GT5, %%GT6, \
                        %%GT7, %%GT8, %%GT9, %%GT10, %%GT11, %%GT12, \
                        %%ZT0,  %%ZT1,  %%ZT2,  %%ZT3,  %%ZT4,  %%ZT5,  %%ZT6,  %%ZT7, \
                        %%ZT8,  %%ZT9,  %%ZT10, %%ZT11, %%ZT12, %%ZT13, %%ZT14, %%ZT15, \
                        %%ZT16, %%ZT17, %%ZT18, %%ZT19, %%ZT20, %%ZT21, %%ZT22, %%ZT23, \
                        %%ZT24, %%ZT25, %%ZT26, %%ZT27, %%ZT28, %%ZT29, %%ZT30, %%ZT31, \
                        %%NROUNDS

        mov             %%idx, [rsp + _idx]

%%_len_is_0:
        mov             %%job_rax, [%%STATE + _aes_job_in_lane + %%idx*8]

        ;; CRC the remaining bytes
        cmp             byte [%%STATE + _docsis_crc_args_done + %%idx], CRC_LANE_STATE_DONE
        je              %%_crc_is_complete

        ;; some bytes left to complete CRC
        movzx           %%GT3, word [%%STATE + _docsis_crc_args_len + %%idx*2]
        mov             %%GT4, [%%STATE + _aes_args_in + %%idx*8]

        or              %%GT3, %%GT3
        jz              %%_crc_read_reduce

        shl             %%idx, 1
        vmovdqa64       xmm8, [%%STATE + _docsis_crc_args_init + %%idx*8]
        shr             %%idx, 1

        lea             %%GT5, [rel pshufb_shf_table]
        vmovdqu64       xmm10, [%%GT5 + %%GT3]
        vmovdqu64       xmm9, [%%GT4 - 16 + %%GT3]
        vmovdqa64       xmm11, xmm8
        vpshufb         xmm8, xmm10  ; top num_bytes with LSB xcrc
        vpxorq          xmm10, [rel mask3]
        vpshufb         xmm11, xmm10 ; bottom (16 - num_bytes) with MSB xcrc

        ;; data num_bytes (top) blended with MSB bytes of CRC (bottom)
        vpblendvb       xmm11, xmm9, xmm10

        ;; final CRC calculation
        vmovdqa64       xmm9, [rel rk1]
        CRC_CLMUL       xmm8, xmm9, xmm11, xmm12
        jmp             %%_crc_reduce

;; complete the last block

%%_crc_read_reduce:
        shl             %%idx, 1
        vmovdqa64       xmm8, [%%STATE + _docsis_crc_args_init + %%idx*8]
        shr             %%idx, 1

%%_crc_reduce:
        ;; GT3 - offset in bytes to put the CRC32 value into
        ;; GT4 - src buffer pointer
        ;; xmm8 - current CRC value for reduction
        ;; - write CRC value into SRC buffer for further cipher
        ;; - keep CRC value in init field
        CRC32_REDUCE_128_TO_32 %%GT7, xmm8, xmm9, xmm10, xmm11
        mov             [%%GT4 + %%GT3], DWORD(%%GT7)
        shl             %%idx, 1
        mov             [%%STATE + _docsis_crc_args_init + %%idx*8], DWORD(%%GT7)
        shr             %%idx, 1

%%_crc_is_complete:
        mov             %%GT3, [%%job_rax + _msg_len_to_cipher_in_bytes]
        and             %%GT3, 0xf
        jz              %%_no_partial_block_cipher


        ;; AES128/256-CFB on the partial block
        mov             %%GT4, [%%STATE + _aes_args_in + %%idx*8]
        mov             %%GT5, [%%STATE + _aes_args_out + %%idx*8]
        mov             %%GT6, [%%job_rax + _enc_keys]
        shl             %%idx, 1
        vmovdqa64       xmm2, [%%STATE + _aes_args_IV + %%idx*8]
        shr             %%idx, 1
        lea             %%GT2, [rel byte_len_to_mask_table]
        kmovw           k1, [%%GT2 + %%GT3*2]
        vmovdqu8        xmm3{k1}{z}, [%%GT4]
        vpxorq          xmm1, xmm2, [%%GT6 + 0*16]
%assign i 1
%rep %%NROUNDS
        vaesenc         xmm1, [%%GT6 + i*16]
%assign i (i + 1)
%endrep
        vaesenclast     xmm1, [%%GT6 + i*16]
        vpxorq          xmm1, xmm1, xmm3
        vmovdqu8        [%%GT5]{k1}, xmm1

%%_no_partial_block_cipher:
        ;;  - copy CRC value into auth tag
        ;; - process completed job "idx"
        shl             %%idx, 1
        mov             DWORD(%%GT7), [%%STATE + _docsis_crc_args_init + %%idx*8]
        shr             %%idx, 1
        mov             %%GT6, [%%job_rax + _auth_tag_output]
        mov             [%%GT6], DWORD(%%GT7)

        mov             %%unused_lanes, [%%STATE + _aes_unused_lanes]
        mov             qword [%%STATE + _aes_job_in_lane + %%idx*8], 0
        or              dword [%%job_rax + _status], STS_COMPLETED_AES
        shl             %%unused_lanes, 4
        or              %%unused_lanes, %%idx
        mov             [%%STATE + _aes_unused_lanes], %%unused_lanes

%ifdef SAFE_DATA
%ifidn %%SUBMIT_FLUSH, submit
        ;; Clear IV
        vpxor           xmm0, xmm0
        shl             %%idx, 3 ; multiply by 8
        mov             qword [%%STATE + _aes_args_keys + %%idx], 0
        vmovdqa         [%%STATE + _docsis_crc_args_init + %%idx*2], xmm0
%else
        ;; Clear IVs of returned job and "NULL lanes"
        vmovdqu64       zmm0, [%%STATE + _aes_job_in_lane + 0*8]
        vpxorq          zmm1, zmm1
        vpcmpeqq        k2, zmm0, zmm1
        CLEAR_IV_KEYS_IN_NULL_LANES %%tmp, xmm0, k2, %%NROUNDS

%endif  ;; SUBMIT / FLUSH
%endif  ;; SAFE_DATA

%%_return:

%endmacro

;; ===========================================================================
;; JOB* SUBMIT_JOB_DOCSIS128_SEC_CRC_ENC(MB_MGR_AES_OOO *state, IMB_JOB *job)
;; arg 1 : state
;; arg 2 : job

align 64
MKGLOBAL(submit_job_aes_docsis128_enc_crc32_vaes_avx512,function,internal)
submit_job_aes_docsis128_enc_crc32_vaes_avx512:
        FUNC_ENTRY

        SUBMIT_FLUSH_DOCSIS_CRC32 arg1, arg2, \
                        TMP0,  TMP1,  TMP2,  TMP3,  TMP4,  TMP5,  TMP6, \
                        TMP7,  TMP8,  TMP9,  TMP10, TMP11, TMP12, \
                        zmm0,  zmm1,  zmm2,  zmm3,  zmm4,  zmm5,  zmm6,  zmm7, \
                        zmm8,  zmm9,  zmm10, zmm11, zmm12, zmm13, zmm14, zmm15, \
                        zmm16, zmm17, zmm18, zmm19, zmm20, zmm21, zmm22, zmm23, \
                        zmm24, zmm25, zmm26, zmm27, zmm28, zmm29, zmm30, zmm31, \
                        submit, 9
        FUNC_EXIT
        ret

;; ===========================================================================
;; JOB* SUBMIT_JOB_DOCSIS256_SEC_CRC_ENC(MB_MGR_AES_OOO *state, IMB_JOB *job)
;; arg 1 : state
;; arg 2 : job

align 64
MKGLOBAL(submit_job_aes_docsis256_enc_crc32_vaes_avx512,function,internal)
submit_job_aes_docsis256_enc_crc32_vaes_avx512:
        FUNC_ENTRY

        SUBMIT_FLUSH_DOCSIS_CRC32 arg1, arg2, \
                        TMP0,  TMP1,  TMP2,  TMP3,  TMP4,  TMP5,  TMP6, \
                        TMP7,  TMP8,  TMP9,  TMP10, TMP11, TMP12, \
                        zmm0,  zmm1,  zmm2,  zmm3,  zmm4,  zmm5,  zmm6,  zmm7, \
                        zmm8,  zmm9,  zmm10, zmm11, zmm12, zmm13, zmm14, zmm15, \
                        zmm16, zmm17, zmm18, zmm19, zmm20, zmm21, zmm22, zmm23, \
                        zmm24, zmm25, zmm26, zmm27, zmm28, zmm29, zmm30, zmm31, \
                        submit, 13
        FUNC_EXIT
        ret

;; =====================================================================
;; JOB* FLUSH128(MB_MGR_AES_OOO *state)
;; arg 1 : state
align 64
MKGLOBAL(flush_job_aes_docsis128_enc_crc32_vaes_avx512,function,internal)
flush_job_aes_docsis128_enc_crc32_vaes_avx512:
        FUNC_ENTRY

        SUBMIT_FLUSH_DOCSIS_CRC32 arg1, arg2, \
                        TMP0,  TMP1,  TMP2,  TMP3,  TMP4,  TMP5,  TMP6, \
                        TMP7,  TMP8,  TMP9,  TMP10, TMP11, TMP12, \
                        zmm0,  zmm1,  zmm2,  zmm3,  zmm4,  zmm5,  zmm6,  zmm7, \
                        zmm8,  zmm9,  zmm10, zmm11, zmm12, zmm13, zmm14, zmm15, \
                        zmm16, zmm17, zmm18, zmm19, zmm20, zmm21, zmm22, zmm23, \
                        zmm24, zmm25, zmm26, zmm27, zmm28, zmm29, zmm30, zmm31, \
                        flush, 9
        FUNC_EXIT
        ret

;; =====================================================================
;; JOB* FLUSH256(MB_MGR_AES_OOO *state)
;; arg 1 : state
align 64
MKGLOBAL(flush_job_aes_docsis256_enc_crc32_vaes_avx512,function,internal)
flush_job_aes_docsis256_enc_crc32_vaes_avx512:
        FUNC_ENTRY

        SUBMIT_FLUSH_DOCSIS_CRC32 arg1, arg2, \
                        TMP0,  TMP1,  TMP2,  TMP3,  TMP4,  TMP5,  TMP6, \
                        TMP7,  TMP8,  TMP9,  TMP10, TMP11, TMP12, \
                        zmm0,  zmm1,  zmm2,  zmm3,  zmm4,  zmm5,  zmm6,  zmm7, \
                        zmm8,  zmm9,  zmm10, zmm11, zmm12, zmm13, zmm14, zmm15, \
                        zmm16, zmm17, zmm18, zmm19, zmm20, zmm21, zmm22, zmm23, \
                        zmm24, zmm25, zmm26, zmm27, zmm28, zmm29, zmm30, zmm31, \
                        flush, 13

        FUNC_EXIT
        ret

%ifdef LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
