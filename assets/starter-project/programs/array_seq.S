.text
# Sequential array sum.
# Array of 256 words at 0x2000-0x23FC (1 KiB).
# Strong spatial locality: consecutive words land in the same cache block.
# Output word at 0x4000 = sum of array.

_start:
    lui  s0, 0x2          # s0 = 0x2000 (array base)
    addi s1, x0, 0        # sum = 0
    addi t0, x0, 0        # i = 0
    addi t1, x0, 256      # n
loop:
    bge  t0, t1, done
    slli t2, t0, 2
    add  t3, s0, t2
    lw   t4, 0(t3)
    add  s1, s1, t4
    addi t0, t0, 1
    jal  x0, loop
done:
    lui  t5, 0x4
    sw   s1, 0(t5)
    ebreak
