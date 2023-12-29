// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 3/11/2018
// Description: Wrapped Spike Model for Tandem Verification

import uvm_pkg::*;

`include "uvm_macros.svh"

import "DPI-C" function int spike_create(string filename, longint unsigned dram_base, int unsigned size);

typedef struct {
  byte priv;
  longint unsigned pc;
  byte is_fp;
  byte rd;
  longint unsigned data;
  int unsigned instr;
  byte was_exception;

  // c910 cosim added
  longint unsigned areg_value [32];
  longint unsigned mstatus_value;
  longint unsigned mcause_value;
  longint unsigned minstret_value;
} commit_log_t;

typedef commit_log_t riscv_commit_log_t;
import "DPI-C" function void spike_tick(output riscv_commit_log_t commit_log);

import "DPI-C" function void clint_tick();

module spike #(
    parameter longint unsigned DramBase = 'h8000_0000,
    parameter int unsigned     Size     = 64 * 1024 * 1024, // 64 Mega Byte
    parameter int unsigned     NR_COMMIT_PORTS = 1,
    parameter int unsigned     NR_COMMIT_PORTS_W = $clog2(NR_COMMIT_PORTS) > 0 ? $clog2(NR_COMMIT_PORTS) : 1,
    parameter int unsigned     NR_RETIRE_PORTS = 1,
    parameter int unsigned     NR_RETIRE_PORTS_W = $clog2(NR_RETIRE_PORTS) > 0 ? $clog2(NR_RETIRE_PORTS) : 1,
    parameter int unsigned     MaxInFlightInstrNum = 64 * 3, // 64 ROB entries * max 3 fold instructions per entry
    parameter int unsigned     MaxInFlightInstrNum_W = $clog2(MaxInFlightInstrNum) > 0 ? $clog2(MaxInFlightInstrNum) : 1 // 64 ROB entries * max 3 fold instructions per entry
)(
    input logic       clk_i,
    input logic       rst_ni,
    input logic       clint_tick_i,
    input logic [NR_COMMIT_PORTS-1:0]                       commit_vld_i,    
    input logic [NR_RETIRE_PORTS-1:0]                       retire_vld_i,    
    input logic [NR_RETIRE_PORTS-1:0][39:0]                 retire_pc_i,
    input logic [NR_RETIRE_PORTS-1:0][39:0]                 retire_nxt_pc_i,
    // input logic [NR_RETIRE_PORTS-1:0][1:0]                  retire_folded_inst_num_i,
    input logic [31:0][63:0]                                areg_value_i,
    input logic [63:0]                                      mstatus_value_i,
    input logic [63:0]                                      mcause_value_i,
    input logic [63:0]                                      minstret_value_i,
    input logic [1:0]                                       priv_lvl_i
);
    static uvm_cmdline_processor uvcl = uvm_cmdline_processor::get_inst();

    string binary = "";

    logic fake_clk;

    logic clint_tick_q, clint_tick_qq, clint_tick_qqq, clint_tick_qqqq;

    initial begin
        void'(uvcl.get_arg_value("+PRELOAD=", binary));
        assert(binary != "") else $error("We need a preloaded binary for tandem verification");
        void'(spike_create(binary, DramBase, Size));
    end

    riscv_commit_log_t commit_log;
    riscv_commit_log_t commit_log_last_inst;
    logic [31:0] instr;

    logic [NR_COMMIT_PORTS_W-1:0] commit_instr_num;
    logic [NR_RETIRE_PORTS_W-1:0] retire_instr_num;
    logic [NR_RETIRE_PORTS_W-1:0] retire_instr_num_per_retire;
    logic [MaxInFlightInstrNum_W-1 : 0] unretired_commited_instr_counter_d, unretired_commited_instr_counter_q;
    logic                         has_retired_inst;
    logic                         has_pc_match;
    logic                         not_the_first_retire;

    assign unretired_commited_instr_counter_d = unretired_commited_instr_counter_q +
                                                commit_instr_num -
                                                retire_instr_num;

    always_comb begin
        commit_instr_num = '0;
        for (int i = 0; i < NR_COMMIT_PORTS; i++) begin
            if(commit_vld_i[i]) begin
                commit_instr_num = commit_instr_num + 1;
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            unretired_commited_instr_counter_q <= '0;
        end else begin
            unretired_commited_instr_counter_q <= unretired_commited_instr_counter_d;
        end
    end

    always_ff @(posedge clk_i) begin
        retire_instr_num = '0;
        has_retired_inst = '0;
        has_pc_match     = '0;
        if (rst_ni) begin
            for (int i = 0; i < NR_RETIRE_PORTS; i++) begin
                has_pc_match     = '0;
                if (retire_vld_i[i]) begin
                    has_retired_inst = 1'b1;
                    $display("vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv");
                    // for(int retire_instr_num_per_retire = 0; retire_instr_num_per_retire < retire_folded_inst_num_i[i]; retire_instr_num_per_retire++) begin
                    while (retire_instr_num < unretired_commited_instr_counter_q) begin
                        retire_instr_num = retire_instr_num + 1;

                        commit_log_last_inst = commit_log;
                        spike_tick(commit_log);
                        if(~not_the_first_retire) begin
                            commit_log_last_inst = commit_log;
                            not_the_first_retire = 1'b1;
                        end
                        instr = (commit_log.instr[1:0] != 2'b11) ? {16'b0, commit_log.instr[15:0]} : commit_log.instr;
                        // $display("vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv");
                        $display("\x1B[pc:%h, inst:%h\x1B]", commit_log.pc, instr);
                        $display("%p", commit_log);
                        $display("\x1B[retire PC: %h\x1B]", retire_pc_i[i]);

                        if(commit_log.pc[39:0] === retire_pc_i[i]) begin // tick spike until reach the first inst of the next retire
                            has_pc_match = 1'b1;
                        
                            // if(retire_instr_num_per_retire == 0) begin // for the first inst of the retire, check pc matching
                            //     assert (commit_log.pc[39:0] === retire_pc_i[i]) else begin
                            //         $warning("\x1B[[Tandem] PCs Mismatch\x1B]");
                            //         $display("Spike PC: %h", commit_log.pc[39:0]);
                            //         $display("TC910 PC: %h", retire_pc_i[i]);
                            //         $display("Spike log: %p", commit_log);
                            //         $display("==========================================");
                            //         $stop;
                            //     end
                            // end

                            assert (commit_log_last_inst.priv === priv_lvl_i) else begin
                                $warning("\x1B[[Tandem] Privilege level mismatches\x1B]");
                                $display("@ PC %h", commit_log_last_inst.pc);
                                $display("Spike priv_lvl: %2d", commit_log_last_inst.priv);
                                $display("TC910 priv_lvl: %2d", priv_lvl_i);
                                $display("==========================================");
                                $stop;
                            end

                            // check the csr
                            assert (mstatus_value_i[i] === commit_log_last_inst.mstatus_value) else begin
                                $warning("\x1B[[Tandem] mstatus mismatches\x1B]");
                                $display("@ PC %h", commit_log_last_inst.pc);
                                $display("Spike mstatus: %h", commit_log_last_inst.mstatus_value);
                                $display("TC910 mstatus: %h", mstatus_value_i[i]);
                                $display("==========================================");
                            end
                            assert (mcause_value_i[i] === commit_log_last_inst.mcause_value) else begin
                                $warning("\x1B[[Tandem] mcause mismatches\x1B]");
                                $display("@ PC %h", commit_log_last_inst.pc);
                                $display("Spike mcause: %h", commit_log_last_inst.mcause_value);
                                $display("TC910 mcause: %h", mcause_value_i[i]);
                                $display("==========================================");
                            end

                            // check the architectural registers
                            for(int k = 0; k < 32; k++) begin
                                // check the register value
                                $display("\x1B[x%d %h vs %h\x1B]", k, areg_value_i[k], commit_log_last_inst.areg_value[k]);
                                
                                if(^areg_value_i[k] !== 1'bx) begin                            
                                    assert (areg_value_i[k] === commit_log_last_inst.areg_value[k]) else begin
                                        $warning("\x1B[[Tandem] x%d register mismatches\x1B]", k);
                                        $display("@ PC %h", commit_log_last_inst.pc);
                                        $display("Spike x%d: %h", k, commit_log_last_inst.areg_value[k]);
                                        $display("TC910 x%d: %h", k, areg_value_i[k]);
                                        $display("==========================================");
                                        $stop;
                                    end
                                end else begin
                                    assert (commit_log_last_inst.areg_value[k] === '0) else begin
                                        $warning("\x1B[[Tandem] x%d register mismatches\x1B]", k);
                                        $display("@ PC %h", commit_log_last_inst.pc);
                                        $display("Spike x%d: %h", k, commit_log_last_inst.areg_value[k]);
                                        $display("TC910 x%d: %h", k, areg_value_i[k]);
                                        $display("==========================================");
                                        $stop;
                                    end
                                end
                            end
                            break;
                        end
                    end

                    assert (has_pc_match) else begin
                        $warning("\x1B[[Tandem] PCs Mismatch\x1B]");
                        $display("Spike PC: %h", commit_log_last_inst.pc[39:0]);
                        $display("TC910 PC: %h", retire_pc_i[i]);
                        $display("Spike log: %p", commit_log_last_inst);
                        for(int k = 0; k < 32; k++) begin
                            $display("\x1B[x%d %h vs %h\x1B]", k, areg_value_i[k], commit_log_last_inst.areg_value[k]);
                        end
                        $display("==========================================");
                        $stop;
                    end

                    assert (retire_instr_num <= unretired_commited_instr_counter_q) else begin
                        $warning("\x1B[[Tandem] retire%d: retire more inst than commited but not retired ones\x1B]", i);
                        $display("Spike PC: %h", commit_log_last_inst.pc[39:0]);
                        $display("TC910 PC: %h", retire_pc_i[i]);
                        $display("==========================================");
                        $stop;
                    end
                end
            end
            if(has_retired_inst) begin
                assert (minstret_value_i === commit_log_last_inst.minstret_value) else begin
                    $warning("\x1B[[Tandem] minstret mismatches\x1B]");
                    $display("@ PC %h", commit_log_last_inst.pc);
                    $display("Spike minstret: %h", commit_log_last_inst.minstret_value);
                    $display("TC910 minstret: %h", minstret_value_i);
                    $display("==========================================");
                    // $stop;
                end
            end
        end else begin
            not_the_first_retire = '0;
        end
    end

    // we want to schedule the timer increment at the end of this cycle
    assign #1ps fake_clk = clk_i;

    always_ff @(posedge fake_clk) begin
        clint_tick_q <= clint_tick_i;
        clint_tick_qq <= clint_tick_q;
        clint_tick_qqq <= clint_tick_qq;
        clint_tick_qqqq <= clint_tick_qqq;
    end

    always_ff @(posedge clint_tick_qqqq) begin
        if (rst_ni) begin
            void'(clint_tick());
        end
    end
endmodule