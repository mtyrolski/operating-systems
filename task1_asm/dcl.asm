;;;;;;;;;;;;;;;;;;;;;;;;;;
; DCL Encryption machine ;
;;;;;;;;;;;;;;;;;;;;;;;;;;

BUFFSZ equ 2912                           ; input buffer size
REQARGS equ 5                             ; required arguments
P2T42M1 equ 0x3FFFFFFFFFF                 ; 2^{42} - 1
ALSIZE equ 42                             ; alphabet size
FIRST equ 49                              ; last supported character
LAST equ 90                               ; first supported character
ROT1 equ 27                               ; first rotatable position
ROT2 equ 33                               ; second rotatable position
ROT3 equ 35                               ; third rotatable position

SECTION .data
SECTION .bss
lperm: resb 1764                          ; space for 42 * 42 bytes: left permutation (l \in \{0,..,41\}, c \in \{'1',..,'Z'\}
mperm: resb 1764                          ; space for 42 * 42 bytes: mid permutation (l \in \{0,..,41\}, c \in \{'1',..,'Z'\}
rperm: resb 1764                          ; space for 42 * 42 bytes: right permutation (l \in \{0,..,41\}, c \in \{'1',..,'Z'\}
linv: resb 42                             ; space for 42 bytes: inverse of L permutation
rinv: resb 42                             ; space for 42 bytes: inverse of R permutation
buffer: resb BUFFSZ                       ; buffer size (for standard input)
SECTION .text
global _start

; @brief: translates character in use of lookup table
; @arguments:
; %1 - target (8b) register, the place where result will be moved
; %2 - offset, used as index of lookup table
; %3 - lookup table
; @modifies: %1
%macro lookup 3
 mov            %1, byte [%3 + %2]        ; moves %2'th byte from %3 table
%endmacro

; @brief: special procedure to calculate the array index (id): 42*iter + char
; @arguments:
; %1 - iterator register
; %2 - character register
; @modifies: rax
%macro calcid 2
 mov            eax, ALSIZE               ; eax := 42
 mul            %1                        ; ; eax := 42*iter
 add            eax, %2                   ; eax := 42*iter + char
%endmacro

; @brief: rotates parameters of DCL machine, l(r13b) and r (r14b).
; @arguments: none
; @modifies: rax, r13, r14
%macro updatelr 0
 inc            r14b                      ; ++r
 cmp            r14b, ALSIZE              ; check if r overflowed
 je             %%reset_r                 ; if so then reset r
 jmp            %%try_rotate_l            ; if not, it is possible to increment l
%%reset_r:
 xor            r14b, r14b                ; reset r (cycle)
%%try_rotate_l:
 cmp            r14b, ROT1                ; check if r is equal to 'L' - '1'
 je             %%rotate_l                ; if so then rotate
 cmp            r14b, ROT2                ; check if r is equal to 'R' - '1'
 je             %%rotate_l                ; if so then rotate
 cmp            r14b, ROT3                ; check if r is equal to 'T' - '1'
 je             %%rotate_l                ; if so then rotate
 jmp            %%finish                  ; if not then quit
%%rotate_l:
 inc            r13b                      ; ++l
 cmp            r13b, ALSIZE              ; check if l overflowed
 jl             %%finish                  ; if not then quit
 xor            r13b, r13b                ; reset l (cycle)
%%finish:
%endmacro

; @brief: exits with given code
; @arguments:
; %1 - exit code
; @modifies: rax, rbx
%macro exit 1
 mov            ebx, %1                   ; moves exit code
 mov            eax, 1                    ; sys_exit kernel opcode 1
 int            80h                       ; invoke
%endmacro

; @brief: loads arguments from stack and validate them, exit 1 if problem occurs
; @arguments: none
; @modifies: rax, rbx, rcx, rdx, rsp, r8, r9, r10, r11, r12, r13, r14
%macro validate 0
 pop            rax                       ; take number of arguments
 xor            eax, REQARGS              ; check if number is expected
 jne            fail                      ; if no, it is time to exit
 add            rsp, 8                    ; ignore program's name
 pop            r8                        ; take L
 pop            r9                        ; take R
 pop            r10                       ; take T
 pop            r11                       ; take key
 mov            rax, r8                   ; prepare argument for validating permutation
 call           validateperm              ; validating L
 mov            rax, r9                   ; prepare argument for validating permutation
 call           validateperm              ; validating R
 mov            rax, r10                  ; prepare argument for validating permutation
 call           validateperm              ; validating T
 mov            rax, r11                  ; prepare argument for validating permutation
 call           slen                      ; calculate length of key
 xor            eax, 0x2                  ; check if equals to 2
 jne            fail                      ; if not fail
 mov            al, byte[r11]             ; take first character from key
 call           validate_char             ; validate that
 mov            al, byte[r11+1]           ; take second character from key
 call           validate_char             ; validate that
 sub            byte [r11], FIRST         ; "normalize" key[0]
 sub            byte [r11+1], FIRST       ; "normalize" key[1]
 mov            ecx, ALSIZE               ; prepare iterator for check T conditions
 xor            rbx, rbx                  ; zeros all 64 bits of rbx
%%iter:
 dec            ecx                       ; --iterator
 mov            bl, byte [r10+rcx]        ; take T[i]
 cmp            bl, cl                    ; check if there is no fixed point i.e. T[i] != i
 je             fail                      ; if so, fail
 cmp            cl, byte [r10+rbx]        ; check if T[T[i]] = i
 jne            fail                      ; if not, fail
 loop           %%iter                    ; loop

%%quit:
%endmacro

; @brief: proceed with edge permutations: Qr^{-1}R^{-1}Qr, Qr^{-1}RQr. Updates lookup table
; @arguments:
; %1 - reversed permutation
; %2 - lookup table
; rbx - character
; @modifies: rcx, rdx
%macro edgeperm 2
 mov            rdx, rbx                  ; move character to rdx
 call           forward                   ; translate forward character
 lookup         dl, rdx, %1               ; translate characters via reversed permutation
 call           backward                  ; translate backward character
 mov            byte [%2 + rax], dl       ; update lookup table
%endmacro

; @brief: prepares and calculates inverse lookup
; @arguments:
; %1 - orginal permutation
; %2 - place for inversd permutation
; @modifies: rcx, rdx
%macro prepinv 2
 mov            r13, %1
 mov            r14d, %2
 call           inv
%endmacro

; @brief: perform preprocessing, fills tables lperm, rpem, mperm such that:
; lperm represents Qr^{-1}R^{-1}Qr
; mperm represents Ql^{-1}L^{-1}Ql T Ql^{-1}LQl
; rperm represents Qr^{-1}RQr
; for all possible values of l/r (for general named index) and character,
; tables contain calculated values of translated character
; @arguments: none
; @modifies: rax, rbx, rcx, rdx
%macro preproc 0
.preproc:
 xor            rbx, rbx                  ; internal variable (character)
 xor            rcx, rcx                  ; external variable (index)
%%outerloop:
 cmp            cl, ALSIZE                ; check if index reached end
 je             %%quit                    ; if so, read input
 xor            bl, bl                    ; otherwise, start internal body again
%%innerloop:
 calcid         rcx, ebx                  ; calculates lookup id
%%leftpart:
 edgeperm       rinv, lperm               ; preproc left permutation
%%rightpart:
 edgeperm       r9, rperm                 ; preproc right permutation
%%midpart:
 mov            dl, bl                    ; prepare place for character
 call           forward                   ; translate character forward
 lookup         dl, rdx, r8               ; lookup from L table
 call           backward                  ; translate character backward
 lookup         dl, rdx, r10              ; lookup from T table
 call           forward                   ; translate character forward
 lookup         dl, rdx, linv             ; lookup from L^{-1} table
 call           backward                  ; translate character backward
 mov            byte [mperm + rax], dl    ; confirm character to mid lookup
%%out:
 inc            bl                        ; ++character
 cmp            bl, ALSIZE                ; check if character overflowed
 je             %%innerdone               ; if so, inner done
 jmp            %%innerloop               ; otherwise proceed with inner
%%innerdone:
 inc            cl                        ; ++index
 jmp            %%outerloop               ; repeat external loop
%%quit:
%endmacro

; @brief: reads input directly to buffer
; @arguments: none
; @modifies: rax, rbx, rcx, rdx
read2buffer:
 mov            edx, BUFFSZ               ; number of bytes to read
 mov            ecx, buffer               ; reserved space to store input
 xor            ebx, ebx                  ; write to the stdin file
 mov            eax, 3                    ; sys_read kernel opcode 3
 int            80h                       ; invoke
 ret

; @brief: translates forward character by given offset.
; If end of alphabet reached then it is being cycled.
; @arguments:
; edx - character c \in \{0 .. <alphabet size>\}
; ecx - offset \in \{0 .. <alphabet size>\}
; @modifies: rcx, rdx
forward:
 add            edx, ecx                  ; translation forward
 cmp            edx, ALSIZE               ; check potential overflow
 jl             .quit                     ; if not, quit
 sub            edx, ALSIZE               ; cycle in case of overflow
.quit:
 ret

; @brief: translates backward character by given offset.
; If beginning of alphabet reached then it is being cycled.
; @arguments:
; edx - character c \in \{0 .. <alphabet size>\}
; ecx - offset \in \{0 .. <alphabet size>\}
; @modifies: rcx, rdx
backward:
 cmp            edx, ecx                  ; check if cycle is needed
 jnl            .substract                ; if not, just substract
 add            edx, ALSIZE               ; dealing with cycle
.substract:
 sub            edx, ecx                  ; translation backward
.quit:
 ret

; @brief: encrypts data directly stored in buffer.
; @arguments:
; eax - number of correctly loaded bytes
; r13b - l value
; r14b - r value
; @modifies: rax, rbx, rcx, rdx, r11, r12, r13, r14
translate:
 mov            r12d, eax                 ; moved number of correctly loaded bytes to r12d
 xor            ecx, ecx                  ; counter (from 0 to number of characters to be created)
 xor            r11d, r11d                ; zeros all bits, will be used for storing character
.nextchar:
 cmp            ecx, r12d                 ; compares counter with target value
 je             .finished                 ; if whole buffer finished then quit
 updatelr
 mov            r11b, byte [buffer + ecx] ; take next character from buffer
 mov            al, r11b                  ; prepares argument for validating char
 call           validate_char             ; check if considered char is correct, eventually exit 1
 sub            r11b, FIRST               ; -= '1' i.e. "normalize" character: {FIRST; LAST} -> {0, ALSIZE}
 calcid         r14b, r11d                ; calculated id for lookup table
 mov            r11b, byte[rperm + rax]   ; temporary state for new character
 calcid         r13b, r11d                ; calculated id for lookup table
 mov            r11b, byte[mperm + rax]   ; temporary state for new character
 calcid         r14b, r11d                ; calculated id for lookup table
 mov            r11b, byte[lperm + rax]   ; temporary state for new character
 add            r11b, FIRST               ; -= '1' i.e. "denormalize" character: {0, ALSIZE} -> {FIRST; LAST}
 mov            byte [buffer + rcx], r11b ; override old character with translated vesion
 inc            ecx                       ; move forward with index
 jmp            .nextchar                 ; repeat
.finished:
 ret

; @brief: prints to output
; @arguments:
; edx - number of correctly loaded bytes
; @modifies: rax, rbx, rcx
sprint:
 mov            ecx, buffer               ; move the buffer address for printing
 mov            ebx, 1                    ; write to the stdout file
 mov            eax, 4                    ; sys_write kernel opcode 4
 int            80h                       ; invoke
 cmp            eax, 0                    ; check returned value
 jl             fail
 ret

; @brief: process data stored in buffer
; @arguments:
; eax - number of correctly loaded bytes
; r13b - l value
; r14b - r value
; @modifies: rax, rbx, rcx, rdx, r11, r12, r13, r14
procdata:
 call           translate                 ; transforms (encrypts) whole buffer
 mov            edx, r12d                 ; move correctly loaded bytes into edx
 call           sprint                    ; print modified buffer to stdout
 ret

;string w eax
;odpowiedz w eax

; @brief: calculates string length
; @arguments:
; eax - string address
; @modifies: rax
slen:
 mov            edx, eax                  ; moves address of begin to edx
.iter:
 cmp            byte [rax], 0             ; check if 'iterator' reached end
 jz             .finalize                 ; of "iterator" equals to '\0' then finish
 inc            rax                       ; inc "iterator"
 jmp            .iter                     ; take next char
.finalize:
 sub            eax, edx                  ; len = index of \0 - index of beginning
 ret

; @brief: checks if permutation is valid. If not then exit 1.
; @arguments:
; eax - string address
; @modifies: rax, rbx, rcx, rdx, r12, r13, r14
 validateperm:
 mov            rbx, rax                  ; move permutation address;
 call           slen                      ; after than in eax is length
 xor            eax, ALSIZE               ; compares length with alphabet
 jne            fail                      ; if not equal then permutation is invalid
 mov            r14d, ALSIZE              ; r14 is iterator now
 xor            r12, r12                  ; bit mask: r12[k] == 1 <=> k \in permutation
 xor            edx, edx                  ; place for string character
.iter:
 cmp            r14b, 0x0                 ; check if loop can be finished
 je             .finalize                 ; if so then quit
 dec            r14b                      ; --iter
 mov            al, byte [rbx+r14]        ; take next character from permutation
 call           validate_char             ; check if it is valid
 sub            byte [rbx+r14], FIRST     ; normalize character {FIRST; LAST} -> {0, ALSIZE}
.checkbit:
 mov            cl, byte [rbx+r14]        ; takes new value of current character
 mov            r13, 0x1                  ; will be used for testing bit
 shl            r13, cl                   ; 00...1 ---> 00..010...00 where 1 is on r14 position
 test           r12, r13                  ; check if bit wasn't turned on before
 jnz            fail                      ; if so then the same character occurred 2 times
.togglebit:
 or             r12, r13                  ; toggle bit related with given character
 jmp            .iter                     ; loop
.finalize:
 mov            rax, P2T42M1              ; permutation is valud <=> r12 == \sum_{0<=i<=41} 2^i = 2^42 - 1
 xor            r12, rax                  ; compares 2^42 - 1 with bit mask
 jnz            fail                      ; if not then fail
 ret

; @brief: checks if character is valid. If not then exit 1
; @arguments:
; al - character to check
; @modifies: none
 validate_char:
 cmp            al, FIRST                 ; compare with first character of alphabet
 jl             fail                      ; if char < 49 then fail
 cmp            al, LAST                  ; compare with last character of alphabet
 jg             fail                      ; if char > 90 then fail
 ret

; @brief: creates inverse permutation
; @arguments:
; r13 - orginal permutation
; r14 - place for inversd permutation
; @modifies: rcx, rdx
 inv:
 mov            ecx, ALSIZE               ; prepare iterator
 xor            rdx, rdx                  ; prepare place for characters
.iter:
 cmp            cl, 0                     ; check if end reached
 je             .quit                     ; if so, quit
 dec            ecx                       ; --iterator
 mov            dl, byte [r13 + rcx]      ; move next character from orginal permutation
 mov            byte [r14 + rdx], cl      ; move to inversed permutation index
 jmp            .iter                     ; loop
.quit:
 ret

; @brief: finish execution with error code
; @arguments: none
; @modifies: rax, rbx
fail:
 exit           1                         ; finish with error code

_start:
 validate                                 ; load & validate input
.prepstage:                               ; preprocessing
 prepinv        r8, linv                  ; preprocessing for L^{-1}
 prepinv        r9, rinv                  ; preprocessing for R^{-1}
 preproc
 mov            r13b, byte [r11]          ; take l parameter
 mov            r14b, byte [r11+1]        ;take r parameter
.procstage:                               ; processing
 call           read2buffer               ; read input and save to buffer
 cmp            eax, 0                    ; check if sth read
 jl             fail                      ; if -1, error
 je             .finish                   ; if 0, nothing read, just quit
 call           procdata                  ; proceed with read data
 jmp            .procstage                ; loop
.finish:
 exit           0                         ; finish with no error code