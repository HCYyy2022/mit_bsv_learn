import CacheTypes::*;
import MyFifo::*;
import MemTypes::*;
import MemUtil::*;


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
