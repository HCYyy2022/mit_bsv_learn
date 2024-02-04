import CacheTypes::*;
import Vector::*;
import MyFifo::*;
import Types::*;
import MemTypes::*;
import MemUtil::*;

//1 参考myrfy001的实现
//2 感觉当core多的时候，原来findChildToDowngrade和checkAllChildCompatibleWithUpgradeReq可能成为关键时序路径, 因此实现中新增加一个FindPassiveDownCore状态，提前提取出所有需要downgrade的core
//3 waitRespFlag信息从每个core每个line缩减为每个core
//4 多引入的FindPassiveDownCore状态可以优化时序，但是会降低性能，考虑到大多数访存都是在Cache中，因此PPP中多一拍处理带来的性能损失可能不大
//5 当core数较少的时候，可以使用之前的版本，后续考虑参数化的硬件生成，根据coreNum选择哪个版本的PPP实现

typedef struct {
    CacheTag tag;
    MSI msi;
} CacheLineInfo deriving(Bits, FShow);

typedef enum {
    FindPassiveDownCore,
    SendPassiveDowngradeReq,
    WaitAllDowngradeResp,
    WaitMemResp
} UpgradeReqHandleStep deriving(Bits, Eq, FShow);

module mkPPP(MessageGet c2m, MessagePut m2c, WideMem mem, Empty ifc);

    Bool  needDebugPrint = False;
    Fmt   printPrefix = $format("[ppp debug]");

    Vector#(CoreNum, Vector#(CacheRows, Reg#(CacheLineInfo))) cli <- replicateM( replicateM(mkReg(CacheLineInfo{msi: I, tag:?})));

    Reg#(Bit#(32))             cycle        <- mkReg(0);
    Reg#(Bit#(CoreNum))        bitMapReg    <- mkRegU();
    Reg#(Bit#(CoreNum))        waitRespFlag <- mkRegU();
    Reg#(CacheMemReq)          upReqReg     <- mkRegU();
    Reg#(UpgradeReqHandleStep) upReqStep    <- mkReg(FindPassiveDownCore);


//===================================================================//
//function
//===================================================================//
    function Action  debugInfoPrint(Bool needPrint,Fmt prefix, Fmt info);
        return action
            if(needPrint) $display(prefix + info);
        endaction;
    endfunction

    function Addr address( CacheTag tag, CacheIndex index, CacheWordSelect sel );
        return {tag, index, sel, 0};
    endfunction

    function Bool isCompatible(MSI cur, MSI next);
        return !((cur==M && next==M) || (cur==M && next==S) || (cur==S && next==M));
    endfunction

    function Bool isInDirectory(CoreID coreID, Addr addr);
        CacheTag   tag     = getTag(addr);
        CacheIndex lineIdx = getIndex(addr);
        return cli[coreID][lineIdx].tag == tag;
    endfunction

    //============================================================================//
    //findAllNeedPassiveDownCore
    //============================================================================//
    function Bit#(CoreNum) findAllNeedPassiveDownCore(CacheMemReq upReq);
        Bit#(CoreNum)  needDownCoreBitMap = 0;
        let  lineIdx = getIndex(upReq.addr);
        for (Integer coreId=0; coreId<valueOf(CoreNum); coreId=coreId+1) begin
            if (fromInteger(coreId) != upReq.child) begin
                let  inDirectory = isInDirectory(fromInteger(coreId), upReq.addr);
                let  lineInfo    = cli[coreId][lineIdx];
                let  compatible  = isCompatible(lineInfo.msi, upReq.state);
                if( inDirectory && !compatible) 
                    needDownCoreBitMap[coreId] = 1;
            end
        end
        return needDownCoreBitMap;
    endfunction

    //============================================================================//
    //priorityBaseArbiter
    //============================================================================//
    function Maybe#(Tuple2#(Bit#(TLog#(CoreNum)), Bit#(CoreNum))) priorityBaseArbiter(Bit#(CoreNum) lastBitMap);  //直接使用CoreID宏定义
        Bit#(CoreNum)        rst        = 0;
        Bit#(CoreNum)        nextBitMap = 0;
        Bit#(TLog#(CoreNum)) idx = 0;
        for (Integer i=valueOf(CoreNum)-1; i>=0; i=i-1) begin
            if(lastBitMap[i] == 1) begin
                idx    = fromInteger(i);
                rst    = 0;
                rst[i] = 1;
            end
        end
        if(rst == 0) 
            return tagged Invalid;
        else begin
            nextBitMap = lastBitMap & (~rst);
            return tagged Valid tuple2(idx, nextBitMap);
        end
    endfunction

