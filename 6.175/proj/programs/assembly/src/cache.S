
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

	# Look at cache lines at 0x4000, 0x6000
	la x1, 0x04000
	la x2, 0x06000

	# Store some data into a single cache line
	# I -> M
	li x3, 0x100
	sw x3, 0(x1)   #st 0x100 到0x4000
	# Write hit
	li x3, 0x101    
	sw x3, 4(x1)   #st 0x101  到0x4004

	# Now store some data into another cache line with the same index
	# M -> I -> M
	li x3, 0x200
	sw x3, 0(x2)    #st 0x200 到 0x6000
	# Write hit
	li x3, 0x201
	sw x3, 4(x2)    #st 0x201 到 0x6004

	# Now read the data
	# M -> I -> S
	lw x3, 0(x1)       #读取0x4000处的数据
	li x4, 0x100
	li TESTNUM, 1
	bne x4, x3, fail   #比较0x4000处的读取值是否是0x100
	# Read hit
	lw x3, 4(x1)
	li x4, 0x101
	li TESTNUM, 2
	bne x4, x3, fail   #比较0x4004处的值是否是0x101

	# Now add 0x0F0 to each entry in the current cache line
	# Read hit
	lw x3, 0(x1)                
	addi x3, x3, 0x0F0    #读取0x4000处的数据并将读出值加上0x0f0
	# S -> M
	sw x3, 0(x1)          #将计算结果写回0x4000地址处
	# Read/Write hit
	lw x3, 4(x1)
	addi x3, x3, 0x0F0  #读取0x4004处的数据并将读出值加上0x0f0
	sw x3, 4(x1)        #将计算结果写回0x4004地址处

	# Now read from another cache line to evect the current cache line
	# M -> I -> S
	lw x3, 0(x2)
	li x4, 0x200
	li TESTNUM, 3
	bne x4, x3, fail   #比较0x6000处的数据是否是0x200
	# Read hit
	lw x3, 4(x2)
	li x4, 0x201
	li TESTNUM, 4
	bne x4, x3, fail  #比较0x6004处的数据是否是0x201

	# Now read the main cache line to check the previous additions
	# S -> I -> S
	lw x3, 0(x1)
	li x4, 0x1F0
	li TESTNUM, 5
	bne x4, x3, fail   #读出0x4000处的数据并判断是否是0x1f0
	# Read hit
	lw x3, 4(x1)
	li x4, 0x1F1
	li TESTNUM, 6
	bne x4, x3, fail   ##读出0x4004处的数据并判断是否是0x1f1

	# If we get here then we passed
	j pass


TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
