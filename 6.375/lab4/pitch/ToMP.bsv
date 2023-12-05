
import ClientServer::*;
import FIFO::*;
import GetPut::*;

import FixedPoint::*;
import Vector::*;

import Complex::*;
import ComplexMP::*;
import Cordic::*;

typedef Server#(
    Vector#(nbins, Complex#(FixedPoint#(isize, fsize))),
    Vector#(nbins, ComplexMP#(isize, fsize, psize))
) ToMP#(numeric type nbins, numeric type isize, numeric type fsize, numeric type psize);

module mkToMP (ToMP#(nbins, isize, fsize, psize) ifc);

    FIFO#(Vector#(nbins, Complex#(FixedPoint#(isize, fsize)))) infifo <- mkFIFO();
    FIFO#(Vector#(nbins, ComplexMP#(isize, fsize, psize))) outfifo <- mkFIFO();

    Vector#(nbins, ToMagnitudePhase#(isize, fsize, psize)) toMP <- replicateM(mkCordicToMagnitudePhase());
    // Vector#(nbins, ComplexMP#(isize, fsize, psize)) out ;

    let nbins_int = valueOf(nbins);

    rule in_data;
        for (Integer i = 0; i < nbins_int; i = i + 1) begin
            toMP[i].request.put(infifo.first[i]);
        end
        infifo.deq();
    endrule
    
    rule out_data;
        Vector#(nbins, ComplexMP#(isize, fsize, psize)) out;
        for (Integer i = 0; i < nbins_int; i = i + 1) begin
            out[i] <- toMP[i].response.get();
        end
        outfifo.enq(out);
    endrule

    interface Put request = toPut(infifo);
    interface Get response = toGet(outfifo);

endmodule