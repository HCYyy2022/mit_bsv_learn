// TwoCycle.bsv
//
// This is a two cycle implementation of the RISC-V processor.

import Types::*;
import ProcTypes::*;
import CMemTypes::*;
import RFile::*;
import IMemory::*;
import DMemory::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Vector::*;
import MyFifo::*;
import Ehr::*;
import GetPut::*;

typedef enum {Fetch, Execute} State deriving (Bits, Eq);

(* synthesize *)
module mkProc(Proc2);
    Reg#(Addr) pc <- mkRegU;
    RFile      rf <- mkRFile;
    //IMemory  iMem <- mkIMemory;
    DMemory  dMem <- mkDMemory;
    CsrFile  csrf <- mkCsrFile;

    Reg#(State) state        <- mkReg(Fetch); 
    Reg#(DecodedInst)  fd2ex <- mkRegU      ; 

    Bool memReady = dMem.init.done();

    rule test (!memReady);
        let e = tagged InitDone;
        dMem.init.request.put(e);
    endrule
    
    rule doFetchDecode(state == Fetch && csrf.started);
        let    inst <- dMem.req(MemReq{op: Ld, addr: pc, data: ?});      //fetch    //TODO: 测试下=号
        fd2ex   <= decode( inst );                                       //decode
        state   <= Execute;

        // trace - print the instruction
        $display("pc: %h inst: (%h) expanded: ", pc, inst, showInst(inst));
        $fflush(stdout);
    endrule

    rule doExecute(state == Execute && csrf.started);
        state <= Fetch;

        let dInst = fd2ex;

        // read general purpose register values 
        Data rVal1 = rf.rd1(fromMaybe(?, dInst.src1));
        Data rVal2 = rf.rd2(fromMaybe(?, dInst.src2));

        // read CSR values (for CSRR inst)
        Data csrVal = csrf.rd(fromMaybe(?, dInst.csr));

        // execute
        ExecInst eInst = exec(dInst, rVal1, rVal2, pc, ?, csrVal);  
        // The fifth argument above is the predicted pc, to detect if it was mispredicted. 
        // Since there is no branch prediction, this field is sent with a random value

        // memory
        if(eInst.iType == Ld) begin
            eInst.data <- dMem.req(MemReq{op: Ld, addr: eInst.addr, data: ?});
        end else if(eInst.iType == St) begin
            let d <- dMem.req(MemReq{op: St, addr: eInst.addr, data: eInst.data});
        end

        // commit


        // check unsupported instruction at commit time. Exiting
        if(eInst.iType == Unsupported) begin
            $fwrite(stderr, "ERROR: Executing unsupported instruction at pc: %x. Exiting\n", pc);
            $finish;
        end

        /* 
        // These codes are checking invalid CSR index
        // you could uncomment it for debugging
        // 
        // check invalid CSR read
        if(eInst.iType == Csrr) begin
            let csrIdx = fromMaybe(0, eInst.csr);
            case(csrIdx)
                csrCycle, csrInstret, csrMhartid: begin
                    $display("CSRR reads 0x%0x", eInst.data);
                end
                default: begin
                    $fwrite(stderr, "ERROR: read invalid CSR 0x%0x. Exiting\n", csrIdx);
                    $finish;
                end
            endcase
        end
        // check invalid CSR write
        if(eInst.iType == Csrw) begin
            let csrIdx = fromMaybe(0, eInst.csr);
            if(csrIdx != csrMtohost) begin
                $fwrite(stderr, "ERROR: invalid CSR index = 0x%0x. Exiting\n", csrIdx);
                $finish;
            end
            else begin
                $display("CSRW writes 0x%0x", eInst.data);
            end
        end
        */

        // write back to reg file
        if(isValid(eInst.dst)) begin
            rf.wr(fromMaybe(?, eInst.dst), eInst.data);
        end

        // update the pc depending on whether the branch is taken or not
        pc <= eInst.brTaken ? eInst.addr : pc + 4;

        // CSR write for sending data to host & stats
        csrf.wr(eInst.iType == Csrw ? eInst.csr : Invalid, eInst.data);
    endrule

    method ActionValue#(CpuToHostData) cpuToHost;
        let ret <- csrf.cpuToHost;
        return ret;
    endmethod

    method Action hostToCpu(Bit#(32) startpc) if ( !csrf.started && memReady );
        csrf.start(0); // only 1 core, id = 0
        $display("Start at pc 200\n");
        $fflush(stdout);
        pc <= startpc;
    endmethod

    //interface iMemInit = iMem.init;
    interface dMemInit = dMem.init;
endmodule