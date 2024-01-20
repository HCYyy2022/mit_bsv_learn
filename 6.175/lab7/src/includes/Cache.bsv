import CacheTypes::*;
import MyFifo::*;
import MemTypes::*;
import MemUtil::*;
import Vector::*;
import Types::*;
import CompletionBuffer :: * ;
import GetPut::*;


//module mkTranslator(WideMem backend, Cache ifc);
//    Fifo#(2, MemReq) originReq <- mkCFFifo();
//
//    method Action req(MemReq r);
//        originReq.enq(r);
//        backend.req(toWideMemReq(r));
//    endmethod
//
//    method ActionValue#(MemResp) resp;
//        let rsp <- backend.resp;
//        let oreq = originReq.first;
//        originReq.deq;
//
//        CacheWordSelect wordsel = truncate( oreq.addr >> 2 );
//        return rsp[wordsel];
//    endmethod
//endmodule

module mkTranslator(WideMem backend, Cache ifc);
    Fifo#(2, MemReq) originReq <- mkCFFifo();   //两个作用 （1）计算offset   （2）同步读请求req和resp，防止req overflow

    method Action req(MemReq r);
        if(r.op == Ld) originReq.enq(r);       //只有read req需要同步， write没有resp，因此不需要同步
        backend.req(toWideMemReq(r));
    endmethod

    method ActionValue#(MemResp) resp;
        let rsp <- backend.resp;             
        let oreq = originReq.first;
        originReq.deq;

        CacheWordSelect wordsel = truncate( oreq.addr >> 2 );
        return rsp[wordsel];
    endmethod
endmodule

typedef enum { Ready, StartMiss, SendFillReq, WaitFillResp } CacheStatus deriving ( Bits, Eq );

