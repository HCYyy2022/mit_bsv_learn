// Reference functions that use Bluespec's '*' operator
function Bit#(TAdd#(n,n)) multiply_unsigned( Bit#(n) a, Bit#(n) b );
    UInt#(n) a_uint = unpack(a);
    UInt#(n) b_uint = unpack(b);
    UInt#(TAdd#(n,n)) product_uint = zeroExtend(a_uint) * zeroExtend(b_uint);
    return pack( product_uint );
endfunction

function Bit#(TAdd#(n,n)) multiply_signed( Bit#(n) a, Bit#(n) b );
    Int#(n) a_int = unpack(a);
    Int#(n) b_int = unpack(b);
    Int#(TAdd#(n,n)) product_int = signExtend(a_int) * signExtend(b_int);
    return pack( product_int );
endfunction



// Multiplication by repeated addition
function Bit#(TAdd#(n,n)) multiply_by_adding( Bit#(n) a, Bit#(n) b );
    Bit#(n) carry = 0;
    Bit#(n) res = 0;

    for(Integer i = 0; i < valueOf(n); i = i + 1)
    begin
        Bit#(TAdd#(1,n)) sum = zeroExtend(carry) + ((b[i] == 1) ? zeroExtend(a) : 0);
        res[i] = sum[0];
        carry = truncateLSB(sum);
    end
    return {carry, res};
endfunction



