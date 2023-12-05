
import ClientServer::*;
import FIFO::*;
import GetPut::*;

import FixedPoint::*;
import Vector::*;

import ComplexMP::*;


typedef Server#(
    Vector#(nbins, ComplexMP#(isize, fsize, psize)),
    Vector#(nbins, ComplexMP#(isize, fsize, psize))
) PitchAdjust#(numeric type nbins, numeric type isize, numeric type fsize, numeric type psize);


// s - the amount each window is shifted from the previous window.
//
// factor - the amount to adjust the pitch.
//  1.0 makes no change. 2.0 goes up an octave, 0.5 goes down an octave, etc...
module mkPitchAdjust(Integer s, FixedPoint#(isize, fsize) factor, PitchAdjust#(nbins, isize, fsize, psize) ifc) provisos (Add#(a__, psize, TAdd#(isize, isize)), Add#(b__, TLog#(nbins), isize), Add#(psize, c__, isize));
    
    FIFO#(Vector#(nbins, ComplexMP#(isize, fsize, psize))) inputFIFO  <- mkFIFO();
    FIFO#(Vector#(nbins, ComplexMP#(isize, fsize, psize))) outputFIFO <- mkFIFO();

    Vector#(nbins, Reg#(Phase#(psize))) inphases  <- replicateM(mkReg(0));
    Vector#(nbins, Reg#(Phase#(psize))) outphases <- replicateM(mkReg(0));

    Reg#(Vector#(nbins, ComplexMP#(isize, fsize, psize))) in  <- mkRegU();
    Reg#(Vector#(nbins, ComplexMP#(isize, fsize, psize))) out <- mkRegU();

    Reg#(Bit#(TLog#(nbins))) i <- mkReg(0);

    Reg#(FixedPoint#(isize, fsize)) bin <- mkReg(0);

    let phase = in[i].phase;
    let mag   = in[i].magnitude;
    let dphase = phase - inphases[i];

    let nbin = bin + factor;

    let bin_int = fxptGetInt(bin);
    let nbin_int = fxptGetInt(nbin);
    
    Bit#(TLog#(nbins)) bin_idx = pack(truncate(bin_int));

    FixedPoint#(isize, fsize) dphase_Fxpt = fromInt(dphase);
    let shifted_Fxpt = fxptMult(factor, dphase_Fxpt);
    Phase#(psize) shifted = truncate(fxptGetInt(shifted_Fxpt));
    Phase#(psize) phase_out = truncate(outphases[bin_idx] + shifted);

    Reg#(Bool) done <- mkReg(True);

    rule input_new (done && i == 0);
        in <= inputFIFO.first();
        inputFIFO.deq();
        out <= replicate(cmplxmp(0, 0));
        bin <= 0;
        done <= False; 
    endrule

    rule process_on (!done);
        inphases[i] <= phase;
        bin <= nbin;

        if (bin_int != nbin_int && bin_int >= 0 && bin_int < fromInteger(valueOf(nbins))) begin
            outphases[bin_idx] <= phase_out;
            out[bin_idx] <= cmplxmp(mag, phase_out);
        end

        if (i == fromInteger(valueOf(nbins) - 1)) begin
            done <= True;
        end
        else begin
            i <= i + 1;
        end
    endrule

    rule output_done (done && i == fromInteger(valueOf(nbins) - 1));
        outputFIFO.enq(out);
        i <= 0;
    endrule

    interface Put request;
        method Action put(Vector#(nbins, ComplexMP#(isize, fsize, psize)) x);
            inputFIFO.enq(x);
        endmethod
    endinterface

    interface Get response = toGet(outputFIFO);

endmodule

