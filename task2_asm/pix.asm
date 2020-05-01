;;;;;
;PIX;
;;;;;

SECTION .data
SECTION .bss
SECTION .text
global pix
extern pixtime

; @brief: rax := rax % r8
; @arguments: none
; @modifies: rax, rdx
%macro mod 0
 div         r8                     ; divide by modular expression
 mov         rax, rdx               ; result is in rdx, moving to rax
%endmacro

; @brief: fast exponential algorithm (log(n)). rdx := 16^{n-k} % 8k + j
; @arguments: none
; @modifies: rax, r12, r10
%macro pow 0
 mov         r10, rcx               ;moves n-k to r10. It will be our exp-iterator (eit)
 mov         rax, 16                ; a-value from fast-exp algo
 mov         r12, 1                 ; result
%%iter:
 test        r10, 1                 ; check if is even
 jz          %%forward              ; if so, move forward
 xchg        rax, r12               ;if not, exchange result with a
 mul         r12                    ; r:= r * a
 mod                                ; take modulo 8k+j
 xchg        rax, r12               ; move backward to old notation
%%forward:
 mul         rax                    ; a := a^2
 mod                                ; take modulo 8k+j
 shr         r10, 1                 ; eit := eit/2
 cmp         r10, 0                 ; check if algo can be finished
 jne         %%iter                 ; if not, go to loop beginning
 mov         rdx, r12               ; result goes to rdx
%endmacro

; @brief: perform a*b, where a,b are 64-bit ints
; and stores higher 64 bits (from 128 bit integer) to rax
; Assumes that a,b = rcx, r10
; Performs similar algo to exercise in second Operating System lab
; @arguments (explicit): none
; @modifies: rax, rcx, r11, r12, r13, r14
%macro mul64 0
;no to teraz
; al,ah = r11d, r12d
; bl,bh = r13d, r14d
 mov         r11d, ecx              ;al (alow) := cur16pow_l
 mov         r12, rcx               ; r12 := cur16pow (whole 64 bits)
 shr         r12, 32                ; after shift in r12d is ah (ahigh)

 mov         r13d, r10d             ;bl (alow) := 1/16
 mov         r14, r10               ; r14 := 1/16 (whole 64 bits)
 shr         r14, 32                ; after shift in r14d is bh (ahigh)

 mov         eax, r14d              ; performing...
 mul         r12                    ; ...ah*bh
 mov         rcx, rax               ; rcx stores result of a*b

 mov         eax, r11d              ; performing...
 mul         r14                    ;al * bh
 shr         rax, 32                ; al*bh \in [0, 2^{96}), don't need lowest 32 bits
 add         rcx, rax               ; adds to result

 mov         eax, r12d              ; performing...
 mul         r13                    ;ah * bl
 shr         rax, 32                ; ah*bl \in [0, 2^{96}), don't need lowest 32 bits
 xadd        rax, rcx               ; adds to result and put that into rax
%endmacro

; @brief: performs sum from 0 to n in that way:
; up = 16^{n-k} % 8k + j
; down = 8*k + j;
; res += up/down
; @arguments: none
; @modifies: rax, rcx, r9, r10, r12
%macro tonsum 0
%%iter:
 pow                                ;result will be in rdx
 xor         rax, rax               ; zeros rax to have rdx:rax == res:0 (128 bit number)
 cmp         r8, 1                  ; check corner case: dividing by 1 could cause overflow
 je          %%forward              ; if corcer cases, move forward
 div         r8                     ; if not, divide by 8k+j, temporary value in rax
 add         r9, rax                ; res+=temp
%%forward:
 add         r8, 8                  ; 8(k-1)+j --> 8k+j
 cmp         rcx, 0                 ; check if n-k == 0
 je          .rest                  ; if so then go to second part (from k:=n+1 to ...)
 dec         rcx                    ; n-(k-1) --> n-k
 jmp         %%iter                 ; loop back
%endmacro


; @brief: performs sum from n+1 to ... for get correct precision
; @arguments: none
; @modifies: rax, rcx, r9, r10, r12
%macro fromnsum 0
%%iter:
 mov         rcx, rax               ; store cur16pow in rcx because rax will be used
 xor         rdx, rdx               ; zeros 64 bits because division will be performed
 div         r8                     ; rax := cur16pow / 8k+j
 cmp         rax, 0                 ; if integral part is zero, no need to continue
 je          .quit                  ; go to finish
 add         r9, rax                ; result += current part;
 add         r8, 8                  ; update 8k+j

 mul64                              ; performs cur16pow * 1/16 and get higher 64 bits
 jmp         %%iter