//direct-mapped, write-miss allocate, writeback, blocking
module mkCache(WideMem wideMem, Cache ifc);

    Vector#(CacheRows, Reg#(CacheLine))            dataArray  <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(Maybe#(CacheTag)))     tagArray   <- replicateM(mkReg(tagged Invalid));
    Vector#(CacheRows, Reg#(Bool))                 dirtyArray <- replicateM(mkReg(False));
    
    // Fifo#(1, Data) hitQ <- mkBypassFifo;
    Reg#(CacheStatus) status   <- mkReg(Ready);
    Fifo#(1, Data)    hitQ     <- mkPipelineFifo;
    Reg#(MemReq)      missReq  <- mkRegU;

    // Fifo#(2, MemReq) memReqQ <- mkCFFifo;
    // Fifo#(2, MemResp) memRespQ <- mkCFFifo;

    function CacheIndex      getIndex (Addr addr) = truncate(addr >> 6) ;     //CacheWordSelect(4位) + 4字节unit（2位）, log2(16*32/8) = 6
    function CacheWordSelect getOffset(Addr addr) = truncate(addr >> 2) ;     //Data是32位，4字节unit，因此右移两位, log2(32/8) = 2
    function CacheTag        getTag   (Addr addr) = truncateLSB(addr)   ;

    rule startMiss(status == StartMiss);
        let idx   = getIndex(missReq.addr);
        let tag   = tagArray[idx];
        let dirty = dirtyArray[idx];

        if (isValid(tag) && dirty) begin
            let addr = {fromMaybe(?, tag), idx, 6'b0}; 
            let data = dataArray[idx];
            wideMem.req(WideMemReq {write_en: '1, addr: addr, data: data});   //'1表示全1扩展
        end

        status <= SendFillReq;   
    endrule
    
    rule sendFillReq(status == SendFillReq);
        WideMemReq wideMemReq = toWideMemReq(missReq);
        wideMemReq.write_en = 0;
        wideMem.req(wideMemReq);

        status <= WaitFillResp;
    endrule
    
    rule waitFillResp(status == WaitFillResp);
        let idx     = getIndex (missReq.addr);
        let tag     = getTag   (missReq.addr);
        let wOffset = getOffset(missReq.addr);
        let data    <- wideMem.resp;
        tagArray[idx] <= tagged Valid tag;

        if(missReq.op == Ld) begin 
            dirtyArray[idx] <= False;
            dataArray [idx] <= data;
            hitQ.enq(data[wOffset]); 
        end else begin
            dirtyArray[idx] <= True;
            data[wOffset]  = missReq.data; 
            dataArray[idx] <= data;
        end     
        
        status <= Ready;
    endrule

    method Action req(MemReq r) if (status == Ready);
        let idx     = getIndex(r.addr); 
        let tag     = getTag(r.addr);
        let wOffset = getOffset(r.addr);
        let currTag = tagArray[idx]; 
        let hit     = isValid(currTag) ? fromMaybe(?, currTag) == tag : False;

        if ( hit ) begin
            let cacheLine = dataArray[idx];
            if ( r.op == Ld ) begin
                hitQ.enq(cacheLine[wOffset]);
            end
            else begin
                cacheLine[wOffset] = r.data;
                dataArray[idx]    <= cacheLine;
                dirtyArray[idx]   <= True;
            end
        end else begin
            missReq <= r;
            status  <= StartMiss;
        end
    endmethod
    
    method ActionValue#(Data) resp;
        hitQ.deq;
        return hitQ.first;
    endmethod
endmodule






module mkNBCache(WideMem wideMem, int id, Cache ifc);
    Vector#(CacheRows, Reg#(CacheLine))            dataArray  <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(Maybe#(CacheTag)))     tagArray   <- replicateM(mkReg(tagged Invalid));
    Vector#(CacheRows, Reg#(Bool))                 dirtyArray <- replicateM(mkReg(False));
    CompletionBuffer #(16, Data)                   cb         <- mkCompletionBuffer;
    Fifo#(8,Tuple2#(Token, MemReq))                fillQ      <- mkCFFifo;   //存放未命中的请求，打上token,进行保序

    Vector#(2, Fifo#(2, Tuple2#(Token, Data)))     completeFifos <- replicateM(mkCFFifo);

    Reg#(Bool)                                     statuReg    <- mkReg(True);
    Reg#(MemReq)                                   missReqReg  <- mkRegU;
    Reg#(Token)                                    tokenReg    <- mkRegU;

    function CacheIndex      getIndex (Addr addr) = truncate(addr >> 6) ;     //CacheWordSelect(4位) + 4字节unit（2位）, log2(16*32/8) = 6
    function CacheWordSelect getOffset(Addr addr) = truncate(addr >> 2) ;     //Data是32位，4字节unit，因此右移两位, log2(32/8) = 2
    function CacheTag        getTag   (Addr addr) = truncateLSB(addr)   ;
    

    rule notHitReqProc(statuReg == False);
        statuReg <= True;
        fillQ.enq(tuple2(tokenReg, missReqReg));  

        WideMemReq wideMemReq = toWideMemReq(missReqReg);
        wideMemReq.write_en = 0;
        wideMem.req(wideMemReq);
        $display("[notHitReqProc_rule][%0x]-process not hit req, token:%0x, op:%0x,: addr:%0x ",id , tokenReg, missReqReg.op, missReqReg.addr);
    endrule
    
    //(* descending_urgency = "doMemory, req" *)
    rule notHitRespProc;
        fillQ.deq();
        let data    <- wideMem.resp;

        match {.token, .req} = fillQ.first;
        let idx     = getIndex (req.addr); 
        let tag     = getTag   (req.addr);
        let wOffset = getOffset(req.addr);

        if(req.op == Ld) begin   //not hit read 
            dirtyArray[idx] <= False;
            dataArray [idx] <= data;
            //hitQ.enq(data[wOffset]); 
            //cb.complete.put( tuple2(token, data[wOffset]) );
            completeFifos[0].enq( tuple2(token, data[wOffset]) );
            $display("[notHitRespProc_rule][%0x]-receive not_hit_ld_resp, token:%0x, idx:%0x, tag:%0x, offset:%0x ",id, token, idx, tag, wOffset);
        end else begin          //not hit write
            dirtyArray[idx] <= True;
            data[wOffset]  = req.data; 
            dataArray[idx] <= data;
            $display("[notHitRespProc_rule][%0x]-receive not_hit_st_resp, token:%0x, idx:%0x, tag:%0x, offset:%0x ",id, token, idx, tag, wOffset);
        end     
    endrule
    
    rule completeProc;
        if(completeFifos[0].notEmpty) begin
            completeFifos[0].deq();
            let cmpl = completeFifos[0].first();
            cb.complete.put( cmpl );
            match {.token, .data}  = cmpl;
            $display("[completeProc_rule][%0x]-process not_hit_ld_cmpl, token:%0x, data:%0x ",id, token, data);
        end
        else if(completeFifos[1].notEmpty) begin
            let cmpl = completeFifos[1].first();
            cb.complete.put( cmpl );
            match {.token, .data}  = cmpl;
            $display("[completeProc_rule][%0x]-process hit_ld_cmpl, token:%0x, data:%0x ",id, token, data);
        end
    endrule
    

    method Action req(MemReq r) if(statuReg == True);
        let idx     = getIndex (r.addr); 
        let tag     = getTag   (r.addr);
        let wOffset = getOffset(r.addr);
        let dirty   = dirtyArray[idx];
        let currTag = tagArray  [idx]; 
        let hit     = isValid(currTag) ? fromMaybe(?, currTag) == tag : False;

        Token token = 0;
        if ( r.op == Ld ) begin   //hit read
            token <- cb.reserve.get;
        end
        
        if(hit) begin
            let cacheLine = dataArray[idx];
            if ( r.op == Ld ) begin   //hit read
                //hitQ.enq(cacheLine[wOffset]);
                //cb.complete.put( tuple2(token, cacheLine[wOffset]) );
                completeFifos[1].enq( tuple2(token, cacheLine[wOffset]) );
                $display("[req_method][%0x]-receive a hit_Ld req, r.addr:%0x, idx:%0x, tag:%0x, offset:%0x, token:%0x",id ,r.addr, idx, tag, wOffset, token);
            end
            else begin               //hit write
                $display("[req_method][%0x]-receive a hit_St req, r.addr:%0x, idx:%0x, tag:%0x, offset:%0x, token:%0x",id, r.addr, idx, tag, wOffset, token);
                cacheLine [wOffset] = r.data;
                dataArray [idx]    <= cacheLine;
                dirtyArray[idx]    <= True;
            end
        end
        else begin     //该状态可能需要处理脏页，因此非命中的请求在下一个状态处理
            statuReg    <= False;
            tokenReg    <= token;
            missReqReg  <= r;
            //fillQ.enq(tuple2(token, r));   //无论读写都在后一个状态处理，因为这里可能需要处理脏页
            if (isValid(currTag) && dirty) begin
                let addr = {fromMaybe(?, currTag), idx, 6'b0}; 
                let data = dataArray[idx];
                wideMem.req(WideMemReq {write_en: '1, addr: addr, data: data});   //'1表示全1扩展
                $display("[req_method][%0x]-receive a notHit_with_dirty req, op:%0x, r.addr:%0x, idx:%0x, tag:%0x, offset:%0x, token:%0x",id, r.op, r.addr, idx, tag, wOffset, token);
            end
            else begin
                $display("[req_method][%0x]-receive a notHit_no_dirty req, op:%0x, r.addr:%0x, idx:%0x, tag:%0x, offset:%0x, token:%0x",id, r.op, r.addr, idx, tag, wOffset, token);
            end
        end
    endmethod

    method ActionValue#(Data) resp;
        //hitQ.deq;
        //return hitQ.first;
        let d <- cb.drain.get();
        $display("[NBCache_resp_method][%0x]- data:%0x ", d);
        return d;
    endmethod

endmodule