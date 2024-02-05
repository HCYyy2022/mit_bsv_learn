import CacheTypes::*;
import Vector::*;
import MyFifo::*;
import Types::*;
import RefTypes::*;
import MemTypes::*;


typedef enum{Ready, ActiveDowngrade, ActiveUpgrade, WaitUpgradeResp} CacheStatus deriving(Eq, Bits);
//Ready           :  处于Ready才能接收core的 req
//ActiveDowngrade :  当未命中且line不处于I状态的时候，需要先主动降级（事件通知， 数据回写(如果有)） ,主动降级是一个resp，不会收到ppp回复的resp
//ActiveUpgrade   :  未命中降级之后需要升级;  命中但是当前级别不够也需要主动升级(事件通知，读出数据)
//WaitUpgradeResp :  当发送主动升级命令之后，需要等待响应

//doPassiveDowngrade rule不在状态机中，并且和doWaitUpgradeResp rule互斥

//并非所有passive的降级req都会回复resp，只有降级发生的时候，会回复resp,但实际上PPP发送过来的降级req一定是判断到需要降级的



module mkDCache#(CoreID id)(MessageGet fromMem, MessagePut toMem, RefDMem refDMem, DCache ifc);
    Reg#(CacheStatus)                        cacheState   <- mkReg(Ready);
    Vector#(CacheRows, Reg#(CacheLine))      dataArray    <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(CacheTag))       tagArray     <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(MSI))            msiArray     <- replicateM(mkReg(I));
    Reg#(MemReq) missReq <- mkRegU;

    Fifo#(2, MemReq )    reqQ  <- mkPipelineFifo;
    Fifo#(2, MemResp)    respQ <- mkBypassFifo  ;
    
    Bool  needDebugPrint = True;
    Fmt   prefix = $format("[DCache(%2d) debug]", id);

    function Action  debugInfoPrint(Bool needPrint,Fmt prefix, Fmt info);
        return action
            if(needPrint) $display(prefix + info);
        endaction;
    endfunction

    function Addr address( CacheTag tag, CacheIndex index, CacheWordSelect sel );
        return {tag, index, sel, 0};
    endfunction

    rule doReq (cacheState == Ready);
        reqQ.deq;
        let r    = reqQ.first;
        let sel  = getWordSelect(r.addr);
        let idx  = getIndex     (r.addr);
        let tag  = getTag       (r.addr);
        let hit  = (tagArray[idx] == tag);
        missReq  <= r;
        
        //$display("[DCache debug] - hit: %1d, msiState: %2d", hit, msiArray[idx]);
        debugInfoPrint(needDebugPrint, prefix, $format(" [doReq_rule]: msi= %1d, curReq=", msiArray[idx] ,fshow(r)));
        if(hit) begin
            if (r.op == Ld) begin
                if (msiArray[idx] > I) begin
                    respQ.enq(dataArray[idx][sel]);
                    refDMem.commit(r, tagged Valid dataArray[idx], tagged Valid dataArray[idx][sel]);
                    debugInfoPrint(needDebugPrint, prefix, $format(" [doReq_rule][Ld_hit], resp_data=%8h, msi=",dataArray[idx][sel] ,fshow(msiArray[idx])));
                end
                else begin
                    cacheState <= ActiveUpgrade;
                    debugInfoPrint(needDebugPrint, prefix, $format(" [doReq_rule]:Ld_hit_in_I (not hit, will do ActiveUpgrade)"));
                end
            end
            else if(r.op == St) begin
                if (msiArray[idx] == M) begin
                    let oldLine    = dataArray[idx];
                    oldLine  [sel]   = r.data;
                    dataArray[idx]  <= oldLine;
                    refDMem.commit(r, tagged Valid dataArray[idx], tagged Invalid);
                    debugInfoPrint(needDebugPrint, prefix, $format(" [doReq_rule]:st_hit_in_M, oldLine=%x, newLine=%x ",dataArray[idx], oldLine));
                end
                else begin 
                    cacheState <= ActiveUpgrade;
                    debugInfoPrint(needDebugPrint, prefix, $format(" [doReq_rule]:st_hit_not_in_M, will do ActiveUpgrade, msi=", fshow(msiArray[idx])) );
                end
            end
            else begin 
                $fwrite(stderr, "ERROR : current cache only support ld and st op\n");
                $finish;
            end
        end
        else begin
            if(msiArray[idx] == I) begin
                cacheState <= ActiveUpgrade  ;
                debugInfoPrint(needDebugPrint, prefix, $format(" [doReq_rule]:req not hit and mis is I, will do ActiveUpgrade"));
            end
            else begin 
                cacheState <= ActiveDowngrade;
                debugInfoPrint(needDebugPrint, prefix, $format(" [doReq_rule]:req not hit and mis is not I, will do ActiveDowngrade, msi=", fshow(msiArray[idx])) );
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
    endrule

    rule doActiveUpgrade(cacheState == ActiveUpgrade);
        let toMemReq = CacheMemReq{child: id, addr: missReq.addr, state: missReq.op == St ? M : S};
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

        if (missReq.op == Ld)  begin
            respQ.enq(newLine[sel]);
            refDMem.commit(missReq, tagged Valid newLine, tagged Valid newLine[sel]);
        end
        else if (missReq.op == St)  begin
            refDMem.commit(missReq, tagged Valid newLine, tagged Invalid);
            newLine[sel] = missReq.data;
        end
        dataArray[idx] <= newLine   ;
        tagArray [idx] <= tag       ;
        msiArray [idx] <= resp.state;
        cacheState <= Ready;
        debugInfoPrint(needDebugPrint, prefix, $format(" [WaitUpgradeResp]: fromMemResp=",fshow(resp)));
    endrule
    
    rule doPassiveDowngrade(fromMem.hasReq);    //被动降级
        fromMem.deq;
        let req = fromMem.first.Req;
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