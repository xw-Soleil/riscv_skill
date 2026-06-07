.text
# Program C - Vowel counter.
# String of 16 ASCII bytes at 0x2000.  Counts upper-case vowels.
# Outputs word at 0x2030 = vowel count.

_start:
    lui  s0, 0x2          # s0 = 0x2000 (string base)
    addi s1, x0, 0        # vowel count
    addi t0, x0, 0        # i = 0
    addi t1, x0, 16       # n
loop:
    bge  t0, t1, done
    add  t2, s0, t0
    lb   t3, 0(t2)
    addi t4, x0, 65       # 'A'
    beq  t3, t4, hit
    addi t4, x0, 69       # 'E'
    beq  t3, t4, hit
    addi t4, x0, 73       # 'I'
    beq  t3, t4, hit
    addi t4, x0, 79       # 'O'
    beq  t3, t4, hit
    addi t4, x0, 85       # 'U'
    beq  t3, t4, hit
nohit:
    addi t0, t0, 1
    jal  x0, loop
hit:
    addi s1, s1, 1
    addi t0, t0, 1
    jal  x0, loop
done:
    lui  t5, 0x2
    sw   s1, 48(t5)       # store at 0x2030
    ebreak
