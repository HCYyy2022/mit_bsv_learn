// Ehr.bsv
// For 6.175, Fall 2014
// 
// CM for Ehr#(2,t) ehr:
//
//                  |   ehr[0]._read    ehr[0]._write   ehr[1]._read    ehr[1]._write
// -----------------+---------------------------------------------------------------
// ehr[0]._read     |       CF              <               CF              <
// ehr[0]._write    |       >               C               <               <
// ehr[1]._read     |       CF              >               CF              <
// ehr[1]._write    |       >               >               >               C

import Vector::*;
import RWire::*;
import RevertingVirtualReg::*;

typedef Vector#(n, Reg#(t)) Ehr#(numeric type n, type t);

module mkEhr( t initVal, Ehr#(n,t) ifc ) provisos(Bits#(t, tSz));
    Reg#(t) ehrReg <- mkReg( initVal );

    // Allows read(i+1) to be in the same cycle as write(i)
    Vector#(n, RWire#(t)) wires <- replicateM( mkUnsafeRWire );     //mkUnsafeRWire功能同mkRWire,但是read和write可以写在同一个rule内; 二者方法都没有隐式条件

    // Additional objects to force the requested schedule
    // These will both be optimized out during FPGA synthesis
    Vector#(n, Reg#(Bool)) virtual_reg <- replicateM( mkRevertingVirtualReg(False) );   //使用mkRevertingVirtualReg在方法间或者方法和rule间强制添加调度属性
    Vector#(n, RWire#(t)) ignored_wires <- replicateM( mkUnsafeRWire );

    Ehr#(n,t) ifc_to_return;    //n个接口

    // These attributes are statically checked by the compiler
    (* fire_when_enabled *)         // WILL_FIRE == CAN_FIRE       //检查一个规则是否因为与其他规则有冲突，且紧急程度较低，而导致在本来该激活（显式和隐式条件都满足）时被抑制了激活。
    (* no_implicit_conditions *)    // CAN_FIRE == guard (True)    //用于断言：一个规则中所有的方法不含隐式条件
    rule canonicalize;
        t val = ehrReg;
        for( Integer i = 0 ; i < valueOf(n) ; i = i + 1 ) begin
            val = fromMaybe( val, wires[i].wget );
        end
        ehrReg <= val;
    endrule

    for( Integer i = 0 ; i < valueOf(n) ; i = i + 1 ) begin   //每个接口方法的具体实现
        ifc_to_return[i] =
            (interface Reg;
                method Action _write(t x);
                    // Performs write
                    wires[i].wset(x);

                    // Ensures write j < write i for j < i
                    t ignore = ehrReg;
                    for( Integer j = 0 ; j < i ; j = j+1 ) begin
                        ignore = fromMaybe( ignore, wires[j].wget );    //因为wires[j].wget < wires[j].set, 因此write j < write i for j < i
                    end
                    // Do something with ignore so the compiler doesn't optimize it out
                    ignored_wires[i].wset(ignore);

                    // Helps ensure that read j < write i for j <= i
                    virtual_reg[i] <= True;               //_write method < _read method
                endmethod
                method t _read;
                    // Gets the value to return
                    // Also ensures that write j < read i for j < i
                    t val = ehrReg;                                   //上一周期寄存器中的值
                    for( Integer j = 0 ; j < i ; j = j+1 ) begin      //当有序号小的接口调用write之后，读出值为最接近的序号小的接口写入的值
                        val = fromMaybe( val, wires[j].wget );
                    end

                    // Helps ensure that read i < write j for i <= j
                    for( Integer j = i ; j < valueOf(n) ; j = j+1 ) begin    //因为virtual_reg[j]._read < virtual_reg[j]._write, 因此read i method < write j method for i <= j
                        if( virtual_reg[j] ) begin
                            // This is impossible because virtual_reg will always be False when read
                            val = unpack(0);
                        end
                    end

                    // Return the value read
                    return val;
                endmethod
            endinterface);
    end
    return ifc_to_return;
endmodule

module mkEhrU( Ehr#(n,t) ) provisos(Bits#(t, tSz));
    let m <- mkEhr( ? );
    return m;
endmodule

