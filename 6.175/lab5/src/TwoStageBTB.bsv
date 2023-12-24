// TwoStageBTB.bsv
//
// This is a two stage pipelined (with BTB) implementation of the RISC-V processor.

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
import Btb::*;

typedef enum {Fetch, Execute} State deriving (Bits, Eq);

(* synthesize *)
module mkProc(Proc);
    Reg#(Addr) pc <- mkRegU;
    RFile      rf <- mkRFile;
    IMemory  iMem <- mkIMemory;
    DMemory  dMem <- mkDMemory;
    CsrFile  csrf <- mkCsrFile;
    
    Reg#(Bool) fEpoch <- mkReg(False);
    Reg#(Bool) eEpoch <- mkReg(False);

    Fifo#(2, DecodedInst2) f2d  <- mkCFFifo();
    Fifo#(2, Redirect) execRedirect <- mkCFFifo();
    
    Btb#(8)   btb  <- mkBtb();


    Bool memReady = iMem.init.done() && dMem.init.done();
    rule test (!memReady);
        let e = tagged InitDone;
        iMem.init.request.put(e);
        dMem.init.request.put(e);
    endrule

    rule doFetchDecode(csrf.started);
        Data inst = iMem.req(pc);         // fetch
        DecodedInst dInst = decode(inst); // decode
        
        if(execRedirect.notEmpty) begin
            let redict = execRedirect.first;
            fEpoch <= !fEpoch;
            pc     <= redict.nextPc;
            execRedirect.deq;
            btb.update(redict.pc, redict.nextPc);
            //if(redict.mispredict) begin
            //    fEpoch <= !fEpoch;
            //    pc     <= redict.nextPc;
            //end
        end
        else begin
            let ppc = btb.predPc(pc);
            pc      <= ppc;
            f2d.enq( DecodedInst2{dInst:dInst,  pc:pc, ppc:ppc, epoch:fEpoch } );
        end
    endrule

    rule doExecute(csrf.started);
        let x = f2d.first;
        let dInst = x.dInst;

        if(x.epoch == eEpoch) begin
            // read general purpose register values 
            Data rVal1 = rf.rd1(fromMaybe(?, dInst.src1));
            Data rVal2 = rf.rd2(fromMaybe(?, dInst.src2));
            // read CSR values (for CSRR inst)
            Data csrVal = csrf.rd(fromMaybe(?, dInst.csr));
            // execute
            ExecInst eInst = exec(dInst, rVal1, rVal2, x.pc, x.ppc, csrVal);  
            // memory
            if(eInst.iType == Ld) begin
                eInst.data <- dMem.req(MemReq{op: Ld, addr: eInst.addr, data: ?});
            end else if(eInst.iType == St) begin
                let d <- dMem.req(MemReq{op: St, addr: eInst.addr, data: eInst.data});
            end
            // check unsupported instruction at commit time. Exiting
            if(eInst.iType == Unsupported) begin
                $fwrite(stderr, "ERROR: Executing unsupported instruction at pc: %x. Exiting\n", pc);
                $finish;
            end
            // write back to reg file
            if(isValid(eInst.dst)) begin
                rf.wr(fromMaybe(?, eInst.dst), eInst.data);
            end
            // CSR write for sending data to host & stats
            csrf.wr(eInst.iType == Csrw ? eInst.csr : Invalid, eInst.data);

            //if(dInst.iType==J || dInst.iType == Jr || dInst.iType == Br) begin    //NOTE:  因为在btb.update的时候，进行了判断，只有非+4的预测才会进行更新，因此这里不用进行区分，看后续的需要再做修改
            //    execRedirect.enq(Redirect{pc:pc, nextPc:eInst.addr, brType:eInst.iType, taken:eInst.brTaken, mispredict:eInst.mispredict});
            //end
            if(eInst.mispredict) begin
                //btb.update(x.pc, eInst.addr);   //如果在这里更新，doExecute rule和doFetchDecode rule会发生冲突导致非分支的IPC也为0.5, 冲突的原因？//TODO:  再编译一次看看
                //execRedirect.enq(Redirect{pc:pc, nextPc:eInst.addr, brType:eInst.iType, taken:eInst.brTaken, mispredict:eInst.mispredict});      //FIXME:  pc值写错了
                execRedirect.enq(Redirect{pc:x.pc, nextPc:eInst.addr, brType:eInst.iType, taken:eInst.brTaken, mispredict:eInst.mispredict});
                eEpoch <= !eEpoch;
            end
        end
        f2d.deq;
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

    interface iMemInit = iMem.init;
    interface dMemInit = dMem.init;
endmodule