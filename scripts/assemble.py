#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


REGS = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7, "s0": 8, "fp": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15,
    "a6": 16, "a7": 17, "s2": 18, "s3": 19, "s4": 20, "s5": 21,
    "s6": 22, "s7": 23, "s8": 24, "s9": 25, "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
}
for i in range(32):
    REGS[f"x{i}"] = i


def clean_line(line):
    line = line.split("#", 1)[0]
    line = line.split("//", 1)[0]
    return line.strip()


def parse_num(token):
    token = token.strip()
    return int(token, 0)


def reg(token):
    key = token.strip()
    if key not in REGS:
        raise ValueError(f"unknown register {token}")
    return REGS[key]


def tokenize(line):
    return [t for t in re.split(r"[\s,()]+", line.strip()) if t]


def sign_range(value, bits, what):
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    if value < lo or value > hi:
        raise ValueError(f"{what} immediate {value} outside signed {bits}-bit range")
    return value & ((1 << bits) - 1)


def unsigned_range(value, bits, what):
    if value < 0 or value >= (1 << bits):
        raise ValueError(f"{what} immediate {value} outside unsigned {bits}-bit range")
    return value


def enc_r(funct7, rs2, rs1, funct3, rd, opcode=0x33):
    return ((funct7 & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def enc_i(imm, rs1, funct3, rd, opcode):
    imm = sign_range(imm, 12, "I")
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def enc_shift(imm, rs1, funct3, rd, funct7):
    shamt = unsigned_range(imm, 5, "shift")
    return (funct7 << 25) | (shamt << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x13


def enc_s(imm, rs2, rs1, funct3):
    imm = sign_range(imm, 12, "S")
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((imm & 0x1f) << 7) | 0x23


def enc_b(imm, rs2, rs1, funct3):
    if imm % 2 != 0:
        raise ValueError(f"B immediate {imm} is not 2-byte aligned")
    imm = sign_range(imm, 13, "B")
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (((imm >> 1) & 0xf) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def enc_u(imm, rd, opcode):
    imm = unsigned_range(imm, 20, "U")
    return (imm << 12) | (rd << 7) | opcode


def enc_j(imm, rd):
    if imm % 2 != 0:
        raise ValueError(f"J immediate {imm} is not 2-byte aligned")
    imm = sign_range(imm, 21, "J")
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3ff) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xff) << 12) | (rd << 7) | 0x6f


def expand_pseudo(tokens):
    op = tokens[0].lower()
    if op == "nop":
        return [["addi", "x0", "x0", "0"]]
    if op == "ebreak":
        return [[".word", "0x00100073"]]
    if op == "ret":
        return [["jalr", "x0", "0", "ra"]]
    if op == "mv":
        return [["addi", tokens[1], tokens[2], "0"]]
    if op == "j":
        return [["jal", "x0", tokens[1]]]
    if op == "li":
        rd = tokens[1]
        imm = parse_num(tokens[2])
        if -2048 <= imm <= 2047:
            return [["addi", rd, "x0", str(imm)]]
        upper = (imm + 0x800) >> 12
        lower = imm - (upper << 12)
        return [["lui", rd, str(upper & 0xfffff)], ["addi", rd, rd, str(lower)]]
    return [tokens]


def parse_source(path):
    logical = []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = clean_line(raw)
        if not line:
            continue
        while ":" in line:
            label, rest = line.split(":", 1)
            label = label.strip()
            if not label:
                raise ValueError(f"empty label in line: {raw}")
            logical.append(("label", label, raw))
            line = rest.strip()
            if not line:
                break
        if line:
            logical.append(("code", line, raw))
    return logical


def first_pass(logical):
    pc = 0
    labels = {}
    items = []
    for kind, text, raw in logical:
        if kind == "label":
            labels[text] = pc
            continue
        if text.startswith("."):
            tokens = tokenize(text)
            directive = tokens[0].lower()
            if directive in (".text",):
                continue
            if directive == ".org":
                pc = parse_num(tokens[1])
                continue
            if directive == ".word":
                items.append((pc, tokens, raw))
                pc += 4
                continue
            raise ValueError(f"unsupported directive {directive} in: {raw}")
        tokens = tokenize(text)
        expanded = expand_pseudo(tokens)
        for inst in expanded:
            items.append((pc, inst, raw))
            pc += 4
    return labels, items


def imm_or_label(token, labels, pc):
    if token in labels:
        return labels[token] - pc
    return parse_num(token)


def encode(tokens, labels, pc):
    op = tokens[0].lower()

    if op == ".word":
        return parse_num(tokens[1]) & 0xffffffff

    r_ops = {
        "add": (0x00, 0x0), "sub": (0x20, 0x0), "sll": (0x00, 0x1),
        "slt": (0x00, 0x2), "sltu": (0x00, 0x3), "xor": (0x00, 0x4), "srl": (0x00, 0x5),
        "sra": (0x20, 0x5), "or": (0x00, 0x6), "and": (0x00, 0x7),
    }
    if op in r_ops:
        funct7, funct3 = r_ops[op]
        return enc_r(funct7, reg(tokens[3]), reg(tokens[2]), funct3, reg(tokens[1]))

    i_ops = {
        "addi": (0x0, 0x13), "slti": (0x2, 0x13), "sltiu": (0x3, 0x13), "xori": (0x4, 0x13),
        "ori": (0x6, 0x13), "andi": (0x7, 0x13), "lb": (0x0, 0x03),
        "lw": (0x2, 0x03), "jalr": (0x0, 0x67),
    }
    if op in i_ops:
        funct3, opcode = i_ops[op]
        if op in ("lb", "lw"):
            rd, imm, rs1 = reg(tokens[1]), parse_num(tokens[2]), reg(tokens[3])
        elif op == "jalr":
            rd, imm, rs1 = reg(tokens[1]), parse_num(tokens[2]), reg(tokens[3])
        else:
            rd, rs1, imm = reg(tokens[1]), reg(tokens[2]), parse_num(tokens[3])
        return enc_i(imm, rs1, funct3, rd, opcode)

    shift_ops = {"slli": (0x1, 0x00), "srli": (0x5, 0x00), "srai": (0x5, 0x20)}
    if op in shift_ops:
        funct3, funct7 = shift_ops[op]
        return enc_shift(parse_num(tokens[3]), reg(tokens[2]), funct3, reg(tokens[1]), funct7)

    s_ops = {"sb": 0x0, "sw": 0x2}
    if op in s_ops:
        rs2, imm, rs1 = reg(tokens[1]), parse_num(tokens[2]), reg(tokens[3])
        return enc_s(imm, rs2, rs1, s_ops[op])

    b_ops = {"beq": 0x0, "bne": 0x1, "blt": 0x4, "bge": 0x5, "bltu": 0x6, "bgeu": 0x7}
    if op in b_ops:
        imm = imm_or_label(tokens[3], labels, pc)
        return enc_b(imm, reg(tokens[2]), reg(tokens[1]), b_ops[op])

    if op == "lui":
        return enc_u(parse_num(tokens[2]), reg(tokens[1]), 0x37)
    if op == "auipc":
        return enc_u(parse_num(tokens[2]), reg(tokens[1]), 0x17)
    if op == "jal":
        if len(tokens) == 2:
            rd, label = 1, tokens[1]
        else:
            rd, label = reg(tokens[1]), tokens[2]
        return enc_j(imm_or_label(label, labels, pc), rd)

    raise ValueError(f"unsupported instruction: {' '.join(tokens)}")


def assemble(src, out_mem, out_lst):
    logical = parse_source(src)
    labels, items = first_pass(logical)
    encoded = []
    for pc, tokens, raw in items:
        try:
            word = encode(tokens, labels, pc)
        except Exception as exc:
            raise ValueError(f"{src}:{pc:#x}: {raw}\n  {exc}") from exc
        encoded.append((pc, word, tokens, raw))

    with Path(out_mem).open("w", encoding="ascii") as f:
        current = 0
        for pc, word, _, _ in encoded:
            index = pc // 4
            while current < index:
                f.write("00000013\n")
                current += 1
            f.write(f"{word:08x}\n")
            current += 1

    if out_lst:
        with Path(out_lst).open("w", encoding="utf-8") as f:
            for pc, word, tokens, _ in encoded:
                f.write(f"{pc:08x}: {word:08x}    {' '.join(tokens)}\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("-o", "--output", required=True)
    parser.add_argument("-l", "--listing")
    args = parser.parse_args()
    assemble(args.source, args.output, args.listing)


if __name__ == "__main__":
    main()
