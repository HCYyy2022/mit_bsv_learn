import Multiplexer::*;

// Full adder functions

function Bit#(1) fa_sum( Bit#(1) a, Bit#(1) b, Bit#(1) c_in );
    return xor1( xor1( a, b ), c_in );
endfunction

function Bit#(1) fa_carry( Bit#(1) a, Bit#(1) b, Bit#(1) c_in );
    return or1( and1( a, b ), and1( xor1( a, b ), c_in ) );
endfunction

// Exercise 4
// Complete the code for add4 by using a for loop to properly connect all the uses of fa_sum and fa_carry.
// 4 Bit full adder
function Bit#(5) add4( Bit#(4) a, Bit#(4) b, Bit#(1) c_in );
    Bit#(4) sum;
    Bit#(1) c = c_in;
    for(Integer i=0; i<4; i=i+1) begin
        sum[i] = fa_sum  (a[i], b[i], c);
        c      = fa_carry(a[i], b[i], c);
    end
    return {c, sum};
    //return 0;
endfunction

// Adder interface

interface Adder8;
    method ActionValue#( Bit#(9) ) sum( Bit#(8) a, Bit#(8) b, Bit#(1) c_in );
endinterface


// Adder modules
// RC = Ripple Carry
module mkRCAdder( Adder8 );
    method ActionValue#( Bit#(9) ) sum( Bit#(8) a, Bit#(8) b, Bit#(1) c_in );
        Bit#(5) lower_result = add4( a[3:0], b[3:0], c_in );
        Bit#(5) upper_result = add4( a[7:4], b[7:4], lower_result[4] );
        return { upper_result , lower_result[3:0] };
    endmethod
endmodule

// Exercise 5
// Complete the code for the carry-select adder in the module mkCSAdder.
// Use Figure 3 as a guide for the required hardware and connections.

// CS = Carry Select
module mkCSAdder( Adder8 );
    method ActionValue#( Bit#(9) ) sum( Bit#(8) a, Bit#(8) b, Bit#(1) c_in );
        Bit#(5) lower_result = add4( a[3:0], b[3:0], c_in );
        //Bit#(5) upper_result = add4( a[7:4], b[7:4], lower_result[4] );
        Bit#(5) upper_result0 = add4( a[7:4], b[7:4], 0 );
        Bit#(5) upper_result1 = add4( a[7:4], b[7:4], 1 );
        let upper_result = multiplexer5(lower_result[4], upper_result0, upper_result1);
        return { upper_result , lower_result[3:0] };
    endmethod
endmodule

