`timescale 1ns/1ps

// Unified testbench for the three SoC configurations.  Pick one with
// `+define+CONFIG_NOCACHE`, `+define+CONFIG_L1`, or `+define+CONFIG_L2`
// at xvlog time.  Plusargs control the program loaded into main memory,
// the expected memory image, the cycle budget, and the path of the JSON
// results file emitted at termination.
module tb_cache_soc;
    // Common signals
    reg clk;
    reg rst;

    wire        retire_valid;
    wire [31:0] retire_pc;
    wire [31:0] retire_instr;
    wire        debug_imem_stall;
    wire        debug_dmem_stall;
    wire        debug_load_use_stall;
    wire        debug_branch_flush;
    wire [63:0] cycles;
    wire [63:0] instr_retired;
    wire [63:0] imem_stall_cycles;
    wire [63:0] dmem_stall_cycles;
    wire [63:0] load_use_stalls;
    wire [63:0] branch_flushes;

    wire [31:0] mem_accesses;

`ifdef CONFIG_NOCACHE
    wire [31:0] imem_accesses;
    wire [31:0] dmem_accesses;
    riscv_nocache_soc #(
        .BLOCK_BYTES   (32),
        .MEM_SIZE_BYTES(1<<16),
        .MEM_LATENCY   (100)
    ) dut (
        .clk(clk), .rst(rst),
        .retire_valid(retire_valid),
        .retire_pc(retire_pc), .retire_instr(retire_instr),
        .debug_imem_stall(debug_imem_stall),
        .debug_dmem_stall(debug_dmem_stall),
        .debug_load_use_stall(debug_load_use_stall),
        .debug_branch_flush(debug_branch_flush),
        .cycles(cycles), .instr_retired(instr_retired),
        .imem_stall_cycles(imem_stall_cycles),
        .dmem_stall_cycles(dmem_stall_cycles),
        .load_use_stalls(load_use_stalls),
        .branch_flushes(branch_flushes),
        .imem_accesses(imem_accesses),
        .dmem_accesses(dmem_accesses),
        .mem_accesses(mem_accesses)
    );
`else
    wire [31:0] icache_hits;
    wire [31:0] icache_misses;
    wire [31:0] dcache_hits;
    wire [31:0] dcache_misses;
    wire [31:0] dcache_writes_through;
    wire [31:0] l2_hits;
    wire [31:0] l2_misses;

    riscv_cached_soc #(
`ifdef CFG_ICACHE_BYTES
        .ICACHE_SIZE_BYTES(`CFG_ICACHE_BYTES),
`endif
`ifdef CFG_ICACHE_WAYS
        .ICACHE_WAYS(`CFG_ICACHE_WAYS),
`endif
`ifdef CFG_DCACHE_BYTES
        .DCACHE_SIZE_BYTES(`CFG_DCACHE_BYTES),
`endif
`ifdef CFG_DCACHE_WAYS
        .DCACHE_WAYS(`CFG_DCACHE_WAYS),
