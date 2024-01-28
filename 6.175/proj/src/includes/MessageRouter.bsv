import CacheTypes:: *;
import MyFifo:: *;
import Vector:: *;
import Types::*;


module mkMessageRouter(
  Vector#(CoreNum, MessageGet) c2r,
  Vector#(CoreNum, MessagePut) r2c, 
  MessageGet m2r,
  MessagePut r2m,
  Empty ifc 
);


    rule doRoute;
        Bit#(TLog#(CoreNum))  respIdx = 0;
        Bit#(TLog#(CoreNum))  reqIdx  = 0;
        Bool haveC2RResp = False;
        Bool haveC2RReq  = False;
        let  haveM2RResp = m2r.hasResp;
        let  haveM2RReq  = m2r.hasReq;
        //let CoreNumInt = valueOf(CoreNum);   //TODO: 这种写法为什么不行

        for(Integer i=0; i<valueOf(CoreNum); i=i+1) begin
            if(c2r[i].hasResp) begin
                haveC2RResp = True;
                respIdx = fromInteger(i);   //最后一个具有最高的优先级
            end
            else if(c2r[i].hasReq) begin
                haveC2RReq  = True;
                reqIdx = fromInteger(i);
            end
        end
        
        if(haveC2RResp) begin
            r2m.enq_resp(c2r[respIdx].first.Resp);
            c2r[respIdx].deq;
        end
        else if(haveM2RResp) begin
            let rsp = m2r.first.Resp;
            m2r.deq;
            r2c[rsp.child].enq_resp(rsp);
        end
        else if(haveC2RReq) begin
            r2m.enq_req(c2r[reqIdx].first.Req);
            c2r[reqIdx].deq;
        end
        else if(haveM2RReq) begin
            let req = m2r.first.Req;
            m2r.deq;
            r2c[req.child].enq_req(req);
        end

    endrule


endmodule