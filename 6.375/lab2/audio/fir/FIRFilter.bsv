
import FIFO::*;
import FixedPoint::*;
import Multiplier::*;
import Vector:: *;

import AudioProcessorTypes :: *;
//import FilterCoefficients::*;


module mkFIRFilter(Vector#(9, FixedPoint#(16,16)) coeffs, AudioProcessor ifc);
    FIFO#(Sample)  infifo <- mkFIFO();
    FIFO#(Sample) outfifo <- mkFIFO();

    Vector#(8, Reg#(Sample)) r <- replicateM(mkReg(0));
    Vector#(9, Multiplier)   multipliers <- replicateM(mkMultiplier());
    
    rule mult_process;
        let sample = infifo.first();
        infifo.deq();
        
        r[0] <= sample;
        for(Integer i=1; i<8; i=i+1) begin
            r[i] <= r[i-1];
        end
        
        multipliers[0].putOperands(coeffs[0], sample);
        for(int i=1; i<9; i=i+1) begin
            multipliers[i].putOperands(coeffs[i], r[i-1]);
        end
    endrule

    rule acc_process;
        FixedPoint#(16, 16) accumulate = 0 ;
        for(int i=0; i<9; i=i+1) begin
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