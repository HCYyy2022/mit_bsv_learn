// six stage bonus ex5

import Types::*;
import ProcTypes::*;
import CMemTypes::*;
//import MemTypes::*;
import MemInit::*;
import RFile::*;
import IMemory::*;
import DMemory::*;
import FPGAMemory::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import MyFifo::*;
import Ehr::*;
import GetPut::*;
import Btb::*;
import Bht::*;
import Scoreboard::*;


typedef struct{
    Addr pc;
    Addr ppc;
    Bool eEpoch;
    Bool dEpoch;
    Bool rEpoch;
} F2D deriving (Bits, Eq);

typedef struct {
    Addr pc;
    Addr ppc;
    Bool eEpoch;
    Bool rEpoch;
    DecodedInst dInst;
} D2R deriving (Bits, Eq);

typedef struct {
    Addr pc;
    Addr ppc;
    Bool eEpoch;
    DecodedInst dInst;
    Data rVal1;
    Data rVal2;
    Data csrVal;
} R2E deriving (Bits, Eq);

typedef struct {
    Addr pc;
    Maybe#(ExecInst) eInst;
} E2M deriving (Bits, Eq);

typedef struct {
    Addr pc;
    Maybe#(ExecInst) eInst;
} M2W deriving (Bits, Eq);

typedef struct {
    Addr pc;
    Addr nextPc;
} ExeRedirect deriving (Bits, Eq);

typedef struct {
    Addr pc;
    Addr nextPc;
} DecRedirect deriving (Bits, Eq);

typedef struct {
    Addr pc;
    Addr nextPc;
} RegRedirect deriving (Bits, Eq);

//btb只有在预测错误的时候进行训练
//bht对所有Br类型的指令进行训练
//bht预测在decode阶段，训练在excute阶段，因为大多数的情况中，循环中的跳转指令不是紧挨的,训练有几个周期的滞后也没有影响
//Jr预测放在RegFetch阶段，因为Jr的预测需要用到rVal1的值


