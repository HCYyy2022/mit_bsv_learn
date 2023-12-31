
import Complex::*;
import FixedPoint::*;
import Reg6375::*;

export AudioProcessorTypes::*;
export Reg6375::*;

typedef Int#(16) Sample;

interface AudioProcessor;
    method Action putSampleInput(Sample in);
    method ActionValue#(Sample) getSampleOutput();
endinterface


typedef Complex#(FixedPoint#(16, 16)) ComplexSample;
typedef FixedPoint#(16, 16) FixForm;

// Turn a real Sample into a ComplexSample.
function ComplexSample tocmplx(Sample x);
    return cmplx(fromInt(x), 0);
endfunction

// Extract the real component from complex.
function Sample frcmplx(ComplexSample x);
    return unpack(truncate(x.rel.i));
endfunction


typedef 8 FFT_POINTS;
typedef TLog#(FFT_POINTS) FFT_LOG_POINTS;
typedef TSub#(TLog#(FFT_POINTS), 1) FFT_LOG_POINTS_SUB1;
typedef Bit#(TLog#(TLog#(FFT_POINTS))) STAGE_IDX;     //3

