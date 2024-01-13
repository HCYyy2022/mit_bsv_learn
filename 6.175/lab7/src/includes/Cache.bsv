import CacheTypes::*;
import MyFifo::*;
import MemTypes::*;
import MemUtil::*;
import Vector::*;
import Types::*;


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