%endmacro

; @brief: Perform single sum step from math-stack exchange hint
; @arguments:
; r11 - n-k
; r8 - value of j for S_j formula
; @modifies: rax, rcx, rdx, r8, r9, r10, r12, r13, r14
sum:
 push        r11                    ; save r11 onto stack
 xor         r9, r9                 ; result
 mov         rcx, r11               ; n - k goes to rcx; on beginning: n-0=n
 tonsum                             ; performs first sum from k:=0 to k=n
.rest:                              ; after loop r8 == j + 8n
 mov         rdx, 1                 ; 1:rax
 xor         rax, rax               ; 1:0
 mov         r11, 16                ; preparing division
 div         r11                    ; now 1/16 in rax. it will be current 16 power (cur16pow)
 mov         r10, rax               ; now 1/16 in r10
 xor         rdx, rdx               ;zeros rdx as it will be used for dividing rdx:rax
 fromnsum                           ; performs second sum from k:=n+1 to ...
.quit:
 mov         rax, r9                ; move result to tax
 pop         r11                    ; restore old value of m
 ret         

; @brief: Performs call to external pixtime function
; @arguments:
; %1 - stack delta for ABI
; @modifies: rax
%macro pixtimecall 1
 push        rdi                    ; saves all register which could be changed
 push        rdx
 push        rsi
 sub         rsp, %1
 rdtsc                              ; Read time-stamp counter into EDX:EAX.
 mov         rdi, rdx               ; prepares arguments for pixtime
 shl         rdi, 32
 add         rdi, rax
 call        pixtime
 add         rsp, %1
 pop         rsi                    ; restore all register which could be changed
 pop         rdx
 pop         rdi
%endmacro

; @brief: Saves callee-save registers
; @arguments: none
; @modifies: none
%macro calleepush 0
 push        rbx
 push        rbp
 push        r12
 push        r13
 push        r14
 push        r15
%endmacro

; @brief: Restores callee-save registers
; @arguments: none
; @modifies: none
%macro calleepop 0
 pop         r15
 pop         r14
 pop         r13
 pop         r12
 pop         rbp
 pop         rbx
%endmacro

; @brief: The element with index pidx, m of this table is
; to contain 32 bits from bit number
; 32m + 1 to bit number 32m + 32
; @arguments:
; - rdi - ppi table
; - rsi - pidx
; - rdx - max
; @modifies: rdx, rcx, [rsi], [rdi+pidx]
pix:
 pixtimecall 0                      ; call pixtime function with protection registers
 calleepush                         ; push all callee-save registers
 mov         r15, rdx               ; store max parameter
.iter:
 mov         r11, 0x1               ; prepare increment for pidx
lock xadd [rsi], r11                ; atomic operation of storing pidx to r11 and increment that
 mov         r14, r11               ; store old value of pidx
 cmp         r11, r15               ; check if pidx >= max
 jge         .quit                  ; if so, just quit
 push        r14                    ; save old value of pidx
 shl         r11, 3                 ; m ---> 8m
 mov         r8, 1                  ; j value of sum
 call        sum                    ; perform S_1
 shl         rax, 2                 ; S_1 ---> 4S_1
 mov         rbx, rax               ; store result in rbx
 mov         r8, 4                  ; j value of sum
 call        sum                    ; perform S_4
 shl         rax, 1                 ; S_4 ---> 2S_4
 sub         rbx, rax               ; result -= 2S_4
 mov         r8, 5                  ; j value of sum
 call        sum                    ; perform S_5
 sub         rbx, rax               ; result -= S_5
 mov         r8, 6                  ; j value of sum
 call        sum                    ; perform S_6
 sub         rbx, rax               ; result -= S_6
 shr         rbx, 32                ; get higher 32 bits to lower part
 pop         r14                    ; restore index
 mov         dword [rdi+4*r14], ebx ; update table
 jmp         .iter                  ; loop back
.quit:
 calleepop                          ; push all callee-save registers
 pixtimecall 0                      ; call pixtime function with protection registers
 ret