//===================================================================//
//rule
//===================================================================//
    rule doFindPassiveDownCore(c2m.hasReq &&& c2m.first matches tagged Req .upReq &&& upReqStep == FindPassiveDownCore);   //寻找所有需要被动降级的core
        let bitMap = findAllNeedPassiveDownCore(upReq);
        debugInfoPrint(needDebugPrint, printPrefix, $format(" [FindPassiveDownCore], bitMap: %b, upReq: ", bitMap, fshow(upReq) ) );
        bitMapReg     <= bitMap;
        waitRespFlag  <= bitMap;
        upReqReg      <= upReq;
        upReqStep     <= SendPassiveDowngradeReq;
    endrule

    rule doSendPassiveDowngradeReq(c2m.hasReq &&& c2m.first matches tagged Req .upReq &&& upReqStep == SendPassiveDowngradeReq);   //发送被动降级req
        let lineIdx = getIndex(upReq.addr);
        let upTag   = getTag  (upReq.addr);
        let info    = cli[upReq.child][lineIdx];

        let findCoreIdx = priorityBaseArbiter(bitMapReg);
        debugInfoPrint(needDebugPrint, printPrefix, $format(" [SendPassiveDowngradeReq], bitMap: %b: ", bitMapReg ) );


        if(isValid(findCoreIdx)) begin
            match {.coreIdx, .nextBitMap } = fromMaybe(?, findCoreIdx);

            let passiveDownReqToSend = CacheMemReq { child: coreIdx, addr: upReq.addr, state: upReq.state == M ? I : S };
            m2c.enq_req(passiveDownReqToSend);

            bitMapReg  <= nextBitMap;
            debugInfoPrint(needDebugPrint, printPrefix, $format(" [SendPassiveDowngradeReq] send one passive down req: ", fshow(passiveDownReqToSend) ) );
            debugInfoPrint(needDebugPrint, printPrefix, $format(" [SendPassiveDowngradeReq] nextBitMap: ",nextBitMap ) );
        end
        else begin
            upReqStep <= WaitAllDowngradeResp;
            debugInfoPrint(needDebugPrint, printPrefix, $format(" [SendPassiveDowngradeReq] no further passive req need to sent,go to next state " ) );
        end
    endrule

    (* descending_urgency = "doHandleDowngradeResp, doWaitAllDowngradeResp" *)
    rule doWaitAllDowngradeResp(c2m.hasReq &&& c2m.first matches tagged Req .upReq &&& upReqStep == WaitAllDowngradeResp);   //处理主动升级的req,必要时需要读mem
        let lineIdx  = getIndex(upReq.addr);
        let tag      = getTag  (upReq.addr);
        let info     = cli[upReq.child][lineIdx];
        

        let isAllRespCmpl = (waitRespFlag == 0);

        if(isAllRespCmpl) begin
            if(upReq.state == M && info.msi == S) begin   //S up to M, not neet to opreate mem
                debugInfoPrint(needDebugPrint, printPrefix, $format(" [WaitAllDowngradeResp] S up to M, not need to opreate mem, , send up_req resp"  ) );
                c2m.deq;
                let upReqResp = CacheMemResp{child:upReq.child, addr:upReq.addr, state:upReq.state, data: tagged Invalid};
                m2c.enq_resp(upReqResp);
                info.msi                  = upReq.state;
                info.tag                  = tag;
                cli[upReq.child][lineIdx] <= info;
                upReqStep <= FindPassiveDownCore;
            end
            else begin
                debugInfoPrint(needDebugPrint, printPrefix, $format(" [WaitAllDowngradeResp]not S up to M,  need to opreate mem, send mem_read_req"  ) );
                mem.req(WideMemReq{write_en: 0, addr: address(tag, lineIdx, 0), data: ?});
                upReqStep <= WaitMemResp;
            end
        end
    endrule

    (* descending_urgency = "doHandleDowngradeResp, doWaitMemResp" *)
    rule doWaitMemResp(mem.respValid && upReqStep == WaitMemResp && c2m.hasReq &&& c2m.first matches tagged Req .upReq);  
        c2m.deq;
        let lineIdx  = getIndex(upReq.addr);
        let info     = cli[upReq.child][lineIdx];
        
        let memData <- mem.resp;
        m2c.enq_resp(CacheMemResp{
            child: upReq.child,
            addr : upReq.addr ,
            state: upReq.state,
            data: tagged Valid memData
        });

        info.tag                  = getTag(upReq.addr);
        info.msi                  = upReq.state;
        cli[upReq.child][lineIdx] <= info;
        upReqStep <= FindPassiveDownCore;
        debugInfoPrint(needDebugPrint, printPrefix, $format(" [WaitMemResp]mem read return, send up_req resp"  ) );
    endrule


    rule doHandleDowngradeResp(c2m.hasResp &&& c2m.first matches tagged Resp .downResp);
        c2m.deq;

        let tag     = getTag  (downResp.addr);
        let lineIdx = getIndex(downResp.addr);
        let info    = cli[downResp.child][lineIdx];

        let upTag     = getTag  (upReqReg.addr);
        let upLineIdx = getIndex(upReqReg.addr);
        let upInfo    = cli[upReqReg.child][lineIdx];


        if(upTag == tag && lineIdx == upLineIdx) begin
            debugInfoPrint(needDebugPrint, printPrefix, $format(" [doHandleDowngradeResp] resp is match upReq " ) );
            waitRespFlag[downResp.child]  <= 0;
        end
        else begin
            debugInfoPrint(needDebugPrint, printPrefix, $format(" [doHandleDowngradeResp] resp is not match upReq " ) );
        end

        info.msi              = downResp.state;
        info.tag              = tag;
        if (downResp.data matches tagged Valid .d) 
            mem.req(WideMemReq{write_en: '1, addr: address(tag, lineIdx, 0), data: d});

        cli[downResp.child][lineIdx] <= info;
    endrule

    rule doIncCycle;
        //$display("cycle %d  time %0t =============================================", cycle, $time);
        cycle <= cycle + 1;
    endrule
endmodule




