PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO = $(PRIV_DIR)/expty.so
SPAWN_HELPER = $(PRIV_DIR)/spawn-helper

C_SRC = $(shell pwd)/c_src
LIB_SRC = $(shell pwd)/lib
LIBUV_SRC = $(shell pwd)/3rd_party/libuv-1.44.2
LIBUV_BUILD_DIR = $(MIX_APP_PATH)/cmake_libuv-1.44.2
LIBUV_A = $(PRIV_DIR)/lib/libuv_a.a
CPPFLAGS += -std=c++14 -O3 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -fPIC
CPPFLAGS += -I"$(ERTS_INCLUDE_DIR)"
NIF_CPPFLAGS = $(CPPFLAGS) -I"$(PRIV_DIR)/include" -L"$(PRIV_DIR)/lib" -luv_a

UNAME_S := $(shell uname -s)
ifndef TARGET_ABI
ifeq ($(UNAME_S),Darwin)
	TARGET_ABI = darwin
endif
endif

ifeq ($(TARGET_ABI),darwin)
	CPPFLAGS += -undefined dynamic_lookup -flat_namespace -undefined suppress
endif

.DEFAULT_GLOBAL := build

build: $(NIF_SO) $(SPAWN_HELPER)
	@ echo > /dev/null

$(PRIV_DIR):
	@ mkdir -p "$(PRIV_DIR)"

$(LIBUV_A): $(PRIV_DIR)
	@ if [ ! -e "$(LIBUV_A)" ]; then \
		mkdir -p "$(LIBUV_BUILD_DIR)" && \
		cd "$(LIBUV_BUILD_DIR)" && \
		cmake "$(LIBUV_SRC)" -D CMAKE_INSTALL_PREFIX="$(PRIV_DIR)" && \
		cmake --build . && \
		cmake --install . ; \
	fi

$(NIF_SO): $(PRIV_DIR) $(LIBUV_A)
	$(CC) $(NIF_CPPFLAGS) -shared "$(C_SRC)/pty.cpp" -o "$(NIF_SO)"

$(SPAWN_HELPER): $(PRIV_DIR)
	@ if [ ! -e "$(SPAWN_HELPER)" ]; then \
		$(CC) $(CPPFLAGS) "$(C_SRC)/spawn-helper.cpp" -o "$(SPAWN_HELPER)" ; \
	fi

clean:
	rm -f $(NIF_SO)
	rm -f $(SPAWN_HELPER)
