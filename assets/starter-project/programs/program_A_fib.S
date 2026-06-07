.text
# Program A - Fibonacci loop.
# Strong temporal locality: same instructions executed many times,
# data is the loop counter (single word).
# Inputs:  word at 0x2000 = N (fibonacci count, e.g. 10)
#          byte at 0x2004 = signed byte to be loaded with LB
# Outputs: word at 0x2010 = fib(N)
#          word at 0x2014 = byte+1 (sign-extended)

_start:
    lui  s0, 0x2          # s0 = 0x2000
    lw   t3, 0(s0)        # t3 = N
    lb   t5, 4(s0)        # t5 = signed byte
    addi t6, t5, 1        # t6 = byte + 1
    addi t0, x0, 0        # f0
    addi t1, x0, 1        # f1
    addi t2, x0, 1        # i = 1
loop:
    add  a0, t0, t1
    add  t0, t1, x0
    add  t1, a0, x0
    addi t2, t2, 1
    blt  t2, t3, loop
    sw   t1, 16(s0)       # store fib(N)
    sw   t6, 20(s0)
    ebreak
