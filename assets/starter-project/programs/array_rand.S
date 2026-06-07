.text
# Random-order array sum.
# Same data array at 0x2000 as array_seq, but accessed in the order given
# by an index permutation at 0x2400-0x27FC.  Each load typically misses
# the cache, demonstrating the cost of poor spatial locality.
# Output word at 0x4000 = sum of array.

_start:
    lui  s0, 0x2          # s0 = 0x2000  (array base)
    lui  s2, 0x2
    addi s2, s2, 1024     # s2 = 0x2400 (index list base)
    addi s1, x0, 0        # sum = 0
    addi t0, x0, 0        # i = 0
    addi t1, x0, 256      # n
loop:
    bge  t0, t1, done
    slli t2, t0, 2
    add  t3, s2, t2
    lw   t4, 0(t3)        # idx = indices[i]
    slli t6, t4, 2
    add  t3, s0, t6
    lw   t4, 0(t3)        # value = arr[idx]
    add  s1, s1, t4
    addi t0, t0, 1
    jal  x0, loop
done:
    lui  t5, 0x4
    sw   s1, 0(t5)
    ebreak
