PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO = $(PRIV_DIR)/expty.so
SPAWN_HELPER = $(PRIV_DIR)/spawn-helper

C_SRC = $(shell pwd)/c_src
LIB_SRC = $(shell pwd)/lib
LIBUV_SRC = $(shell pwd)/3rd_party/libuv-1.51.0
LIBUV_BUILD_DIR = $(MIX_APP_PATH)/cmake_libuv-1.51.0
LIBUV_INSTALL_DIR = $(MIX_APP_PATH)/libuv
LIBUV_A = $(LIBUV_INSTALL_DIR)/lib/libuv_a.a
LIBUV_CMAKE_SOURCE_DIR = $(LIBUV_INSTALL_DIR)/cmake/libuv
NIF_BUILD_DIR = $(MIX_APP_PATH)/cmake_expty

DEFAULT_JOBS ?= 1
MAKE_BUILD_FLAGS ?= -j$(DEFAULT_JOBS)

.DEFAULT_GLOBAL := build

build: $(NIF_SO)
	@ echo > /dev/null

$(PRIV_DIR):
	@ mkdir -p "$(PRIV_DIR)"

$(LIBUV_A): $(PRIV_DIR)
	@ if [ ! -e "$(LIBUV_A)" ]; then \
		mkdir -p "$(LIBUV_BUILD_DIR)" && \
		mkdir -p "$(NIF_BUILD_DIR)" && \
		cd "$(LIBUV_BUILD_DIR)" && \
		cmake "$(LIBUV_SRC)" -D CMAKE_INSTALL_PREFIX="$(LIBUV_INSTALL_DIR)" -D CMAKE_C_FLAGS="-fPIC" -D CMAKE_CXX_FLAGS="-fPIC" && \
		cmake --build . $(MAKE_BUILD_FLAGS) && \
		cmake --install . ; \
	fi

$(NIF_SO): $(PRIV_DIR) $(LIBUV_A)
	@ if [ ! -e "$(NIF_SO)" ]; then \
		mkdir -p "$(NIF_BUILD_DIR)" && \
		cd "$(NIF_BUILD_DIR)" && \
		cmake "$(shell pwd)" -D CMAKE_INSTALL_PREFIX="$(PRIV_DIR)" \
			-D LIBUV_INCLUDE_DIR="$(LIBUV_INSTALL_DIR)/include" \
			-D LIBUV_LIBRARIES_DIR="$(LIBUV_INSTALL_DIR)/lib" \
			-D LIBUV_CMAKE_SOURCE_DIR="$(LIBUV_CMAKE_SOURCE_DIR)" \
			-D C_SRC="$(C_SRC)" \
			-D CMAKE_TOOLCHAIN_FILE="$(TOOLCHAIN_FILE)" \
			-D MIX_APP_PATH="$(MIX_APP_PATH)" \
			-D PRIV_DIR="$(PRIV_DIR)" \
			-D ERTS_INCLUDE_DIR="$(ERTS_INCLUDE_DIR)" && \
		cmake --build . $(MAKE_BUILD_FLAGS) && \
		cmake --install . ; \
	fi

cleanup:
	@ rm -rf "$(PRIV_DIR)"
	@ rm -rf "$(LIBUV_BUILD_DIR)"
	@ rm -rf "$(LIBUV_INSTALL_DIR)"
	@ rm -rf "$(NIF_BUILD_DIR)"
