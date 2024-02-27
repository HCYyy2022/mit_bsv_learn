import Types::*;
import ProcTypes::*;
import MemTypes::*;
import RFile::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import MyFifo::*;
import Ehr::*;
import GetPut::*;
import ICache::*;
import DCache::*;
import DCacheStQ::*;
import DCacheLHUSM::*;
import MemReqIDGen::*;
import CacheTypes::*;
import MemUtil::*;
import Vector::*;
import FShow::*;
import MessageFifo::*;
import RefTypes::*;


typedef enum {
    Fetch,
    Execute,
    Commit
} Stage deriving(Bits, Eq, FShow);

module mkCore#(CoreID id)(
    WideMem iMem,
    RefDMem refDMem,
    Core ifc
);

    Bool  needDebugPrint = True;
    Fmt   printPrefix = $format("[ThreeCycle(core%2d) debug]", id);

    Reg#(Addr)               pc <- mkRegU;
    CsrFile                csrf <- mkCsrFile(id);
    RFile                    rf <- mkRFile;
    Reg#(ExecInst)          e2c <- mkRegU;
    Reg#(Stage)           stage <- mkReg(Fetch);
    MemReqIDGen     memReqIDGen <- mkMemReqIDGen;
    ICache               iCache <- mkICache(iMem);
    MessageFifo#(8)   toParentQ <- mkMessageFifo;
    MessageFifo#(8) fromParentQ <- mkMessageFifo;
    DCache               dCache <- mkDCacheLHUSM(id, toMessageGet(fromParentQ), toMessagePut(toParentQ), refDMem);

    //===================================================================//
    //function
    //===================================================================//
    function Action  debugInfoPrint(Bool needPrint,Fmt prefix, Fmt info);
        return action
            if(needPrint) $display(prefix + info);
        endaction;
    endfunction

    rule doFetch if (csrf.started && stage == Fetch);
        iCache.req(pc);
        stage <= Execute;
        debugInfoPrint(needDebugPrint, printPrefix, $format(" [doFetch], pc=%x ", pc ) );
    endrule

    rule doExecute if (csrf.started && stage == Execute);
        let   inst <- iCache.resp;
        let  dInst = decode(inst);
        debugInfoPrint(needDebugPrint, printPrefix, $format(" [doExecute-decode], pc=%x, inst=: ", pc, showInst(inst) ) );

        let  rVal1 = rf.rd1(validValue(dInst.src1));
        let  rVal2 = rf.rd2(validValue(dInst.src2));
        let csrVal = csrf.rd(validValue(dInst.csr));
        debugInfoPrint(needDebugPrint, printPrefix, $format(" [doExecute-regFetch], pc=%x, src1=%x, src2=%x ", pc, rVal1, rVal2 ) );

        let  eInst = exec(dInst, rVal1, rVal2, pc, ?, csrVal);
        if (eInst.iType == Unsupported) begin
            $fwrite(stderr, "ERROR: Executing unsupported instruction. Exiting\n");
            $finish;
        end
        debugInfoPrint(needDebugPrint, printPrefix, $format(" [doExecute-excute], pc=%x, eInst= ", pc, fshow(eInst)) );

        case (eInst.iType)
            Ld: begin
                let rid <- memReqIDGen.getID;   //rid不是core id,只是给每条访存命令打上标签，用于调试
                let req = MemReq { op: Ld, addr: eInst.addr, data: ?, rid: rid };
                dCache.req(req);
                debugInfoPrint(needDebugPrint, printPrefix, $format(" [doExecute-memory][Ld op], rid=%x, req= ", rid, fshow(req)) );
            end
            St: begin
                let rid <- memReqIDGen.getID;
                let req = MemReq { op: St, addr: eInst.addr, data: eInst.data, rid: rid };
                dCache.req(req);
                debugInfoPrint(needDebugPrint, printPrefix, $format(" [doExecute-memory][St op], rid=%x, req= ", rid, fshow(req)) );
            end
            Lr: begin
                let rid <- memReqIDGen.getID;
                let req = MemReq { op: Lr, addr: eInst.addr, data: ?, rid: rid };
                dCache.req(req);
                debugInfoPrint(needDebugPrint, printPrefix, $format(" [doExecute-memory][Lr op], rid=%x, req= ", rid, fshow(req)) );
            end
            Sc: begin
                let rid <- memReqIDGen.getID;
                let req = MemReq { op: Sc, addr: eInst.addr, data: eInst.data, rid: rid };
                dCache.req(req);
                debugInfoPrint(needDebugPrint, printPrefix, $format(" [doExecute-memory][Sc op], rid=%x, req= ", rid, fshow(req)) );
            end
            Fence: begin
                let rid <- memReqIDGen.getID;
                let req = MemReq { op: Fence, addr: ?, data: ?, rid: rid };
                dCache.req(req);
                debugInfoPrint(needDebugPrint, printPrefix, $format(" [doExecute-memory][Fence op], rid=%x, req= ", rid, fshow(req)) );
            end
            default: begin
            end
        endcase
        e2c   <= eInst;
        stage <= Commit;
    endrule

    rule doCommit if (csrf.started && stage == Commit);
        let eInst = e2c;
        let willPrint = fromMaybe(?, eInst.csr) != csrMtohost || (fromMaybe(?, eInst.csr) == csrMtohost && id == 0);
        debugInfoPrint(needDebugPrint, printPrefix, $format(" [doCommit-writeBack], willPrint:%x, eInst:  ",willPrint, fshow(eInst)) );
        if (eInst.iType == Ld || eInst.iType == Lr || eInst.iType == Sc) begin
            eInst.data <- dCache.resp;
            debugInfoPrint(needDebugPrint, printPrefix, $format(" [doCommit-writeBack][have resp], resp:%x, iType:%x  ", eInst.data, eInst.iType) );
        end
        if (isValid(eInst.dst)) begin
            rf.wr(fromMaybe(?, eInst.dst), eInst.data);
        end
        csrf.wr(eInst.iType == Csrw && willPrint ? eInst.csr : Invalid, eInst.data);
        pc    <= eInst.brTaken ? eInst.addr : pc + 4;
        stage <= Fetch;
    endrule

    interface MessageGet toParent = toMessageGet(toParentQ);
    interface MessagePut fromParent = toMessagePut(fromParentQ);

    method ActionValue#(CpuToHostData) cpuToHost if (csrf.started);
        let ret <- csrf.cpuToHost;
        return ret;
    endmethod

    method Bool cpuToHostValid = csrf.cpuToHostValid;

    method Action hostToCpu(Bit#(32) startpc) if (!csrf.started);
        csrf.start;
        pc <= startpc;
    endmethod
endmodule
