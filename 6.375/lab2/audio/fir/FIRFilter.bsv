
import FIFO::*;
import FixedPoint::*;
import Multiplier::*;
import Vector:: *;

import AudioProcessorTypes :: *;
//import FilterCoefficients::*;


module mkFIRFilter(Vector#(tnpNum, FixedPoint#(16,16)) coeffs, AudioProcessor ifc);
    FIFO#(Sample)  infifo <- mkFIFO();
    FIFO#(Sample) outfifo <- mkFIFO();

    Vector#(TSub#(tnpNum, 1), Reg#(Sample)) r <- replicateM(mkReg(0));
    Vector#(tnpNum, Multiplier)   multipliers <- replicateM(mkMultiplier());
    
    rule mult_process;
        let sample = infifo.first();
        infifo.deq();
        
        r[0] <= sample;
        for(Integer i=1; i<( valueOf(tnpNum)-1 ); i=i+1) begin
            r[i] <= r[i-1];
        end
        
        multipliers[0].putOperands(coeffs[0], sample);
        for(Integer i=1; i<valueOf(tnpNum); i=i+1) begin
            multipliers[i].putOperands(coeffs[i], r[i-1]);
        end
    endrule

    rule acc_process;
        FixedPoint#(16, 16) accumulate = 0 ;
        for(Integer i=0; i<valueOf(tnpNum); i=i+1) begin
            let t <- multipliers[i].getResult();
            accumulate = accumulate + t;
        end
        outfifo.enq(fxptGetInt(accumulate));
    endrule
    
    method Action putSampleInput(Sample in);
        infifo.enq(in);
    endmethod

    method ActionValue#(Sample) getSampleOutput();
        outfifo.deq();
        return outfifo.first();
    endmethod

    

endmodule