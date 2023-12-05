
import ClientServer::*;
import GetPut::*;

import AudioProcessorTypes::*;
import Chunker::*;
import FFT::*;
import FIRFilter::*;
import FilterCoefficients::*;
import Splitter::*;
import FixedPoint::*;

import OverSampler::*;
import Overlayer::*;
import PitchAdjust::*;
import ToMP::*;
import FromMP::*;
import Complex::*;
import Vector::*;

typedef 8 N;
typedef 2 S;
typedef 2 FACTOR;
typedef 16 ISIZE;
typedef 16 FSIZE;
typedef 16 PSIZE;

module mkAudioPipeline(AudioProcessor);

    AudioProcessor fir <- mkFIRFilter(c);
    Chunker#(S, Sample) chunker <- mkChunker();

    Vector#(N, Sample) init_vec = replicate(0);
    OverSampler#(S, N, Sample) over_sampler <- mkOverSampler(init_vec);

    FFT#(FFT_POINTS, FixedPoint#(ISIZE, PSIZE)) fft <- mkFFT();

    ToMP#(N, ISIZE, FSIZE, PSIZE) tomp <- mkToMP();

    FixedPoint#(isize, fsize) factor = fromInteger(valueOf(FACTOR));
    PitchAdjust#(N, ISIZE, FSIZE, PSIZE) pitch_adjust <- mkPitchAdjust(valueOf(S), factor);

    FromMP#(N, ISIZE, FSIZE, PSIZE) frommp <- mkFromMP();

    FFT#(N, FixedPoint#(ISIZE, PSIZE)) ifft <- mkIFFT();
    Overlayer#(N, S, Sample) over_layer <- mkOverlayer(init_vec);
    Splitter#(S, Sample) splitter <- mkSplitter();

    rule fir_to_chunker (True);
        let x <- fir.getSampleOutput();
        // chunker.request.put(tocmplx(x));
        chunker.request.put(x);
    endrule

    rule chunker_to_oversampler (True);
        let x <- chunker.response.get();
        // fft.request.put(x);
        over_sampler.request.put(x);
    endrule

    rule oversampler_to_fft (True);
        let x <- over_sampler.response.get();
        fft.request.put(tocmplx_vec(x));
    endrule
    
    rule fft_to_tomp (True);
        let x <- fft.response.get();
        tomp.request.put(x); 
    endrule

    rule tomp_to_pitchadjust (True);
        let x <- tomp.response.get();
        pitch_adjust.request.put(x);
    endrule

    rule pitchadjust_to_frommp (True);
        let x <- pitch_adjust.response.get();
        frommp.request.put(x);
    endrule

    rule frommp_to_ifft (True);
        let x <- frommp.response.get();
        ifft.request.put(x);
    endrule

    rule ifft_to_overlayer (True);
        let x <- ifft.response.get();
        over_layer.request.put(frcmplx_vec(x));
    endrule

    rule overlayer_to_splitter (True);
        let x <- over_layer.response.get();
        splitter.request.put(x);
    endrule

    method Action putSampleInput(Sample x);
        fir.putSampleInput(x);
    endmethod

    method ActionValue#(Sample) getSampleOutput();
        let x <- splitter.response.get();
        return x;
    endmethod

endmodule

