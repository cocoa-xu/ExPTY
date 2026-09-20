PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO = $(PRIV_DIR)/expty.so
SPAWN_HELPER = $(PRIV_DIR)/spawn-helper

C_SRC = $(shell pwd)/c_src
LIB_SRC = $(shell pwd)/lib
NIF_BUILD_DIR = $(MIX_APP_PATH)/cmake_expty
NIF_SOURCES = $(shell find "$(C_SRC)" -type f) CMakeLists.txt

DEFAULT_JOBS ?= 1
MAKE_BUILD_FLAGS ?= -j$(DEFAULT_JOBS)

.DEFAULT_GOAL := build

build: $(NIF_SO)
	@ echo > /dev/null

$(PRIV_DIR):
	@ mkdir -p "$(PRIV_DIR)"

$(NIF_SO): $(PRIV_DIR) $(NIF_SOURCES)
	@ mkdir -p "$(NIF_BUILD_DIR)" && \
		cd "$(NIF_BUILD_DIR)" && \
		cmake "$(shell pwd)" -D CMAKE_INSTALL_PREFIX="$(PRIV_DIR)" \
			-D C_SRC="$(C_SRC)" \
			-D CMAKE_TOOLCHAIN_FILE="$(TOOLCHAIN_FILE)" \
			-D MIX_APP_PATH="$(MIX_APP_PATH)" \
			-D PRIV_DIR="$(PRIV_DIR)" \
			-D ERTS_INCLUDE_DIR="$(ERTS_INCLUDE_DIR)" && \
		cmake --build . $(MAKE_BUILD_FLAGS) && \
		cmake --install .

cleanup:
	@ rm -rf "$(PRIV_DIR)"
	@ rm -rf "$(NIF_BUILD_DIR)"