`endif
`ifdef CFG_BLOCK_BYTES
        .BLOCK_BYTES(`CFG_BLOCK_BYTES),
`endif
`ifdef CONFIG_L2
        .ENABLE_L2(1),
`else
        .ENABLE_L2(0),
`endif
`ifdef CFG_L2_BYTES
        .L2_SIZE_BYTES(`CFG_L2_BYTES),
`endif
`ifdef CFG_L2_WAYS
        .L2_WAYS(`CFG_L2_WAYS),
`endif
`ifdef CFG_L2_LATENCY
        .L2_HIT_LATENCY(`CFG_L2_LATENCY),
`endif
        .MEM_SIZE_BYTES(1<<16),
        .MEM_LATENCY(100)
    ) dut (
        .clk(clk), .rst(rst),
        .retire_valid(retire_valid),
        .retire_pc(retire_pc), .retire_instr(retire_instr),
        .debug_imem_stall(debug_imem_stall),
        .debug_dmem_stall(debug_dmem_stall),
        .debug_load_use_stall(debug_load_use_stall),
        .debug_branch_flush(debug_branch_flush),
        .cycles(cycles), .instr_retired(instr_retired),
        .imem_stall_cycles(imem_stall_cycles),
        .dmem_stall_cycles(dmem_stall_cycles),
        .load_use_stalls(load_use_stalls),
        .branch_flushes(branch_flushes),
        .icache_hits(icache_hits), .icache_misses(icache_misses),
        .dcache_hits(dcache_hits), .dcache_misses(dcache_misses),
        .dcache_writes_through(dcache_writes_through),
        .l2_hits(l2_hits), .l2_misses(l2_misses),
        .mem_accesses(mem_accesses)
    );
`endif

    // Clock
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    reg [1023:0] mem_init_file;
    reg [1023:0] data_init_file;
    reg [1023:0] expect_file;
    reg [1023:0] result_file;
    reg [1023:0] vcd_file;
    integer max_cycles;
    integer baseline_cycles;
    real    real_dhit_rate, real_dmiss_rate;
    real    real_ihit_rate, real_imiss_rate;
    real    real_l2_hit_rate, real_l2_miss_rate;
    real    real_amat_d, real_amat_i, real_speedup;
    real    real_cpi;
    real    real_miss_penalty_d;
    integer fd_result;
    integer halt_seen;
    integer halt_drain;
    integer failed;
    integer finished;
    integer rc;
    integer expect_fd;
    integer pass_cnt, fail_cnt;
    reg [31:0] exp_addr, exp_value, actual;
    integer i;
    reg [31:0] tmp_words [0:8191];   // word-form image buffer
    integer    init_words;
    integer    init_bytes;
    integer    base_byte;

    initial begin
        mem_init_file  = "";
        data_init_file = "";
        expect_file    = "";
        result_file    = "results.json";
        vcd_file       = "";
        max_cycles      = 200_000_000;
        baseline_cycles = 0;
        halt_seen       = 0;
        halt_drain      = 0;
        failed          = 0;
        finished        = 0;

        if (!$value$plusargs("MEM=%s",             mem_init_file))   begin end
        if (!$value$plusargs("DATA=%s",            data_init_file))  begin end
        if (!$value$plusargs("EXPECT=%s",          expect_file))     begin end
        if (!$value$plusargs("RESULTS=%s",         result_file))     begin end
        if (!$value$plusargs("MAX_CYCLES=%d",      max_cycles))      begin end
        if (!$value$plusargs("BASELINE_CYCLES=%d", baseline_cycles)) begin end
        if ($test$plusargs("VCD")) begin
            // XSim's $dumpfile only accepts a literal string, so the
            // file always lands in the current build directory under
            // the well-known name `trace.vcd`.  scripts/run_sim.sh moves
            // it where the caller asked.
            $dumpfile("trace.vcd");
            $dumpvars(0, tb_cache_soc);
        end

        rst = 1'b1;
        // initialise main memory contents.  The cached SoC instantiates
        // u_mem either inside gen_l2 (when L2 is enabled) or inside
        // gen_no_l2 (when L2 is disabled), so the hierarchical reference
        // depends on the CONFIG_* define.  The byte array itself is the
        // same shape in both cases.
`ifdef CONFIG_NOCACHE
        `define U_MEM dut.u_mem
`elsif CONFIG_L2
        `define U_MEM dut.gen_l2.u_mem
`else
        `define U_MEM dut.gen_no_l2.u_mem
`endif
        for (i = 0; i < (1<<16); i = i + 1) `U_MEM.mem[i] = 8'd0;

        if (mem_init_file != "") begin
            // Word-form .mem: one 32-bit hex per line.  Load into the
            // word buffer, then unpack into the byte-wide memory in
            // little-endian order.
            for (i = 0; i < 8192; i = i + 1) tmp_words[i] = 32'd0;
            $readmemh(mem_init_file, tmp_words);
            for (i = 0; i < 8192; i = i + 1) begin
                `U_MEM.mem[i*4 + 0] = tmp_words[i][7:0];
                `U_MEM.mem[i*4 + 1] = tmp_words[i][15:8];
                `U_MEM.mem[i*4 + 2] = tmp_words[i][23:16];
                `U_MEM.mem[i*4 + 3] = tmp_words[i][31:24];
            end
        end
        if (data_init_file != "") begin
            // Byte-form .dmem: one byte per hex token, loaded at 0x2000.
            $readmemh(data_init_file, `U_MEM.mem, 32'h2000);
        end

        repeat (5) @(posedge clk);
        rst = 1'b0;
    end

    integer trace_count;
    initial trace_count = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (!finished && retire_valid) begin
                if (trace_count < 200) begin
                    $display("RETIRE %0d  pc=%08x instr=%08x  cyc=%0d", trace_count, retire_pc, retire_instr, cycles);
                    trace_count <= trace_count + 1;
                end
                if (retire_instr == 32'h00100073) begin
                    halt_seen  <= 1;
                    halt_drain <= 0;
                end
            end
            if (!finished && halt_seen) begin
                halt_drain <= halt_drain + 1;
                if (halt_drain == 8) begin
                    finish_run();
                end
            end
            if (!finished && cycles > max_cycles) begin
                $display("ERROR: timeout after %0d cycles", max_cycles);
                finish_run();
            end
        end
    end

    function [31:0] peek_system_word;
        input [31:0] addr;
        begin
`ifdef CONFIG_NOCACHE
            peek_system_word = dut.u_mem.peek_word(addr);
`else
            if (dut.u_dcache.peek_hit(addr)) begin
                peek_system_word = dut.u_dcache.peek_word(addr);
            end
`ifdef CONFIG_L2
            else if (dut.gen_l2.u_l2.peek_hit(addr)) begin
                peek_system_word = dut.gen_l2.u_l2.peek_word(addr);
            end
            else begin
                peek_system_word = dut.gen_l2.u_mem.peek_word(addr);
            end
`else
            else begin
                peek_system_word = dut.gen_no_l2.u_mem.peek_word(addr);
            end
`endif
`endif
        end
    endfunction

    task finish_run;
        begin
            if (finished) begin
                disable finish_run;
            end
            finished = 1;
            pass_cnt = 0;
            fail_cnt = 0;
            if (expect_file != "") begin
                expect_fd = $fopen(expect_file, "r");
                if (expect_fd == 0) begin
                    $display("WARN: failed to open expect file %0s", expect_file);
                end else begin
                    while (!$feof(expect_fd)) begin
                        rc = $fscanf(expect_fd, "%h %h\n", exp_addr, exp_value);
                        if (rc == 2) begin
                            actual = peek_system_word(exp_addr);
                            if (actual !== exp_value) begin
                                $display("FAIL mem[%08x] expected %08x got %08x",
                                         exp_addr, exp_value, actual);
                                fail_cnt = fail_cnt + 1;
                                failed = 1;
                            end else begin
                                $display("PASS mem[%08x] = %08x", exp_addr, actual);
                                pass_cnt = pass_cnt + 1;
                            end
                        end
                    end
                    $fclose(expect_fd);
                end
            end

            // ----- Derived metrics (AMAT, hit rates, CPI, speedup) -----
            // Hit rates are computed with a tiny epsilon-style fallback so
            // we never divide by zero on programs that never touch a port.
`ifndef CONFIG_NOCACHE
            real_ihit_rate    = (icache_hits + icache_misses) == 0 ? 0.0 :
                                (icache_hits * 1.0) / (icache_hits + icache_misses);
            real_imiss_rate   = 1.0 - real_ihit_rate;
            real_dhit_rate    = (dcache_hits + dcache_misses) == 0 ? 0.0 :
                                (dcache_hits * 1.0) / (dcache_hits + dcache_misses);
            real_dmiss_rate   = 1.0 - real_dhit_rate;
  `ifdef CONFIG_L2
            real_l2_hit_rate  = (l2_hits + l2_misses) == 0 ? 0.0 :
                                (l2_hits * 1.0) / (l2_hits + l2_misses);
            real_l2_miss_rate = 1.0 - real_l2_hit_rate;
            // AMAT_L2 = 10 (L2 hit time) + L2_miss_rate * 100 (main mem)
            // AMAT_d  = 1  (L1 hit time) + d_miss_rate    * AMAT_L2
            real_miss_penalty_d = 10.0 + real_l2_miss_rate * 100.0;
            real_amat_d         = 1.0 + real_dmiss_rate * real_miss_penalty_d;
            real_amat_i         = 1.0 + real_imiss_rate * real_miss_penalty_d;
  `else
            real_l2_hit_rate    = 0.0;
            real_l2_miss_rate   = 0.0;
            real_miss_penalty_d = 100.0;
            real_amat_d         = 1.0 + real_dmiss_rate * 100.0;
            real_amat_i         = 1.0 + real_imiss_rate * 100.0;
  `endif
`else
            // No cache:  every access pays the full main-memory latency.
            real_ihit_rate      = 0.0;
            real_imiss_rate     = 1.0;
            real_dhit_rate      = 0.0;
            real_dmiss_rate     = 1.0;
            real_l2_hit_rate    = 0.0;
            real_l2_miss_rate   = 1.0;
            real_miss_penalty_d = 100.0;
            real_amat_d         = 100.0;
            real_amat_i         = 100.0;
`endif
            real_cpi     = (instr_retired == 0) ? 0.0 :
                           (cycles * 1.0) / (instr_retired * 1.0);
            real_speedup = (baseline_cycles == 0 || cycles == 0) ? 0.0 :
                           (baseline_cycles * 1.0) / (cycles * 1.0);

            // Print summary
            $display("=================== SIM SUMMARY ===================");
`ifdef CONFIG_NOCACHE
            $display("CONFIG = NOCACHE");
`elsif CONFIG_L2
            $display("CONFIG = L1 + L2");
`else
            $display("CONFIG = L1 only");
`endif
            $display("cycles            = %0d", cycles);
            $display("instr_retired     = %0d", instr_retired);
            $display("imem_stall_cycles = %0d", imem_stall_cycles);
            $display("dmem_stall_cycles = %0d", dmem_stall_cycles);
            $display("load_use_stalls   = %0d", load_use_stalls);
            $display("branch_flushes    = %0d", branch_flushes);
`ifdef CONFIG_NOCACHE
            $display("imem_accesses     = %0d", imem_accesses);
            $display("dmem_accesses     = %0d", dmem_accesses);
`else
            $display("icache_hits       = %0d", icache_hits);
            $display("icache_misses     = %0d", icache_misses);
            $display("dcache_hits       = %0d", dcache_hits);
            $display("dcache_misses     = %0d", dcache_misses);
            $display("dcache_wt         = %0d", dcache_writes_through);
            $display("l2_hits           = %0d", l2_hits);
            $display("l2_misses         = %0d", l2_misses);
`endif
            $display("mem_accesses      = %0d", mem_accesses);
            // Derived metrics
            $display("icache_hit_rate   = %0.4f", real_ihit_rate);
            $display("dcache_hit_rate   = %0.4f", real_dhit_rate);
`ifdef CONFIG_L2
            $display("l2_hit_rate       = %0.4f", real_l2_hit_rate);
`endif
            $display("CPI               = %0.3f", real_cpi);
            $display("AMAT_d (cycles)   = %0.3f", real_amat_d);
            $display("AMAT_i (cycles)   = %0.3f", real_amat_i);
            if (baseline_cycles != 0) begin
                $display("baseline_cycles   = %0d", baseline_cycles);
                $display("speedup           = %0.3fx", real_speedup);
            end
            $display("expect_pass=%0d fail=%0d", pass_cnt, fail_cnt);
            $display("===================================================");

            // JSON results file
            fd_result = $fopen(result_file, "w");
            if (fd_result != 0) begin
                $fdisplay(fd_result, "{");
`ifdef CONFIG_NOCACHE
                $fdisplay(fd_result, "  \"config\": \"nocache\",");
`elsif CONFIG_L2
                $fdisplay(fd_result, "  \"config\": \"l1_l2\",");
`else
                $fdisplay(fd_result, "  \"config\": \"l1\",");
`endif
                $fdisplay(fd_result, "  \"cycles\": %0d,", cycles);
                $fdisplay(fd_result, "  \"instr_retired\": %0d,", instr_retired);
                $fdisplay(fd_result, "  \"imem_stall_cycles\": %0d,", imem_stall_cycles);
                $fdisplay(fd_result, "  \"dmem_stall_cycles\": %0d,", dmem_stall_cycles);
                $fdisplay(fd_result, "  \"load_use_stalls\": %0d,", load_use_stalls);
                $fdisplay(fd_result, "  \"branch_flushes\": %0d,", branch_flushes);
`ifdef CONFIG_NOCACHE
                $fdisplay(fd_result, "  \"imem_accesses\": %0d,", imem_accesses);
                $fdisplay(fd_result, "  \"dmem_accesses\": %0d,", dmem_accesses);
`else
                $fdisplay(fd_result, "  \"icache_hits\": %0d,", icache_hits);
                $fdisplay(fd_result, "  \"icache_misses\": %0d,", icache_misses);
                $fdisplay(fd_result, "  \"dcache_hits\": %0d,", dcache_hits);
                $fdisplay(fd_result, "  \"dcache_misses\": %0d,", dcache_misses);
                $fdisplay(fd_result, "  \"dcache_writes_through\": %0d,", dcache_writes_through);
                $fdisplay(fd_result, "  \"l2_hits\": %0d,", l2_hits);
                $fdisplay(fd_result, "  \"l2_misses\": %0d,", l2_misses);
`endif
                $fdisplay(fd_result, "  \"mem_accesses\": %0d,", mem_accesses);
                $fdisplay(fd_result, "  \"icache_hit_rate\": %0.6f,", real_ihit_rate);
                $fdisplay(fd_result, "  \"dcache_hit_rate\": %0.6f,", real_dhit_rate);
                $fdisplay(fd_result, "  \"l2_hit_rate\": %0.6f,", real_l2_hit_rate);
                $fdisplay(fd_result, "  \"cpi\": %0.6f,", real_cpi);
                $fdisplay(fd_result, "  \"amat_d\": %0.6f,", real_amat_d);
                $fdisplay(fd_result, "  \"amat_i\": %0.6f,", real_amat_i);
                $fdisplay(fd_result, "  \"baseline_cycles\": %0d,", baseline_cycles);
                $fdisplay(fd_result, "  \"speedup\": %0.6f,", real_speedup);
                $fdisplay(fd_result, "  \"pass\": %0d,", pass_cnt);
                $fdisplay(fd_result, "  \"fail\": %0d", fail_cnt);
                $fdisplay(fd_result, "}");
                $fclose(fd_result);
            end

            if (failed) begin
                $display("TEST FAILED");
                $finish;
            end else begin
                $display("TEST PASSED");
                $finish;
            end
        end
    endtask
endmodule
