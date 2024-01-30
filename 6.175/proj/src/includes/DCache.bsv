import CacheTypes::*;
import Vector::*;
import MyFifo::*;
import Types::*;
import RefTypes::*;
import MemTypes::*;


typedef enum{Ready, ActiveDowngrade, ActiveUpgrade, WaitUpgradeResp} CacheStatus deriving(Eq, Bits);
//Ready           :  处于Ready才能接收core的 req
//ActiveDowngrade :  当未命中且line不处于I状态的时候，需要先主动降级（事件通知， 数据回写）
//ActiveUpgrade   :  未命中降级之后需要升级;  命中但是当前级别不够也需要主动升级(事件通知，读出数据)
//WaitUpgradeResp :  当发送主动升级命令之后，需要等待响应

//doPassiveDowngrade rule不在状态机中，并且和doWaitUpgradeResp rule互斥



module mkDCache#(CoreID id)(MessageGet fromMem, MessagePut toMem, RefDMem refDMem, DCache ifc);
    Reg#(CacheStatus)                        cacheState   <- mkReg(Ready);
    Vector#(CacheRows, Reg#(CacheLine))      dataArray    <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(CacheTag))       tagArray     <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(MSI))            msiArray     <- replicateM(mkReg(I));
    Reg#(MemReq) missReq <- mkRegU;

    Fifo#(2, MemReq )    reqQ  <- mkPipelineFifo;
    Fifo#(2, MemResp)    respQ <- mkBypassFifo  ;
    
    Bool  needDebugPrint = False;
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
        debugInfoPrint(needDebugPrint, prefix, $format(" [doReq rule], hit: %1d, msiState: ", hit, fshow(msiArray[idx])) );
        if(hit) begin
            if (r.op == Ld) begin
                if (msiArray[idx] > I) begin
                    respQ.enq(dataArray[idx][sel]);
                    //$display("[DCache debug] - ld op is hit and msi is in %2d, return data resp", msiArray[idx]);
                end
                else 
                    cacheState <= ActiveUpgrade;
            end
            else if(r.op == St) begin
                if (msiArray[idx] == M) begin
                    let oldLine    = dataArray[idx];
                    oldLine  [sel]   = r.data;
                    dataArray[idx]  <= oldLine;
                end
                else 
                    cacheState <= ActiveUpgrade;
            end
            else begin 
                $fwrite(stderr, "ERROR : current cache only support ld and st op\n");
                $finish;
            end
        end
        else begin
            if(msiArray[idx] == I)
                cacheState <= ActiveUpgrade  ;
            else 
                cacheState <= ActiveDowngrade;
        end
    endrule
        
    rule doActiveDowngrade(cacheState == ActiveDowngrade);  //当发生为命中且不在I状态的时候，需要先进行主动降级
        let sel  = getWordSelect(missReq.addr);
        let idx  = getIndex     (missReq.addr);
        let tag  = getTag       (missReq.addr);

        let curTag = tagArray[idx];

        Addr oldAddr = address(curTag, idx, sel);      //NOTE: 这里的sel是不正确的，不过后级只需要tag和idx，不关心sel
        let data = msiArray[idx] == M ? tagged Valid dataArray[idx] : tagged Invalid;
        toMem.enq_resp(CacheMemResp{child: id, addr: oldAddr, state: I, data: data});
        msiArray[idx] <= I;

        cacheState <= ActiveUpgrade;
    endrule

    rule doActiveUpgrade(cacheState == ActiveUpgrade);
        toMem.enq_req(CacheMemReq{child: id, addr: missReq.addr, state: missReq.op == St ? M : S});
        cacheState <= WaitUpgradeResp;
    endrule

    rule doWaitUpgradeResp(cacheState == WaitUpgradeResp && fromMem.hasResp);
        fromMem.deq;
        let resp    = fromMem.first.Resp;
        let sel     = getWordSelect(missReq.addr);
        let idx     = getIndex     (missReq.addr);
        let tag     = getTag       (missReq.addr);
        let newLine = isValid(resp.data) ? fromMaybe(?, resp.data) : dataArray[idx];

        if (missReq.op == Ld) 
            respQ.enq(newLine[sel]);
        else if (missReq.op == St) 
            newLine[sel] = missReq.data;
        dataArray[idx] <= newLine   ;
        tagArray [idx] <= tag       ;
        msiArray [idx] <= resp.state;
        cacheState <= Ready;
    endrule
    
    rule doPassiveDowngrade(fromMem.hasReq);    //被动降级
        fromMem.deq;
        let req = fromMem.first.Req;
        let idx    = getIndex(req.addr);
        let tag    = getTag  (req.addr);

        let curTag = tagArray[idx];
        let msi    = msiArray[idx];

        if ( (msi > req.state) && (tag == curTag) ) begin
            let data = msi == M ? tagged Valid dataArray[idx] : tagged Invalid;
            toMem.enq_resp(CacheMemResp{child: id, addr: req.addr, state: req.state, data: data});
            msiArray[idx] <= req.state;
        end
    endrule

    method Action req(MemReq r);
        reqQ.enq(r);
        //refDMem.issue(r);
    endmethod


    method ActionValue#(MemResp) resp;
        respQ.deq;
        return respQ.first;
    endmethod

endmodule