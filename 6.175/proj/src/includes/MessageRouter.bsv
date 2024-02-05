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
    Bool  needDebugPrint = True;
    Fmt   printPrefix = $format("[messageRouter debug]");

    Reg#(CoreID)  lastRespProcIdx <- mkReg(0);  //TODO:  初始值最好弄成CoreNum-1
    Reg#(CoreID)  lastReqProcIdx  <- mkReg(0);

    function Action  debugInfoPrint(Bool needPrint,Fmt prefix, Fmt info);
        return action
            if(needPrint) $display(prefix + info);
        endaction;
    endfunction

    function  CoreID fixPriorityArbiter(Bit#(CoreNum) req);
        Integer  coreIdxMax = valueOf(CoreNum) - 1;
        CoreID  grantIdx = 0;
        for(Integer i=coreIdxMax; i>=0; i=i-1) begin
            if(req[i] == 1) 
                grantIdx = fromInteger(i);
        end
        return  grantIdx;
    endfunction

    function  CoreID roundRobinArbiter(Bit#(CoreNum) req,  CoreID lastGrantIdx);
        CoreID  grantIdx = 0;
        CoreID  coreIdxMax = fromInteger(valueOf(CoreNum) - 1);
        Bool    find = False;

        for(Integer i=0; i<valueOf(CoreNum); i=i+1) begin
            CoreID  idxBit = fromInteger(i);
            CoreID  roundRobinIdx = 0;
            if(!find) begin
                if(lastGrantIdx < coreIdxMax - idxBit) 
                    roundRobinIdx = lastGrantIdx + idxBit + 1;
                else 
                    roundRobinIdx =  lastGrantIdx -  (coreIdxMax - idxBit);
                
                if(req[roundRobinIdx] == 1) begin
                    grantIdx = roundRobinIdx;
                    find = True;
                end
            end
        end

        return  grantIdx;
    endfunction


    rule doRoute;
        Bool haveC2RResp = False;
        Bool haveC2RReq  = False;
        let  haveM2RResp = m2r.hasResp;
        let  haveM2RReq  = m2r.hasReq;
        //let CoreNumInt = valueOf(CoreNum);   //TODO: 这种写法为什么不行

        Bit#(CoreNum) c2rRespArbReq = 0;
        Bit#(CoreNum) c2rReqArbReq  = 0;

        for(Integer i=0; i<valueOf(CoreNum); i=i+1) begin
            c2rRespArbReq[i] = pack(c2r[i].hasResp);
            c2rReqArbReq [i] = pack(c2r[i].hasReq);
        end

        haveC2RResp  = c2rRespArbReq != 0;
        haveC2RReq   = c2rReqArbReq  != 0;
        let respIdx      = roundRobinArbiter(c2rRespArbReq, lastRespProcIdx);
        let reqIdx       = roundRobinArbiter(c2rReqArbReq , lastReqProcIdx );
        
        if(haveC2RResp) begin 
            lastRespProcIdx <= respIdx;
            debugInfoPrint(needDebugPrint, printPrefix, $format("[haveC2RResp], current respIdx :%4b, next respIdx: %4b  ",lastRespProcIdx, respIdx ) );
        end
        if(haveC2RReq) begin
            lastReqProcIdx  <= reqIdx;
            debugInfoPrint(needDebugPrint, printPrefix, $format("[haveC2RReq],  current reqIdx :%4b, next reqIdx: %4b  ",lastReqProcIdx, reqIdx ) );
        end
        
        if(haveM2RResp) begin
            let rsp = m2r.first.Resp;
            m2r.deq;
            r2c[rsp.child].enq_resp(rsp);
        end
        else if(haveC2RResp) begin
            r2m.enq_resp(c2r[respIdx].first.Resp);
            c2r[respIdx].deq;
        end
        else if(haveM2RReq) begin
            let req = m2r.first.Req;
            m2r.deq;
            r2c[req.child].enq_req(req);
        end
        else if(haveC2RReq) begin
            r2m.enq_req(c2r[reqIdx].first.Req);
            c2r[reqIdx].deq;
        end

    endrule


endmodule