(* synthesize *)
module mkProc(Proc);
    Ehr#(2, Addr)     pcReg      <- mkEhr(?);
    RFile             rf         <- mkRFile;
    FPGAMemory        iMem       <- mkFPGAMemory;
    FPGAMemory        dMem       <- mkFPGAMemory;
    CsrFile           csrf       <- mkCsrFile;
    Btb#(6)           btb        <- mkBtb; // 64-entry BTB
    DirectionPred#(8) bht        <- mkBHT; //256-entry BHT
    Scoreboard#(4)    sb         <- mkCFScoreboard;
    //NOTE: 和教材上的不同，这里使用的是全局的Epoch，教材上使用的是分布式的
    Reg#(Bool)        exeEpoch   <- mkReg(False); // global epoch for redirection from Execute  stage
    Reg#(Bool)        decEpoch   <- mkReg(False); // global epoch for redirection from Decode   stage
    Reg#(Bool)        regEpoch   <- mkReg(False); // global epoch for redirection from RegFetch stage

    Ehr#(2, Maybe#(ExeRedirect)) exeRedirect <- mkEhr(Invalid); //EHR for Excute redirection
    Ehr#(2, Maybe#(DecRedirect)) decRedirect <- mkEhr(Invalid); //EHR for Decode redirection
    Ehr#(2, Maybe#(RegRedirect)) regRedirect <- mkEhr(Invalid); //EHR for Decode redirection

    // FIFO between two stages
    Fifo#(2, F2D) f2dFifo <- mkCFFifo;
    Fifo#(2, D2R) d2rFifo <- mkCFFifo;
    Fifo#(2, R2E) r2eFifo <- mkCFFifo;
    Fifo#(2, E2M) e2mFifo <- mkCFFifo;   
    Fifo#(2, M2W) m2wFifo <- mkCFFifo;

    Bool memReady = iMem.init.done && dMem.init.done;
    
    rule doFetch(csrf.started);
        iMem.req(MemReq{op:Ld, addr:pcReg[0], data:?});
        let ppc = btb.predPc(pcReg[0]);
        pcReg[0] <= ppc;
        
        let f2d = F2D{pc:pcReg[0], ppc:ppc, eEpoch:exeEpoch, dEpoch:decEpoch, rEpoch:regEpoch};
        f2dFifo.enq(f2d);
        $display("[Fetch] : PC = %x", pcReg[0]);
    endrule

    rule doDecode(csrf.started);
        f2dFifo.deq;
        let f2d = f2dFifo.first;
        let inst <- iMem.resp;
        if(f2d.eEpoch != exeEpoch) begin
            $display("[Decode][Kill instruction,exeEpoch not eq]: PC = %x, inst = %x, expanded = ", f2d.pc, inst, showInst(inst));
        end
        else if(f2d.dEpoch != decEpoch) begin
            $display("[Decode][Kill instruction,decEpoch not eq]: PC = %x, inst = %x, expanded = ", f2d.pc, inst, showInst(inst));
        end
        else if(f2d.rEpoch != regEpoch) begin
            $display("[Decode][Kill instruction,regEpoch not eq]: PC = %x, inst = %x, expanded = ", f2d.pc, inst, showInst(inst));
        end
        else begin
            let dInst = decode(inst);
            let predPc = f2d.ppc;   // addrPredPc
            if(dInst.iType == Br || dInst.iType == J) begin
            //if(dInst.iType == Br) begin
                let dirPredPc  = f2d.pc + fromMaybe(?, dInst.imm);
                //let dirPredPc2 = bht.ppcDP(f2d.pc, dirPredPc); 
                let dirPredPc2 = dInst.iType == Br ? bht.ppcDP(f2d.pc, dirPredPc) : dirPredPc;  //J型指令不使用bht,因为循环中较少使用J型指令,直接使用计算结果作为预测值
                if(dirPredPc2 != predPc) begin
                    $display("[Decode][Br dir Mispredict]: PC = %x, inst = %x, expanded = ", f2d.pc, inst, showInst(inst));
                    decRedirect[0] <= tagged Valid DecRedirect{pc:f2d.pc, nextPc:dirPredPc2 };
                    predPc = dirPredPc2;  //dirPredPc2
                end
                else begin
                    $display("[Decode][Br dir right predict]: PC = %x, inst = %x, expanded = ", f2d.pc, inst, showInst(inst));
                end
            end
            else begin
                $display("[Decode][not Br Inst]: PC = %x, inst = %x, expanded = ", f2d.pc, inst, showInst(inst));
            end
            let d2r = D2R{pc:f2d.pc, ppc:predPc, eEpoch:f2d.eEpoch, rEpoch: f2d.rEpoch, dInst:dInst};
            d2rFifo.enq(d2r);
        end
    endrule
    
    rule doRegFetch(csrf.started);
        let d2r    = d2rFifo.first;
        let rVal1  = rf.rd1 (fromMaybe(?, d2r.dInst.src1));
        let rVal2  = rf.rd2 (fromMaybe(?, d2r.dInst.src2));
        let csrVal = csrf.rd(fromMaybe(?, d2r.dInst.csr));
        let dInst  = d2r.dInst;
        let predPc = d2r.ppc;
        

        if(d2r.eEpoch != exeEpoch) begin
            d2rFifo.deq;
            $display("[RegFetch][Kill instruction,exeEpoch not eq]: PC = %x ", d2r.pc);
        end
        else if(d2r.rEpoch != regEpoch) begin
            d2rFifo.deq;
            $display("[RegFetch][Kill instruction,regEpoch not eq]: PC = %x", d2r.pc);
        end
        else begin
            if(!sb.search1(d2r.dInst.src1) && !sb.search2(d2r.dInst.src2)) begin
                if(dInst.iType == Jr) begin
                    let imm  = fromMaybe(?, dInst.imm);
                    Addr jrPredPc  = {truncateLSB(rVal1 + imm), 1'b0};
                    if(jrPredPc != predPc) begin
                        $display("[RegFetch][Jr Mispredict]: PC = %x", d2r.pc);
                        regRedirect[0] <= tagged Valid RegRedirect{pc:d2r.pc, nextPc:jrPredPc };
                        predPc = jrPredPc;  //

                    end
                    else begin
                        $display("[RegFetch][Jr right predict]: PC = %x", d2r.pc);
                    end
                end
                let r2e = R2E{
                    pc     : d2r.pc    ,
                    ppc    : predPc    ,
                    eEpoch : d2r.eEpoch,
                    dInst  : d2r.dInst ,
                    rVal1  : rVal1     ,
                    rVal2  : rVal2     ,
                    csrVal : csrVal };

                d2rFifo.deq;
                r2eFifo.enq(r2e);
                sb.insert(d2r.dInst.dst);
                $display("[RegFetch]: PC = %x, insert sb = %x", d2r.pc, d2r.dInst.dst);
            end
            else begin
                $display("[RegFetch]: Stalled, PC = %x, src1 = %x, src2 = %x", d2r.pc, d2r.dInst.src1, d2r.dInst.src2);
            end
        end

        //if(!sb.search1(d2r.dInst.src1) && !sb.search2(d2r.dInst.src2)) begin
        //    d2rFifo.deq;
        //    r2eFifo.enq(r2e);
        //    sb.insert(d2r.dInst.dst);
        //    $display("[RegFetch]: PC = %x, insert sb = %x", d2r.pc, d2r.dInst.dst);
        //end
        //else begin
        //    $display("[RegFetch]: Stalled, PC = %x, src1 = %x, src2 = %x", d2r.pc, d2r.dInst.src1, d2r.dInst.src2);
        //end
    endrule

    rule doExecute(csrf.started);
        let r2e = r2eFifo.first;
        r2eFifo.deq;
        Maybe#(ExecInst) eInst2 = Invalid;
        if(r2e.eEpoch != exeEpoch) begin
            $display("[Execute]: Kill instruction, PC: %x",r2e.pc);
        end
        else begin
            let eInst = exec(r2e.dInst, r2e.rVal1, r2e.rVal2, r2e.pc, r2e.ppc, r2e.csrVal);
            eInst2 = Valid(eInst);
            if(eInst.iType == Unsupported) begin
                $fwrite(stderr, "[Execute] :ERROR, Executing unsupported instruction at pc: %x. Exiting\n", r2e.pc);
                $finish;
            end
            if(eInst.mispredict) begin 
                $display("[Execute] : finds misprediction, PC = %x", r2e.pc);
                exeRedirect[0] <= Valid (ExeRedirect { pc: r2e.pc, nextPc: eInst.addr });
            end
            else begin
                $display("[Execute] : PC = %x", r2e.pc);
            end
            
            //if(eInst.iType == Br || eInst.iType == J) begin
            if(eInst.iType == Br) begin   //所有B型指令都需要训练bht,只有在Excute阶段能拿到eInst.brTaken并对bht进行训练
                bht.update(r2e.pc, eInst.brTaken);
                $display("[Execute] Br Type inst,update bht : PC = %x", r2e.pc);
            end
        end
        let e2m = E2M{ pc:r2e.pc, eInst:eInst2 };
        e2mFifo.enq(e2m);
    endrule

    rule doMemory(csrf.started);
        e2mFifo.deq();
        let e2m = e2mFifo.first;
        if(isValid(e2m.eInst)) begin
            let eInst = fromMaybe(?, e2m.eInst);
            if(eInst.iType == Ld) begin
                dMem.req(MemReq{op: Ld, addr: eInst.addr, data: ?});
            end else if(eInst.iType == St) begin
                dMem.req(MemReq{op: St, addr: eInst.addr, data: eInst.data});
            end
            $display("[Memory] : valid eInst, PC = %x", e2m.pc);
        end
        else begin
            $display("[Memory] : Invalid eInst PC = %x", e2m.pc);
        end
        let m2w = M2W{ pc: e2m.pc, eInst:e2m.eInst };
        m2wFifo.enq(m2w);
    endrule

    rule doWriteBack(csrf.started);
        m2wFifo.deq();
        let m2w = m2wFifo.first;
        if(isValid(m2w.eInst)) begin
            let eInst = fromMaybe(?, m2w.eInst);
            if(eInst.iType == Ld) begin
                eInst.data <- dMem.resp;
            end
            if(isValid(eInst.dst)) begin
                rf.wr(fromMaybe(?, eInst.dst), eInst.data);
            end
            csrf.wr(eInst.iType == Csrw ? eInst.csr : Invalid, eInst.data);
            $display("[WriteBack] :  valid eInst, PC = %x, remove sb", m2w.pc);
        end
        else begin
            $display("[WriteBack] :  Invalid eInst, PC = %x, remove sb", m2w.pc);
        end
        sb.remove;            
    endrule

    (* fire_when_enabled *)
    (* no_implicit_conditions *)
    rule cononicalizeRedirect(csrf.started);
        if(exeRedirect[1] matches tagged Valid .r) begin  //TODO: 三者的优先级
            // fix mispred
            pcReg[1] <= r.nextPc;
            exeEpoch <= !exeEpoch;      // flip epoch
            btb.update(r.pc, r.nextPc); // train BTB
            $display("exeRedirect, redirected by Execute, oriPC: %x, truePC :%x",r.pc, r.nextPc);
        end
        else if(regRedirect[1] matches tagged Valid .r) begin  
            pcReg[1] <= r.nextPc;
            regEpoch <= !regEpoch;      // flip epoch
            btb.update(r.pc, r.nextPc); // TODO:  还需要训练吗?
            $display("exeRedirect, redirected by RegFetch, oriPC: %x, truePC :%x",r.pc, r.nextPc);
        end
        else if(decRedirect[1] matches tagged Valid .r) begin
            pcReg[1] <= r.nextPc;
            decEpoch <= !decEpoch;      // flip epoch
            btb.update(r.pc, r.nextPc); // 当btb和bht预测的结果不一致的时候，对btb也进行更新
            $display("decRedirect, redirected by Decode, oriPC: %x, truePC :%x",r.pc, r.nextPc);
        end
        // reset EHR
        exeRedirect[1] <= Invalid;
        regRedirect[1] <= Invalid;
        decRedirect[1] <= Invalid;
    endrule

    method ActionValue#(CpuToHostData) cpuToHost if(csrf.started);
        let ret <- csrf.cpuToHost;
        return ret;
    endmethod

    method Action hostToCpu(Bit#(32) startpc) if ( !csrf.started && memReady );
        $display("Start cpu");
        csrf.start(0); // only 1 core, id = 0
        pcReg[0] <= startpc;
    endmethod

    interface iMemInit = iMem.init;
    interface dMemInit = dMem.init;
endmodule