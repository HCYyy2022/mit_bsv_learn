// FourCycle.bsv
//
// This is a four cycle implementation of the RISC-V processor.

import Types::*;
import ProcTypes::*;
import CMemTypes::*;
import RFile::*;
import IMemory::*;
import DMemory::*;
import DelayedMemory::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Vector::*;
import MyFifo::*;
import Ehr::*;
import GetPut::*;

typedef enum {Fetch, Decode, Execute, WriteBack} State deriving (Bits, Eq);

(* synthesize *)
module mkProc(Proc2);
    Reg#(Addr) pc     <- mkRegU;
    RFile      rf     <- mkRFile;
    CsrFile  csrf     <- mkCsrFile;
    DelayedMemory mem <- mkDelayedMemory;

    Reg#(State)        state   <- mkReg(Fetch); 
    //Reg#(MemResp)      f2d     <- mkRegU      ; 
    Reg#(DecodedInst)  dInst     <- mkRegU      ; 
    Reg#(ExecInst)     eInst     <- mkRegU      ; 

    Bool memReady = mem.init.done();

    rule test (!memReady);
        let e = tagged InitDone;
        mem.init.request.put(e);
    endrule

    rule doFetch(state == Fetch && csrf.started);
        state   <= Decode;

        mem.req(MemReq{op: Ld, addr: pc, data: ?});      //fetch 
    endrule

    rule doDecode(state == Decode && csrf.started);
        state    <= Execute;

        let inst <- mem.resp;
        dInst <= decode(inst);
        // trace - print the instruction
        $display("pc: %h inst: (%h) expanded: ", pc, inst, showInst(inst));
        $fflush(stdout);
    endrule

    rule doExecute(state == Execute && csrf.started);
        state    <= WriteBack;

        // read general purpose register values 
        Data rVal1 = rf.rd1(fromMaybe(?, dInst.src1));
        Data rVal2 = rf.rd2(fromMaybe(?, dInst.src2));

        // read CSR values (for CSRR inst)
        Data csrVal = csrf.rd(fromMaybe(?, dInst.csr));

        // execute
        ExecInst eInstTemp = exec(dInst, rVal1, rVal2, pc, ?, csrVal);
        // memory
        if(eInstTemp.iType == Ld) begin
             mem.req(MemReq{op: Ld, addr: eInstTemp.addr, data: ?});
        end else if(eInstTemp.iType == St) begin
            mem.req(MemReq{op: St, addr: eInstTemp.addr, data: eInstTemp.data});
        end
        eInst <= eInstTemp;  
    endrule
    
    rule doWriteBack(state == WriteBack && csrf.started);
        state    <= Fetch;
        // check unsupported instruction at commit time. Exiting
        if(eInst.iType == Unsupported) begin
            $fwrite(stderr, "ERROR: Executing unsupported instruction at pc: %x. Exiting\n", pc);
            $finish;
        end

        let eInstTemp = eInst;
        if(eInstTemp.iType == Ld) begin
             eInstTemp.data <- mem.resp;
        end 

        // write back to reg file
        if(isValid(eInstTemp.dst)) begin
            rf.wr(fromMaybe(?, eInstTemp.dst), eInstTemp.data);
        end

        // update the pc depending on whether the branch is taken or not
        pc <= eInstTemp.brTaken ? eInstTemp.addr : pc + 4;

        // CSR write for sending data to host & stats
        csrf.wr(eInstTemp.iType == Csrw ? eInstTemp.csr : Invalid, eInstTemp.data);
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

    interface dMemInit = mem.init;

endmodule
(* synthesize *)
module mkTb();
    Proc2 proc_inst <-mkProc();
endmodule