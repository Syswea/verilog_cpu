#=============================================================================
# Makefile — tb_decode 单元测试（decode.v, L1）
#=============================================================================
# 用法（在本目录下执行）：
#   make lint     # 仅语法检查 DUT
#   make sim      # 编译并运行 TB（默认目标）
#   make clean    # 删除编译产物
#
# 相对路径以本 Makefile 所在目录（src/tbsim/tb_decode/）为基准。
#=============================================================================

TB      := tb_decode.v
DUT     := ../../rtl/stage/id_stage/decode.v
INCDIR  := -I../../rtl/defines
OBJ     := build
SIM     := sim_tb_decode

.PHONY: all lint sim clean

all: sim

# 语法检查（lint）：仅编译不生成仿真
lint:
	verilator --lint-only $(INCDIR) $(DUT)

# 编译 + 运行（--assert 启用断言；--timing 支持仿真任务）
sim: $(TB) $(DUT)
	verilator --cc --binary --assert --timing $(INCDIR) \
		--top-module tb_decode --Mdir $(OBJ) \
		$(TB) $(DUT) -o $(SIM)
	./$(OBJ)/$(SIM)

clean:
	rm -rf $(OBJ)
