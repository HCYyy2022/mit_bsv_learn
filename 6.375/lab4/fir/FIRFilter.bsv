import Vector::*;
import FIFO::*;
import FixedPoint::*;

import AudioProcessorTypes::*;
// import FilterCoefficients::*;
import Multiplier::*;

module mkFIRFilter (Vector#(c_num, FixedPoint#(16, 16)) coeffs, AudioProcessor ifc);
    FIFO#(Sample) infifo <- mkFIFO();
    FIFO#(Sample) outfifo <- mkFIFO();

    Vector#(TSub#(c_num, 1), Reg#(Sample)) r <- replicateM(mkReg(0));

    Vector#(c_num , Multiplier) multiplier <- replicateM(mkMultiplier());


    rule mul_step;
        let sample = infifo.first();
        infifo.deq();

        r[0] <= sample;
        for (Integer i = 0; i < valueOf(c_num) - 2; i = i + 1) begin
            r[i + 1] <= r[i];
        end 

        multiplier[0].putOperands(coeffs[0], sample);
        for (Integer i = 0; i < valueOf(c_num) - 1; i = i + 1) begin
            multiplier[i + 1].putOperands(coeffs[i + 1], r[i]);
        end
    endrule 

    rule acc_out ;
        Vector#(9, FixedPoint#(16, 16)) acc;

        acc[0] <- multiplier[0].getResult();
        for (Integer i = 1; i < 9; i = i + 1) begin
            let temp <- multiplier[i].getResult();
            acc[i] = acc[i - 1] + temp; 
        end

        outfifo.enq(fxptGetInt(acc[8]));
    endrule

    method Action putSampleInput(Sample in);
        infifo.enq(in);
    endmethod

    method ActionValue#(Sample) getSampleOutput();
        outfifo.deq();
        return outfifo.first();
    endmethod

endmodule