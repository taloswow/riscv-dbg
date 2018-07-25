/* Copyright 2018 ETH Zurich and University of Bologna.
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the “License”); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * File:   dmi_jtag_tap.sv
 * Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
 * Date:   19.7.2018
 *
 * Description: JTAG TAP for DMI (according to debug spec 0.13)
 *
 */

module dmi_jtag_tap #(
    parameter int IrLength = 5
)(
    input  logic        tck_i,    // JTAG test clock pad
    input  logic        tms_i,    // JTAG test mode select pad
    input  logic        trst_ni,  // JTAG test reset pad
    input  logic        td_i,     // JTAG test data input pad
    output logic        td_o,     // JTAG test data output pad

    output logic        test_logic_reset_o,
    output logic        run_test_idle_o,
    output logic        shift_dr_o,
    output logic        pause_dr_o,
    output logic        update_dr_o,
    output logic        capture_dr_o,

    // we want to access DMI register
    output logic        dmi_access_o,
    // JTAG is interested in writing the DTM CSR register
    output logic        dtmcs_select_o,
    // clear error state
    output logic        dmi_reset_o,
    // test data to submodule
    output logic        dmi_tdi_o,
    // test data in from submodule
    input  logic        dmi_tdo_i

);

    // to submodule
    assign dmi_tdi_o = td_i;

    enum logic [3:0] { TestLogicReset, RunTestIdle, SelectDrScan,
                     CaptureDr, ShiftDr, Exit1Dr, PauseDr, Exit2Dr,
                     UpdateDr, SelectIrScan, CaptureIr, ShiftIr,
                     Exit1Ir, PauseIr, Exit2Ir, UpdateIr } tap_state_q, tap_state_d;

    localparam BYPASS0   = 'h0;
    localparam IDCODE    = 'h1;
    localparam DTMCSR    = 'h10;
    localparam DMIACCESS = 'h11;
    localparam BYPASS1   = 'h1f;

    typedef struct packed {
        logic [31:18] zero1;
        logic         dmihardreset;
        logic         dmireset;
        logic         zero0;
        logic [14:12] idle;
        logic [11:10] dmistat;
        logic [9:4]   abits;
        logic [3:0]   version;
    } dtmcs_t;

    // ----------------
    // IR logic
    // ----------------
    logic [IrLength-1:0]  jtag_ir_shift_d, jtag_ir_shift_q; // shift register
    logic [IrLength-1:0]  jtag_ir_d, jtag_ir_q; // IR register
    logic capture_ir, shift_ir, pause_ir, update_ir;

    always_comb begin
        jtag_ir_shift_d = jtag_ir_shift_q;
        jtag_ir_d       = jtag_ir_q;

        // IR shift register
        if (shift_ir) begin
            jtag_ir_shift_d = {td_i, jtag_ir_shift_q[IrLength-1:1]};
        end

        // capture IR register
        if (capture_ir) begin
            jtag_ir_d =  'b0101;
        end

        // update IR register
        if (capture_ir) begin
            jtag_ir_d = jtag_ir_shift_q;
        end

        // synchronous test-logic reset
        if (test_logic_reset_o) begin
            jtag_ir_d       = IDCODE;
            jtag_ir_shift_d = IDCODE;
        end
    end

    always_ff @(posedge tck_i, negedge trst_ni) begin
        if (~trst_ni) begin
            jtag_ir_shift_q <= IDCODE;
            jtag_ir_q       <= '0;
        end else begin
            jtag_ir_shift_q <= jtag_ir_shift_q;
            jtag_ir_q       <= jtag_ir_d;
        end
    end

    // ----------------
    // TAP DR Regs
    // ----------------
    // - Bypass
    // - IDCODE
    // - DTM CS
    // Define IDCODE Value
    localparam IDCODE_VALUE = 32'h249511C3;
    // 0001             version
    // 0100100101010001 part number (IQ)
    // 00011100001      manufacturer id (flextronics)
    // 1                required by standard
    logic [31:0] idcode_d, idcode_q;
    logic        idcode_select;
    logic        bypass_select;
    dtmcs_t      dtmcs_d, dtmcs_q;
    logic        bypass_d, bypass_q;  // this is a 1-bit register

    assign dmi_reset_o = dtmcs_q.dmireset;

    always_comb begin
        idcode_d = idcode_q;
        bypass_d = bypass_q;
        dtmcs_d  = dtmcs_q;

        if (capture_dr_o) begin
            if (idcode_select) idcode_d = IDCODE_VALUE;
            if (bypass_select) bypass_d = 1'b0;
            if (dtmcs_select_o) begin
                dtmcs_d  = '{
                                zero1        : '0,
                                dmihardreset : 1'b0,
                                dmireset     : 1'b0,
                                zero0        : '0,
                                idle         : 'd1, // 1: Enter Run-Test/Idle and leave it immediately
                                dmistat      : '0,  // 0: No error
                                abits        : 'd7, // The size of address in dmi
                                version      : 'd1  // Version described in spec version 0.13 (and later?)
                            };
            end
        end

        if (shift_dr_o) begin
            if (idcode_select)  idcode_d = {td_i, idcode_q[31:1]};
            if (bypass_select)  bypass_d = td_i;
            if (dtmcs_select_o) dtmcs_d  = {td_i, dtmcs_q[31:1]};
        end

        if (test_logic_reset_o) begin
            idcode_d = IDCODE_VALUE;
            bypass_d = 1'b0;
        end
    end

    // ----------------
    // Data reg select
    // ----------------
    always_comb begin
        dmi_access_o   = 1'b0;
        dtmcs_select_o = 1'b0;
        idcode_select  = 1'b0;
        bypass_select  = 1'b0;
        case (jtag_ir_q)
            BYPASS0:   bypass_select  = 1'b1;
            IDCODE:    idcode_select  = 1'b1;
            DTMCSR:    dtmcs_select_o = 1'b1;
            DMIACCESS: dmi_access_o   = 1'b1;
            BYPASS1:   bypass_select  = 1'b1;
            default:   bypass_select  = 1'b1;
        endcase
    end

    // ----------------
    // Output select
    // ----------------
    logic tdo_mux;

    always_comb begin
        if (shift_ir) begin
            tdo_mux = jtag_ir_q[0];
        end else begin
          case (jtag_ir_q)    // synthesis parallel_case
            IDCODE:         tdo_mux = idcode_q[0];     // Reading ID code
            DTMCSR:         tdo_mux = dtmcs_q[0];
            DMIACCESS:      tdo_mux = dmi_tdo_i;       // Read from DMI TDO
            default:        tdo_mux = bypass_q;      // BYPASS instruction
          endcase
        end

    end

  // TDO changes state at negative edge of TCK
    always_ff @(negedge tck_i, negedge trst_ni) begin
        if (~trst_ni) begin
            td_o <= 1'b0;
        end else begin
            td_o <= tdo_mux;
        end
    end
    // ----------------
    // TAP FSM
    // ----------------
    // Determination of next state; purely combinatorial
    always_comb begin
        test_logic_reset_o = 1'b0;
        run_test_idle_o    = 1'b0;

        capture_dr_o       = 1'b0;
        shift_dr_o         = 1'b0;
        pause_dr_o         = 1'b0;
        update_dr_o        = 1'b0;

        capture_ir         = 1'b0;
        shift_ir           = 1'b0;
        pause_ir           = 1'b0;
        update_ir          = 1'b0;

        case (tap_state_q)
            TestLogicReset: begin
                test_logic_reset_o = 1'b0;
                tap_state_d = (tms_i) ? TestLogicReset : RunTestIdle;
            end
            RunTestIdle: begin
                run_test_idle_o = 1'b1;
                tap_state_d = (tms_i) ? SelectDrScan : RunTestIdle;
            end
            // DR Path
            SelectDrScan: begin
                tap_state_d = (tms_i) ? SelectIrScan : CaptureDr;
            end
            CaptureDr: begin
                capture_dr_o = 1'b1;
                tap_state_d = (tms_i) ? Exit1Dr : ShiftDr;
            end
            ShiftDr: begin
                shift_dr_o = 1'b1;
                tap_state_d = (tms_i) ? Exit1Dr : ShiftDr;
            end
            Exit1Dr: begin
                tap_state_d = (tms_i) ? UpdateDr : PauseDr;
            end
            PauseDr: begin
                pause_dr_o = 1'b1;
                tap_state_d = (tms_i) ? Exit2Dr : PauseDr;
            end
            Exit2Dr: begin
                tap_state_d = (tms_i) ? UpdateDr : ShiftDr;
            end
            UpdateDr: begin
                update_dr_o = 1'b1;
                tap_state_d = (tms_i) ? SelectDrScan : RunTestIdle;
            end
            // IR Path
            SelectIrScan: begin
                tap_state_d = (tms_i) ? TestLogicReset : CaptureIr;
            end
            // In this controller state, the shift register bank in the
            // Instruction Register parallel loads a pattern of fixed values on
            // the rising edge of TCK. The last two significant bits must always
            // be "01".
            CaptureIr: begin
                capture_ir = 1'b1;
                tap_state_d = (tms_i) ? Exit1Ir : ShiftIr;
            end
            // In this controller state, the instruction register gets connected
            // between TDI and TDO, and the captured pattern gets shifted on
            // each rising edge of TCK. The instruction available on the TDI
            // pin is also shifted in to the instruction register.
            ShiftIr: begin
                shift_ir = 1'b1;
                tap_state_d = (tms_i) ? Exit1Ir : ShiftIr;
            end
            Exit1Ir: begin
                tap_state_d = (tms_i) ? UpdateIr : PauseIr;
            end
            PauseIr: begin
                pause_ir = 1'b1;
                tap_state_d = (tms_i) ? Exit2Ir : PauseIr;
            end
            Exit2Ir: begin
                tap_state_d = (tms_i) ? UpdateIr : ShiftIr;
            end
            // In this controller state, the instruction in the instruction
            // shift register is latched to the latch bank of the Instruction
            // Register on every falling edge of TCK. This instruction becomes
            // the current instruction once it is latched.
            UpdateIr: begin
                update_ir = 1'b1;
                tap_state_d = (tms_i) ? SelectDrScan : RunTestIdle;
            end
            default: tap_state_d = TestLogicReset;  // can't actually happen
      endcase
    end

    always_ff @(posedge tck_i or negedge trst_ni) begin
        if (~trst_ni) begin
            tap_state_q <= RunTestIdle;
            idcode_q    <= IDCODE_VALUE;
            bypass_q    <= 1'b0;
            dtmcs_q     <= '0;
        end else begin
            tap_state_q <= tap_state_d;
            idcode_q    <= idcode_d;
            bypass_q    <= bypass_d;
            dtmcs_q     <= dtmcs_d;
        end
    end


endmodule