import CacheTypes::*;
import Vector::*;
import FShow::*;
import MemTypes::*;
import Types::*;
import ProcTypes::*;
import MyFifo::*;
import Ehr::*;
import RefTypes::*;
import StQ::*;


typedef enum{Ready, ActiveDowngrade, ActiveUpgrade, WaitUpgradeResp} CacheStatus deriving(Eq, Bits);

//stq 可以使得load指令绕过前面的store指令执行，提升效率
//为了保证Sc的顺序性, Sc指令不存入stq,并且在执行Sc的时候，stq必须是空的(指令的顺序是Lr0，Sc0，Lr1, Sc1,如果Sc存入stq，则会导致Lr1,在Sc0之前执行,导致错误的linkAddr设置)
//为了保证Lr的顺序性，Lr指令在执行的时候，stq必须是空的

module mkDCacheStQ#(CoreID id)(MessageGet fromMem, MessagePut toMem, RefDMem refDMem, DCache ifc);
    Reg#(CacheStatus)                        cacheState   <- mkReg(Ready);
    Vector#(CacheRows, Reg#(CacheLine))      dataArray    <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(CacheTag))       tagArray     <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(MSI))            msiArray     <- replicateM(mkReg(I));

    Reg#(Maybe#(CacheLineAddr)) linkAddr <- mkReg(Invalid);
    Reg#(MemReq) missReq                 <- mkRegU;

    Fifo#(2, MemReq )    reqQ  <- mkBypassFifo;
    Fifo#(2, MemResp)    respQ <- mkBypassFifo;
    StQ#(StQSize) stq <-mkStQ;
    
    Bool  needDebugPrint = True;
    Fmt   prefix = $format("[mkDCacheStQ(%2d) debug]", id);

    function Action  debugInfoPrint(Bool needPrint,Fmt prefix, Fmt info);
        return action
            if(needPrint) $display(prefix + info);
        endaction;
    endfunction

    function Addr address( CacheTag tag, CacheIndex index, CacheWordSelect sel );
        return {tag, index, sel, 0};
    endfunction
    
    rule doProcSt(reqQ.first.op == St);
        let r = reqQ.first;
        reqQ.deq;
        stq.enq(r);
    endrule
    
    rule doProcSc(cacheState == Ready && reqQ.first.op == Sc && !stq.notEmpty);
        reqQ.deq;
        let r    = reqQ.first;
        let sel  = getWordSelect(r.addr);
        let idx  = getIndex     (r.addr);
        let tag  = getTag       (r.addr);
        let hit  = (tagArray[idx] == tag);
        missReq  <= r;
        let isScFail =   (!isValid(linkAddr) || getLineAddr(r.addr) != fromMaybe(?, linkAddr)) ;
        debugInfoPrint(needDebugPrint, prefix, $format(" [doProcSc]: msi= %1d, curReq=", msiArray[idx] ,fshow(r)));
        if(hit) begin
            if(isScFail) begin
                respQ.enq(scFail);
                refDMem.commit(r, tagged Valid dataArray[idx], tagged Valid scFail);
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcSc]:Sc op, hit, isScFail"));
                linkAddr <= tagged Invalid;
            end
            else begin
                if (msiArray[idx] == M) begin
                    let oldLine    = dataArray[idx];
                    oldLine  [sel]   = r.data;
                    dataArray[idx]  <= oldLine;
                    
                    respQ.enq(scSucc);
                    refDMem.commit(r, tagged Valid dataArray[idx], tagged Valid scSucc);
                    debugInfoPrint(needDebugPrint, prefix, $format(" [doProcSc]:Sc op, hit, isScSucc"));
                    linkAddr <= tagged Invalid;
                end
                else begin 
                    cacheState <= ActiveUpgrade;
                    debugInfoPrint(needDebugPrint, prefix, $format(" [doProcSc]:sc_hit_not_in_M, will do ActiveUpgrade, msi=", fshow(msiArray[idx])) );
                end
            end
        end
        else begin   //not hit
            if(isScFail) begin
                respQ.enq(scFail);
                refDMem.commit(r, tagged Valid dataArray[idx], tagged Valid scFail);
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcSc]:Sc op(not hit), isScFail"));
                linkAddr <= tagged Invalid;
            end
            else begin
                if(msiArray[idx] == I) begin
                    cacheState <= ActiveUpgrade  ;
                    debugInfoPrint(needDebugPrint, prefix, $format(" [doProcSc]:req not hit and mis is I, will do ActiveUpgrade"));
                end
                else begin 
                    cacheState <= ActiveDowngrade;
                    debugInfoPrint(needDebugPrint, prefix, $format(" [doProcSc]:req not hit and mis is not I, will do ActiveDowngrade, msi=", fshow(msiArray[idx])) );
                end
            end
        end
    endrule

    rule doProcFence (cacheState == Ready && reqQ.first.op == Fence && !stq.notEmpty);   //TODO:
        debugInfoPrint(needDebugPrint, prefix, $format(" [doProcFence]" ));
        reqQ.deq;
        refDMem.commit(reqQ.first, Invalid, Invalid);
    endrule

    rule doProcLoad (cacheState == Ready && (reqQ.first.op == Ld || (reqQ.first.op == Lr && !stq.notEmpty) ) );   //处理Lr指令的时候，需要确保之前的store指令都被处理完了
        reqQ.deq;
        let r    = reqQ.first;
        let sel  = getWordSelect(r.addr);
        let idx  = getIndex     (r.addr);
        let tag  = getTag       (r.addr);
        let hit  = (tagArray[idx] == tag);
        missReq  <= r;
        debugInfoPrint(needDebugPrint, prefix, $format(" [doProcLoad]: msi= %1d, curReq=", msiArray[idx] ,fshow(r)));
        
        if(r.op == Ld &&& stq.search(r.addr) matches tagged Valid .stqRes) begin
            debugInfoPrint(needDebugPrint, prefix, $format(" [doProcLoad][ld_after_st], stqRes: %8h",stqRes));
            refDMem.commit(r, tagged Invalid, tagged Valid stqRes);
            respQ.enq(stqRes);
        end

        else if(hit) begin
            if (msiArray[idx] > I) begin
                respQ.enq(dataArray[idx][sel]);
                refDMem.commit(r, tagged Valid dataArray[idx], tagged Valid dataArray[idx][sel]);
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcLoad][Load_hit], resp_data=%8h, msi=",dataArray[idx][sel] ,fshow(msiArray[idx])));
            end
            else begin
                cacheState <= ActiveUpgrade;
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcLoad]:Load_hit_in_I (not hit, will do ActiveUpgrade)"));
            end
            if(r.op == Lr) begin
                linkAddr <= tagged Valid getLineAddr(r.addr);
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcLoad]:Lr op, set linkAddr"));
            end
        end
        else begin   //not hit
            if(msiArray[idx] == I) begin
                cacheState <= ActiveUpgrade  ;
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcLoad]:req not hit and mis is I, will do ActiveUpgrade"));
            end
            else begin 
                cacheState <= ActiveDowngrade;
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcLoad]:req not hit and mis is not I, will do ActiveDowngrade, msi=", fshow(msiArray[idx])) );
            end
        end
    endrule
    
    rule doProcStq(cacheState == Ready && !stq.isIssued && ((reqQ.notEmpty && reqQ.first.op != Ld) || !reqQ.notEmpty));
        let r    <- stq.issue;
        let sel  = getWordSelect(r.addr);
        let idx  = getIndex     (r.addr);
        let tag  = getTag       (r.addr);
        let hit  = (tagArray[idx] == tag);
        missReq  <= r;
        debugInfoPrint(needDebugPrint, prefix, $format(" [doProcStq]: msi= %1d, curReq=", msiArray[idx] ,fshow(r)));
        if(hit) begin
            if (msiArray[idx] == M) begin
                let oldLine    = dataArray[idx];
                oldLine  [sel]   = r.data;
                dataArray[idx]  <= oldLine;
                
                refDMem.commit(r, tagged Valid dataArray[idx], tagged Invalid);
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcStq]:st_hit_in_M, oldLine=%x, newLine=%x ",dataArray[idx], oldLine));
                stq.deq;
            end
            else begin 
                cacheState <= ActiveUpgrade;
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcStq]:st_hit_not_in_M, will do ActiveUpgrade, msi=", fshow(msiArray[idx])) );
            end
        end
        else begin   //not hit
            if(msiArray[idx] == I) begin
                cacheState <= ActiveUpgrade  ;
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcStq]:req not hit and mis is I, will do ActiveUpgrade"));
            end
            else begin 
                cacheState <= ActiveDowngrade;
                debugInfoPrint(needDebugPrint, prefix, $format(" [doProcStq]:req not hit and mis is not I, will do ActiveDowngrade, msi=", fshow(msiArray[idx])) );
            end
        end
    endrule

        
    rule doActiveDowngrade(cacheState == ActiveDowngrade);  //当发生为不命中且不在I状态的时候，需要先进行主动降级
        let sel  = getWordSelect(missReq.addr);
        let idx  = getIndex     (missReq.addr);
        let tag  = getTag       (missReq.addr);

        let curTag = tagArray[idx];

        Addr oldAddr = address(curTag, idx, sel);      //NOTE: 这里的sel是不正确的，不过后级只需要tag和idx，不关心sel
        let data = msiArray[idx] == M ? tagged Valid dataArray[idx] : tagged Invalid;
        let  toMemResp = CacheMemResp{child: id, addr: oldAddr, state: I, data: data};
        toMem.enq_resp(toMemResp);
        msiArray[idx] <= I;

        cacheState <= ActiveUpgrade;
        debugInfoPrint(needDebugPrint, prefix, $format(" [doActiveDowngrade]: old_msi=%1d, toMemResp=",msiArray[idx], fshow(toMemResp)));

        if (isValid(linkAddr) && fromMaybe(?, linkAddr)==getLineAddr(missReq.addr)) begin
            linkAddr <= tagged Invalid;
            debugInfoPrint(needDebugPrint, prefix, $format(" [doActiveDowngrade]:  linkAddr is Valid, set Invalid") );
        end
    endrule

    rule doActiveUpgrade(cacheState == ActiveUpgrade);
        let toMemReq = CacheMemReq{child: id, addr: missReq.addr, state: (missReq.op == St || missReq.op == Sc) ? M : S};
        toMem.enq_req(toMemReq);
        cacheState <= WaitUpgradeResp;
        debugInfoPrint(needDebugPrint, prefix, $format(" [doActiveUpgrade]: toMemReq=",fshow(toMemReq)));
    endrule

    rule doWaitUpgradeResp(cacheState == WaitUpgradeResp && fromMem.hasResp);
        fromMem.deq;
        let resp    = fromMem.first.Resp;
        let sel     = getWordSelect(missReq.addr);
        let idx     = getIndex     (missReq.addr);
        let tag     = getTag       (missReq.addr);
        let newLine = isValid(resp.data) ? fromMaybe(?, resp.data) : dataArray[idx];

        if (missReq.op == Ld || missReq.op ==Lr)  begin
            respQ.enq(newLine[sel]);
            refDMem.commit(missReq, tagged Valid newLine, tagged Valid newLine[sel]);
            if(missReq.op ==Lr) begin
                linkAddr <= tagged Valid getLineAddr(missReq.addr);
            end
        end
        else if (missReq.op == St)  begin
            refDMem.commit(missReq, tagged Valid newLine, tagged Invalid);
            stq.deq;
            newLine[sel] = missReq.data;
        end
        else if (missReq.op == Sc)  begin
            if (isValid(linkAddr) && fromMaybe(?, linkAddr) == getLineAddr(missReq.addr)) begin
                refDMem.commit(missReq, tagged Valid newLine, tagged Valid scSucc);
                respQ.enq(scSucc);
                newLine[sel] = missReq.data;
            end else begin   //NOTE:  理论上是不会进入这个状态的
                refDMem.commit(missReq, tagged Valid newLine, tagged Valid scFail);
                respQ.enq(scFail);
            end
            linkAddr <= tagged Invalid;
        end
        dataArray[idx] <= newLine   ;
        tagArray [idx] <= tag       ;
        msiArray [idx] <= resp.state;
        cacheState <= Ready;
        debugInfoPrint(needDebugPrint, prefix, $format(" [WaitUpgradeResp]: fromMemResp=",fshow(resp)));
    endrule
    
    rule doPassiveDowngrade(fromMem.hasReq);    //被动降级
        fromMem.deq;
        let req    = fromMem.first.Req;
        let idx    = getIndex(req.addr);
        let tag    = getTag  (req.addr);

        let curTag = tagArray[idx];
        let msi    = msiArray[idx];
        debugInfoPrint(needDebugPrint, prefix, $format(" [doPassiveDowngrade]: oriMsi=%1d, fromMemReq=",msi ,fshow(req)));

        if ( (msi > req.state) && (tag == curTag) ) begin
            let data = msi == M ? tagged Valid dataArray[idx] : tagged Invalid;
            let toMemResp = CacheMemResp{child: id, addr: req.addr, state: req.state, data: data};
            toMem.enq_resp(toMemResp);
            msiArray[idx] <= req.state;
            debugInfoPrint(needDebugPrint, prefix, $format(" [doPassiveDowngrade]: msi > req.state, need downgrade, toMemResp=", fshow(toMemResp)) );
            if (isValid(linkAddr) && fromMaybe(?, linkAddr)==getLineAddr(req.addr)) begin
                linkAddr <= tagged Invalid;
                debugInfoPrint(needDebugPrint, prefix, $format(" [doPassiveDowngrade]: msi > req.state, linkAddr is Valid, set Invalid") );
            end
        end
    endrule

    method Action req(MemReq r);
        reqQ.enq(r);
        refDMem.issue(r);
    endmethod


    method ActionValue#(MemResp) resp;
        respQ.deq;
        return respQ.first;
    endmethod

endmodule

