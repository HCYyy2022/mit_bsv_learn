import Vector::*;
import Complex::*;

import FftCommon::*;
import FIFOF::*;
//import Fifo::*;

interface Fft;
    method Action enq(Vector#(FftPoints, ComplexData) in);
    method ActionValue#(Vector#(FftPoints, ComplexData)) deq;
endinterface

//==============================================================================//
//function : my_stage_f
//==============================================================================//
function Vector#(FftPoints, ComplexData) my_stage_f(StageIdx stage, Vector#(FftPoints, ComplexData) stage_in, Vector#(NumStages, Vector#(BflysPerStage, Bfly4)) bfly);
    Vector#(FftPoints, ComplexData) stage_temp, stage_out;
    for (FftIdx i = 0; i < fromInteger(valueOf(BflysPerStage)); i = i + 1)  begin
        FftIdx idx = i * 4;
        Vector#(4, ComplexData) x;
        Vector#(4, ComplexData) twid;
        for (FftIdx j = 0; j < 4; j = j + 1 ) begin
            x[j] = stage_in[idx+j];
            twid[j] = getTwiddle(stage, idx+j);
        end
        let y = bfly[stage][i].bfly4(twid, x);

        for(FftIdx j = 0; j < 4; j = j + 1 ) begin
            stage_temp[idx+j] = y[j];
        end
    end

    stage_out = permute(stage_temp);

    return stage_out;
endfunction


(* synthesize *)
module mkFftCombinational(Fft);
    FIFOF#(Vector#(FftPoints, ComplexData)) inFifo  <- mkFIFOF;
    FIFOF#(Vector#(FftPoints, ComplexData)) outFifo <- mkFIFOF;
    //Fifo#(2,Vector#(FftPoints, ComplexData)) inFifo <- mkCFFifo;
    //Fifo#(2,Vector#(FftPoints, ComplexData)) outFifo <- mkCFFifo;
    Vector#(NumStages, Vector#(BflysPerStage, Bfly4)) bfly <- replicateM(replicateM(mkBfly4));

    function Vector#(FftPoints, ComplexData) stage_f(StageIdx stage, Vector#(FftPoints, ComplexData) stage_in);
        Vector#(FftPoints, ComplexData) stage_temp, stage_out;
        for (FftIdx i = 0; i < fromInteger(valueOf(BflysPerStage)); i = i + 1)  begin
            FftIdx idx = i * 4;
            Vector#(4, ComplexData) x;
            Vector#(4, ComplexData) twid;
            for (FftIdx j = 0; j < 4; j = j + 1 ) begin
                x[j] = stage_in[idx+j];
                twid[j] = getTwiddle(stage, idx+j);
            end
            let y = bfly[stage][i].bfly4(twid, x);

            for(FftIdx j = 0; j < 4; j = j + 1 ) begin
                stage_temp[idx+j] = y[j];
            end
        end

        stage_out = permute(stage_temp);

        return stage_out;
    endfunction
  
    rule doFft;
        if( inFifo.notEmpty && outFifo.notFull ) begin
            inFifo.deq;
            Vector#(4, Vector#(FftPoints, ComplexData)) stage_data;
            stage_data[0] = inFifo.first;
      
            for (StageIdx stage = 0; stage < 3; stage = stage + 1) begin
                stage_data[stage+1] = stage_f(stage, stage_data[stage]);
            end
            outFifo.enq(stage_data[3]);
        end
    endrule
    
    method Action enq(Vector#(FftPoints, ComplexData) in);
        inFifo.enq(in);
    endmethod
  
    method ActionValue#(Vector#(FftPoints, ComplexData)) deq;
        outFifo.deq;
        return outFifo.first;
    endmethod
endmodule

//==============================================================================//
//Exercise 2 : mkFftFolded
//==============================================================================//
(* synthesize *)
module mkFftFolded(Fft);
    FIFOF#(Vector#(FftPoints, ComplexData)) inFifo  <- mkFIFOF;
    FIFOF#(Vector#(FftPoints, ComplexData)) outFifo <- mkFIFOF;
    //Fifo#(2,Vector#(FftPoints, ComplexData)) inFifo <- mkCFFifo;
    //Fifo#(2,Vector#(FftPoints, ComplexData)) outFifo <- mkCFFifo;

    Reg#(StageIdx)                         stage <- mkReg(0);
    Reg#(Vector#(FftPoints, ComplexData))  sReg  <- mkRegU;
    Vector#(NumStages, Vector#(BflysPerStage, Bfly4)) bfly <- replicateM(replicateM(mkBfly4));    //3级，每级16个Bfly4
    rule doFft;
        if(stage == 0) begin
            sReg  <= my_stage_f(stage, inFifo.first(), bfly);
            stage <= stage + 1;
            inFifo.deq();
        end
        else if( (stage != 0) && (stage != (fromInteger(valueOf(NumStagesSub1)))) ) begin
            sReg  <= my_stage_f(stage, sReg, bfly);
            stage <= stage + 1;
        end 
        else if(stage == (fromInteger(valueOf(NumStagesSub1)))) begin
            outFifo.enq( my_stage_f(stage, sReg, bfly) );
            stage <= 0;
        end
    endrule
    
    //rule  foldedEntry(stage == 0);
    //    sReg  <= my_stage_f(stage, inFifo.first(), bfly);
    //    stage <= stage + 1;
    //    inFifo.deq();
    //endrule 

    //rule  foldedCirculate( (stage != 0) && (stage != (fromInteger(valueOf(NumStagesSub1)))) );
    //    sReg  <= my_stage_f(stage, sReg, bfly);
    //    stage <= stage + 1;
    //endrule 
    //
    //rule  foldedExit(stage == (fromInteger(valueOf(NumStagesSub1))));
    //    outFifo.enq( my_stage_f(stage, sReg, bfly) );
    //    stage <= 0;
    //endrule 

    method Action enq(Vector#(FftPoints, ComplexData) in);
        inFifo.enq(in);
    endmethod

    method ActionValue#(Vector#(FftPoints, ComplexData)) deq;
        outFifo.deq;
        return outFifo.first;
    endmethod
endmodule

//==============================================================================//
//Exercise 3 : mkFftInelasticPipeline
//==============================================================================//
(* synthesize *)
module mkFftInelasticPipeline(Fft);
    FIFOF#(Vector#(FftPoints, ComplexData)) inFifo  <- mkFIFOF;
    FIFOF#(Vector#(FftPoints, ComplexData)) outFifo <- mkFIFOF;
    //Fifo#(2,Vector#(FftPoints, ComplexData)) inFifo <- mkCFFifo;
    //Fifo#(2,Vector#(FftPoints, ComplexData)) outFifo <- mkCFFifo;
    Vector#(NumStages, Vector#(BflysPerStage, Bfly4)) bfly <- replicateM(replicateM(mkBfly4));    //3级，每级16个Bfly4
    
    Vector#(NumStagesSub1, Reg#(Maybe #(Vector#(FftPoints, ComplexData))) ) sReg <- replicateM(mkRegU);

    rule doFft;
        if(inFifo.notEmpty) begin
            sReg[0] <= tagged Valid (my_stage_f(0, inFifo.first, bfly));
            inFifo.deq;
        end
        else begin
            sReg[0] <= tagged Invalid;
        end
        // At stage1 - stageN-1
        for(StageIdx stage=0; stage < fromInteger(valueOf(NumStagesSub2)); stage=stage+1 ) begin
            case (sReg[stage]) matches
                tagged Invalid   : sReg[stage+1] <= tagged Invalid;
                tagged Valid   .x: sReg[stage+1] <= tagged Valid ( my_stage_f(stage+1, x, bfly ) );
            endcase
        end
        // Last stage
        if (isValid(sReg[fromInteger(valueOf(NumStagesSub2))])) begin
            outFifo.enq(my_stage_f(fromInteger(valueOf(NumStagesSub1)), fromMaybe(?, sReg[fromInteger(valueOf(NumStagesSub2))]), bfly));
        end
    endrule

    method Action enq(Vector#(FftPoints, ComplexData) in);
        inFifo.enq(in);
    endmethod
  
    method ActionValue#(Vector#(FftPoints, ComplexData)) deq;
        outFifo.deq;
        return outFifo.first;
    endmethod
endmodule

//==============================================================================//
//Exercise 4 : mkFftElasticPipeline
//==============================================================================//
(* synthesize *)
module mkFftElasticPipeline(Fft);
    Vector#(NumStagesAdd1, FIFOF#( Vector#(FftPoints, ComplexData)) ) stageFifo <- replicateM(mkFIFOF);
    //Vector#(NumStagesAdd1, MyFifo#(3, Vector#(FftPoints, ComplexData))) stageFifo <- replicateM(mkMyFifo);
    Vector#(NumStages, Vector#(BflysPerStage, Bfly4)) bfly <- replicateM(replicateM(mkBfly4));    //3级，每级16个Bfly4

    for(StageIdx stage=0; stage < fromInteger(valueOf(NumStages)); stage=stage+1 ) begin
        rule doFft;
            stageFifo[stage].deq;
            stageFifo[stage+1].enq(my_stage_f(stage, stageFifo[stage].first, bfly));
        endrule
    end

    method Action enq(Vector#(FftPoints, ComplexData) in);
        stageFifo[0].enq(in);
    endmethod

    method ActionValue#(Vector#(FftPoints, ComplexData)) deq;
        stageFifo[fromInteger(valueOf(NumStages))].deq;
        return stageFifo[fromInteger(valueOf(NumStages))].first;
    endmethod
endmodule

//==============================================================================//
//Bonus : mkFftSuperFolded
//==============================================================================//
interface SuperFoldedFft#(numeric type radix);
    method ActionValue#(Vector#(FftPoints, ComplexData)) deq;
    method Action enq(Vector#(FftPoints, ComplexData) in);
endinterface

module mkFftSuperFolded(SuperFoldedFft#(radix)) provisos(Div#(TDiv#(FftPoints, 4), radix, times), Mul#(radix, times, TDiv#(FftPoints, 4)));
    FIFOF#(Vector#(FftPoints, ComplexData)) inFifo  <- mkFIFOF;
    FIFOF#(Vector#(FftPoints, ComplexData)) outFifo <- mkFIFOF;

    Vector#(radix, Bfly4)                  bfly    <- replicateM(mkBfly4);      //radix个Bfly4
    Vector#(FftPoints, Reg#(ComplexData))  sReg    <- replicateM(mkRegU);       //FftPoints个寄存器
    //Reg#(Vector#(FftPoints, ComplexData))  sReg    <- mkRegU;
    Reg#(StageIdx)                         stage   <- mkReg(0);
    Reg#(FftIdx)                           timeIdx <- mkReg(0);

    rule  foldedEntry(stage == 0 && timeIdx == 0);
        let temp = inFifo.first;
        for (int i = 0; i < fromInteger(valueOf(FftPoints)); i = i + 1 ) begin       
            sReg[i]  <= temp[i];   
        end
        stage <= stage + 1;
        inFifo.deq();
    endrule 
    
    rule step_Bfly4( (stage != 0) && (stage != (fromInteger(valueOf(NumStagesAdd1)))) && (timeIdx != fromInteger(valueOf(times))) );  //TODO:
        Vector#(radix, Vector#(4, ComplexData))  res;   //radix个bfly4，每个4个数据
        let stageTrue = stage - 1;
        let oneLoopProcPoint = 4*fromInteger(valueOf(radix));
        for (FftIdx i = 0; i < fromInteger(valueOf(radix)); i = i + 1 ) begin       //radix个bfly4
            Vector#(4, ComplexData)  twid;
            Vector#(4, ComplexData)  temp;
            for (FftIdx j = 0; j < 4; j = j + 1 ) begin   //每个bfly4 处理4个数据
                let idx = timeIdx*oneLoopProcPoint + i*4+j;
                temp[j] = sReg[idx];
                twid[j] = getTwiddle(stageTrue, idx);
            end

            res[i] = bfly[i].bfly4(twid, temp);

            for (FftIdx j = 0; j < 4; j = j + 1 ) begin
                sReg[timeIdx*oneLoopProcPoint+i*4+j] <= res[i][j];
            end
        end
        timeIdx <= timeIdx + 1;
    endrule

    rule doPermute(timeIdx == fromInteger(valueOf(times)));
        Vector#(FftPoints,ComplexData) temp, res ;  
        for (int i = 0; i < fromInteger(valueOf(FftPoints)); i = i + 1 ) begin       
            temp[i]  = sReg[i];   
        end
        res =  permute(temp) ;  
        for (int i = 0; i < fromInteger(valueOf(FftPoints)); i = i + 1 ) begin       
            sReg[i]  <= res[i];   
        end
        timeIdx <= 0;
        stage   <= stage + 1;
    endrule

    rule  foldedExit(stage == (fromInteger(valueOf(NumStagesAdd1)))  && timeIdx == 0);  
        Vector#(FftPoints,ComplexData) temp ;  
        for (int i = 0; i < fromInteger(valueOf(FftPoints)); i = i + 1 ) begin       
            temp[i]  = sReg[i];   
        end
        outFifo.enq( temp );
        stage <= 0;
    endrule 

    method Action enq(Vector#(FftPoints, ComplexData) in);
        inFifo.enq(in);
    endmethod
  
    method ActionValue#(Vector#(FftPoints, ComplexData)) deq;
        outFifo.deq;
        return outFifo.first;
    endmethod
endmodule

function Fft getFft(SuperFoldedFft#(radix) f);
    return (interface Fft;
        method enq = f.enq;
        method deq = f.deq;
    endinterface);
endfunction

(* synthesize *)
module mkFftSuperFolded4(Fft);
    SuperFoldedFft#(4) sfFft <- mkFftSuperFolded;
    return (getFft(sfFft));
endmodule

(* synthesize *)
module mkFftSuperFolded2(Fft);
    SuperFoldedFft#(2) sfFft <- mkFftSuperFolded;
    return (getFft(sfFft));
endmodule
