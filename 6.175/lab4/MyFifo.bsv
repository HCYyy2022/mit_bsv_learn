import Ehr::*;
import Vector::*;

//////////////////
// Fifo interface 

interface Fifo#(numeric type n, type t);
    method Bool notFull;
    method Action enq(t x);
    method Bool notEmpty;
    method Action deq;
    method t first;
    method Action clear;
endinterface

/////////////////
// Conflict FIFO

module mkMyConflictFifo( Fifo#(n, t) ) provisos (Bits#(t,tSz));
    // n is size of fifo
    // t is data type of fifo
    Vector#(n, Reg#(t))     data     <- replicateM(mkRegU());
    Reg#(Bit#(TLog#(n)))    enqP     <- mkReg(0);
    Reg#(Bit#(TLog#(n)))    deqP     <- mkReg(0);
    Reg#(Bool)              empty    <- mkReg(True);
    Reg#(Bool)              full     <- mkReg(False);

    // useful value
    Bit#(TLog#(n))          max_index = fromInteger(valueOf(n)-1);

    method Bool notFull;
        return !full;
    endmethod

    method Action enq(t x) if(full == False) ;
        let nextEnqP = (enqP == max_index) ? 0 : (enqP + 1);
        data[enqP]   <= x;
        empty        <= False;
        full         <= nextEnqP == deqP;
        enqP         <= nextEnqP;
    endmethod

    method Bool notEmpty;
        return !empty;
    endmethod

    method Action deq if(empty == False) ;
        let nextDeqP = (deqP == max_index) ? 0 : (deqP + 1);
        full  <= False;
        empty <= nextDeqP == enqP;
        deqP  <= nextDeqP;
    endmethod

    method t first if(empty==False);
        return data[deqP];
    endmethod
    
    method Action clear;
        enqP  <= 0;
        deqP  <= 0;
        empty <= True;
        full  <= False;
    endmethod

endmodule

/////////////////
// Pipeline FIFO

// Intended schedule:
//      {notEmpty, first, deq} < {notFull, enq} < clear
module mkMyPipelineFifo( Fifo#(n, t) ) provisos (Bits#(t,tSz));
    // n is size of fifo
    // t is data type of fifo
    Vector#(n, Reg#(t) )     data  <-replicateM(mkRegU);
    Ehr#(3, Bit#(TLog#(n)))  enqP  <- mkEhr(0);
    Ehr#(3, Bit#(TLog#(n)))  deqP  <- mkEhr(0);
    Ehr#(3, Bool)            empty <- mkEhr(True);
    Ehr#(3, Bool)            full  <- mkEhr(False);

    Bit#(TLog#(n))          max_index = fromInteger(valueOf(n)-1);

    method Bool notFull;
        return !full[1];
    endmethod

    method Action enq(t x) if(full[1] == False) ;
        let nextEnqP = (enqP[1] == max_index) ? 0 : (enqP[1] + 1);
        data[enqP[1]]   <= x;
        empty[1]        <= False;
        full [1]        <= nextEnqP == deqP[1];
        enqP [1]        <= nextEnqP;
    endmethod

    method Bool notEmpty;
        return !empty[0];
    endmethod

    method Action deq if(empty[0] == False) ;
        let nextDeqP = (deqP[0] == max_index) ? 0 : (deqP[0] + 1);
        full [0]  <= False;
        empty[0]  <= nextDeqP == enqP[0];
        deqP [0]  <= nextDeqP;
    endmethod

    method t first if(empty[0]==False);
        return data[deqP[0]];
    endmethod

    method Action clear;
        enqP [2]  <= 0;
        deqP [2]  <= 0;
        empty[2]  <= True;
        full [2]  <= False;
    endmethod
endmodule

/////////////////////////////
// Bypass FIFO without clear

// Intended schedule:
//      {notFull, enq} < {notEmpty, first, deq} < clear

module mkMyBypassFifo( Fifo#(n, t) ) provisos (Bits#(t,tSz));
    // n is size of fifo
    // t is data type of fifo
    //Vector#(n, Reg#(t) )     data  <-replicateM(mkRegU);
    Vector#(n, Ehr#(2,t) )   data  <-replicateM(mkEhrU);    //保证能够deq当前周期enq的值
    Ehr#(3, Bit#(TLog#(n)))  enqP  <- mkEhr(0);
    Ehr#(3, Bit#(TLog#(n)))  deqP  <- mkEhr(0);
    Ehr#(3, Bool)            empty <- mkEhr(True);
    Ehr#(3, Bool)            full  <- mkEhr(False);

    Bit#(2) enq_port   = 0;
    Bit#(2) deq_port   = 1;
    Bit#(2) clear_port = 2;

    Bit#(TLog#(n))          max_index = fromInteger(valueOf(n)-1);

    method Bool notFull;
        return !full[enq_port];
    endmethod

    method Action enq(t x) if(full[enq_port] == False) ;
        let nextEnqP = (enqP[enq_port] == max_index) ? 0 : (enqP[enq_port] + 1);
        data[enqP[enq_port]][enq_port]   <= x;
        empty[enq_port]                  <= False;
        full [enq_port]                  <= nextEnqP == deqP[enq_port];
        enqP [enq_port]                  <= nextEnqP;
    endmethod

    method Bool notEmpty;
        return !empty[deq_port];
    endmethod

    method Action deq if(empty[deq_port] == False) ;
        let nextDeqP = (deqP[deq_port] == max_index) ? 0 : (deqP[deq_port] + 1);
        full [deq_port]  <= False;
        empty[deq_port]  <= nextDeqP == enqP[deq_port];
        deqP [deq_port]  <= nextDeqP;
    endmethod

    method t first if(empty[deq_port]==False);
        return data[deqP[deq_port]][deq_port];
    endmethod

    method Action clear;
        enqP [clear_port]  <= 0;
        deqP [clear_port]  <= 0;
        empty[clear_port]  <= True;
        full [clear_port]  <= False;
    endmethod
endmodule

//////////////////////
// Conflict free fifo

// Intended schedule:
//      {notFull, enq} CF {notEmpty, first, deq}
//      {notFull, enq, notEmpty, first, deq} < clear
module mkMyCFFifo( Fifo#(n, t) ) provisos (Bits#(t,tSz));
    // n is size of fifo
    // t is data type of fifo
    Vector#(n, Reg#(t))     data     <- replicateM(mkRegU());
    Reg#(Bit#(TLog#(n)))    enqP     <- mkReg(0);
    Reg#(Bit#(TLog#(n)))    deqP     <- mkReg(0);
    Reg#(Bool)              empty    <- mkReg(True);
    Reg#(Bool)              full     <- mkReg(False);

    Ehr#(2, Bool)         deqReq     <- mkEhr(False);
    Ehr#(2, Maybe#(t))    enqReq     <- mkEhr(tagged Invalid);
    Ehr#(2, Bool)         clearReq   <- mkEhr(False);

    // useful value
    Bit#(TLog#(n))          max_index = fromInteger(valueOf(n)-1);
    
    (* no_implicit_conditions *)
    (* fire_when_enabled *)
    rule canonicalize (True);    //每个周期都触发
        enqReq  [1] <= tagged Invalid;
        deqReq  [1] <= False;
        clearReq[1] <= False;
        
        let nextEnqP = (enqP == max_index) ? 0 : (enqP + 1);
        let nextDeqP = (deqP == max_index) ? 0 : (deqP + 1);
        
        let reqs =  tuple3(enqReq[1], deqReq[1], clearReq[1]);
        
        case(tuple3(enqReq[1], deqReq[1], clearReq[1])) matches
            {tagged Valid .dat, True, False} : begin    //enq and deq
                enqP       <= nextEnqP;
                deqP       <= nextDeqP;
                data[enqP] <= dat;
            end

            {tagged Valid .dat, False, False} : begin   //enq
                enqP       <= nextEnqP;
                empty      <= False;
                full       <= nextEnqP == deqP;
                data[enqP] <= dat;
            end
            {tagged Invalid, True, False} : begin   //deq
                deqP       <= nextDeqP;
                empty      <= nextDeqP == enqP;
                full       <= False;
            end
            {.*, .*, True} : begin   //clear
                deqP       <= 0;
                enqP       <= 0;
                empty      <= True;
                full       <= False;
            end
            default : begin end
        endcase
    endrule
    
    method Bool notFull;
        return !full;
    endmethod
    
    method Action enq(t x) if(full == False);
        enqReq[0] <= tagged Valid x;
    endmethod

    method Bool notEmpty;
        return !empty;
    endmethod
    
    method Action deq if(empty == False);
        deqReq[0] <= True;
    endmethod
    
    method t first if(empty == False);
        return data[deqP];
    endmethod
    
    method Action clear;
        clearReq[0] <= True;
    endmethod



endmodule