// Multiplier Interface
interface Multiplier#( numeric type n );
    method Bool start_ready();
    method Action start( Bit#(n) a, Bit#(n) b );
    method Bool result_ready();
    method ActionValue#(Bit#(TAdd#(n,n))) result();
endinterface



// Folded multiplier by repeated addition
module mkFoldedMultiplier( Multiplier#(n) );
    // You can use these registers or create your own if you want

    Reg#(Bit#(n)) a     <- mkRegU();
    Reg#(Bit#(n)) b     <- mkRegU();
    Reg#(Bit#(n)) res   <- mkRegU();
    Reg#(Bit#(n)) carry <- mkRegU();
    Reg#(Bit#(TAdd#(TLog#(n),1))) i  <- mkReg(fromInteger(valueOf(n)+1));

    rule mulStep(i < fromInteger(valueOf(n)));
        Bit#(TAdd#(n, 1)) sum = zeroExtend(carry) + zeroExtend( (b[0] == 1) ? a : 0 );
        res[i] <= sum[0];
        carry  <= truncateLSB(sum);
        b      <= b >> 1;
        i      <= i + 1;
    endrule
    method Bool start_ready();
        return i == fromInteger(valueOf(n)+1);
    endmethod

    method Action start( Bit#(n) aIn, Bit#(n) bIn ) if( i == fromInteger(valueOf(n)+1));
        a     <= aIn;
        b     <= bIn;
        carry <= 0;
        i     <= 0;
    endmethod

    method Bool result_ready();
        return i == fromInteger(valueOf(n));
    endmethod

    method ActionValue#(Bit#(TAdd#(n,n))) result();
        i <= i + 1;
        return {carry, res};
    endmethod
endmodule


function Bit#(n) arth_shift(Bit#(n) a, Integer n, Bool right_shift);
    Int#(n) a_int = unpack(a);
    if (right_shift) begin
        return  pack(a_int >> n);
    end else begin //left shift
        return  pack(a_int <<n);
    end
endfunction

// Booth Multiplier
//1 p = {A, Q};  Q初始值 = {r, 1'b0};  A初始值= 0(N位)
//2 -m和+m的计算结果都是存储在Q中的，因此m_neg和m_pos都填充为2n+1位,并且在Q的位置为有效数据
//3 常规的计算过程应该是-m或者m左移然后累加，但是经过上述操作之后，p的算数右移相当于-m或者m的左移
module mkBoothMultiplier( Multiplier#(n) );
    Reg#(Bit#(TAdd#(TAdd#(n,n),1))) m_pos <- mkRegU;
    Reg#(Bit#(TAdd#(TAdd#(n,n),1))) m_neg <- mkRegU;
    Reg#(Bit#(TAdd#(TAdd#(n,n),1))) p <- mkRegU;      
    Reg#(Bit#(TAdd#(TLog#(n),1))) i <- mkReg( fromInteger(valueOf(n)+1) );


    rule mul_step(i < fromInteger(valueOf(n)));
        let pr = p[1:0];
        Bit#(TAdd#(TAdd#(n,n), 1)) temp = p;

        if (pr == 2'b01) begin
            temp = p + m_pos;
        end

        if (pr == 2'b10) begin
            temp = p + m_neg;
        end
        p <= arth_shift(temp, 1, True);
        i <= i + 1;
    endrule

    method Bool start_ready();
        return i == fromInteger(valueOf(n) + 1);
    endmethod

    method Action start( Bit#(n) m, Bit#(n) r ) if (i == fromInteger(valueOf(n) + 1));
        m_pos <= {m, 0};
        m_neg <= {-m, 0};
        p <= {0, r, 1'b0};
        i <= 0;
    endmethod

    method Bool result_ready();
        return i == fromInteger(valueOf(n));
    endmethod

    method ActionValue#(Bit#(TAdd#(n,n))) result() if (i == fromInteger(valueOf(n)));
        i <= i + 1;
        //$display("p : %b", p );
        return truncateLSB(p);
    endmethod
endmodule

//============================================================================//
//mkBoothMultiplier1
//解决最负数的问题
//假设N为4，则当测试值是m为'b1000的时候，该值表示是-15，-m的理论值是15，但是4位有符号数并不能表示出该数，因此最负数时一个特例。
//
//============================================================================//
module mkBoothMultiplier1 #(Bool isSign)( Multiplier#(n) )
    provisos(Add#(1, a__, n)); // make sure n >= 1   //因为mkBoothMultiplier中位n >= 2,因此这里是n >= 1
    Multiplier#(TAdd#(n,1)) bmAddOne <- mkBoothMultiplier();

    method Bool start_ready();
        return bmAddOne.start_ready;
    endmethod

    method Action start( Bit#(n) m, Bit#(n) r ) if (bmAddOne.start_ready);
        Bit#(TAdd#(n,1)) m_ext ;
        Bit#(TAdd#(n,1)) r_ext ;
        if(isSign) begin
            m_ext = signExtend(m);
            r_ext = signExtend(r);
        end else begin
            m_ext = zeroExtend(m);
            r_ext = zeroExtend(r);
        end
        bmAddOne.start( m_ext, r_ext );
    endmethod

    method Bool result_ready();
        return bmAddOne.result_ready;
    endmethod

    method ActionValue#(Bit#(TAdd#(n,n))) result() if (bmAddOne.result_ready);
        let res <- bmAddOne.result();
        //$display("res : %b", res );
        return truncate(res);
    endmethod
endmodule



// Radix-4 Booth Multiplier
module mkBoothMultiplierRadix4( Multiplier#(n) )
	provisos(Mul#(a__, 2, n), Add#(1, b__, a__)); // make sure n >= 2 and n is even

    Reg#(Bit#(TAdd#(TAdd#(n,n),2))) m_pos <- mkRegU;
    Reg#(Bit#(TAdd#(TAdd#(n,n),2))) m_neg <- mkRegU;
    Reg#(Bit#(TAdd#(TAdd#(n,n),2))) p <- mkRegU;
    Reg#(Bit#(TAdd#(TLog#(n),1))) i <- mkReg( fromInteger(valueOf(n)/2+1) );

    rule mul_step(i < fromInteger(valueOf(n))/2);
        let pr  = p[2:0];
        Bit#(TAdd#(TAdd#(n, n), 2)) temp = p;

        if ((pr == 3'b001) || (pr == 3'b010)) begin temp = p + m_pos; end
        if ((pr == 3'b101) || (pr == 3'b110)) begin temp = p + m_neg; end
        if (pr == 3'b011) begin temp = p + arth_shift(m_pos, 1, False); end
        if (pr == 3'b100) begin temp = p + arth_shift(m_neg, 1, False); end

        p <= arth_shift(temp, 2, True);
        i <= i + 1;
    endrule

    method Bool start_ready();
        return i == fromInteger(valueOf(n)/2 + 1);
    endmethod

    method Action start( Bit#(n) m, Bit#(n) r ) if (i == fromInteger(valueOf(n)/2 + 1));
        m_pos <= {msb(m), m, 0};
        m_neg <= {msb(-m), -m, 0};
        p <= {0, r, 1'b0};
        i <= 0;
    endmethod

    method Bool result_ready();
        return i == fromInteger(valueOf(n)/2);
    endmethod

    method ActionValue#(Bit#(TAdd#(n,n))) result() if (i == fromInteger(valueOf(n)/2));
        i <= i + 1;
        return p [(2*valueOf(n)):1];
    endmethod
endmodule

