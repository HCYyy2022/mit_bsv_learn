import ClientServer::*;
import FIFO::*;
import GetPut::*;

import FixedPoint::*;
import Vector::*;

import Complex::*;
import ComplexMP::*;
import Cordic::*;

typedef Server#(
    Vector#(nbins, ComplexMP#(isize, fsize, psize)),
    Vector#(nbins, Complex#(FixedPoint#(isize, fsize)))
) FromMP#(numeric type nbins, numeric type isize, numeric type fsize, numeric type psize);

module mkFromMP (FromMP#(nbins, isize, fsize, psize));
    FIFO#(Vector#(nbins, ComplexMP#(isize, fsize, psize))) infifo <- mkFIFO();
    FIFO#(Vector#(nbins, Complex#(FixedPoint#(isize, fsize))))  outfifo <- mkFIFO();
    
    Vector#(nbins, FromMagnitudePhase#(isize, fsize, psize)) fromMP <- replicateM(mkCordicFromMagnitudePhase());
    // Vector#(nbins, Complex#(FixedPoint#(isize, fsize))) out ;

    let nbins_int = valueOf(nbins);

    rule in_data;
        for (Integer i = 0; i < nbins_int; i = i + 1) begin
            fromMP[i].request.put(infifo.first[i]);
        end
        infifo.deq();
    endrule

    rule out_data;
        Vector#(nbins, Complex#(FixedPoint#(isize, fsize))) out ;
        for (Integer i = 0; i < nbins_int; i = i + 1) begin
            out[i] <- fromMP[i].response.get();
        end
        outfifo.enq(out);
    endrule

    interface Put request = toPut(infifo);
    interface Get response = toGet(outfifo);

endmodule
