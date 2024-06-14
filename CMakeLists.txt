cmake_minimum_required(VERSION 3.12 FATAL_ERROR)
project(expty)

if(NOT DEFINED CMAKE_BUILD_TYPE OR "${CMAKE_BUILD_TYPE}" STREQUAL "")
    set(CMAKE_BUILD_TYPE "Release")
endif()

# ========= PRIV_DIR & ERTS_INCLUDE_DIR =========

if(DEFINED MIX_APP_PATH AND NOT "${MIX_APP_PATH}" STREQUAL "")
    set(PRIV_DIR "${MIX_APP_PATH}/priv")
else()
    set(PRIV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/priv")
endif()
message(STATUS "Using PRIV_DIR: ${PRIV_DIR}")

if(DEFINED ERTS_INCLUDE_DIR AND NOT "${ERTS_INCLUDE_DIR}" STREQUAL "")
    set(ERTS_INCLUDE_DIR "${ERTS_INCLUDE_DIR}")
else()
    if(WIN32)
        execute_process(COMMAND powershell -command "erl -noshell -s init stop -eval \"io:format('~ts/erts-~ts/include/', [code:root_dir(), erlang:system_info(version)]).\"" OUTPUT_VARIABLE ERTS_INCLUDE_DIR)
    else()
        execute_process(COMMAND bash -c "erl -noshell -s init stop -eval \"io:format('~ts/erts-~ts/include/', [code:root_dir(), erlang:system_info(version)]).\"" OUTPUT_VARIABLE ERTS_INCLUDE_DIR)
    endif()
    set(ERTS_INCLUDE_DIR "${ERTS_INCLUDE_DIR}")
endif()
message(STATUS "Using ERTS_INCLUDE_DIR: ${ERTS_INCLUDE_DIR}")

include_directories(${ERTS_INCLUDE_DIR})
include_directories(${C_SRC})

# ===============================================

if(POLICY CMP0068)
    cmake_policy(SET CMP0068 NEW)
endif()

if(WIN32)
    string(REPLACE "\\" "/" C_SRC "${C_SRC}")
    file(GLOB expty_src "${C_SRC}/win/path_util.cc" "${C_SRC}/win/conpty.cc")
    file(GLOB expty_conpty_console_list_src "${C_SRC}/win/conpty_console_list.cc")
else()
    file(GLOB expty_src "${C_SRC}/unix/pty.cpp")
    file(GLOB expty_spawn_helper_src "${C_SRC}/unix/spawn-helper.cpp")
endif()

# ==================== expty ====================

add_library(expty SHARED ${expty_src})

if(NOT WIN32)
    list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
    include(FindLibX)
    find_lib_x(util util.h pty.h)
    target_include_directories(expty PUBLIC "${LIBUTIL_INCLUDE_DIR}")
    target_link_libraries(expty "${LIBUTIL_LIBRARIES}")
endif()
target_include_directories(expty PUBLIC "${LIBUV_INCLUDE_DIR}")
target_link_directories(expty PUBLIC "${LIBUV_LIBRARIES_DIR}")
set_property(TARGET expty PROPERTY CXX_STANDARD 14)
set_target_properties(expty PROPERTIES PREFIX "")
set_target_properties(expty PROPERTIES
    INSTALL_RPATH_USE_LINK_PATH TRUE
    BUILD_WITH_INSTALL_RPATH TRUE
)
install(TARGETS expty DESTINATION "${PRIV_DIR}")
if(NOT WIN32)
    set_target_properties(expty PROPERTIES SUFFIX ".so")
    target_link_libraries(expty "uv_a")
else()
    target_link_libraries(expty PRIVATE "uv_a" "Shlwapi" "Ws2_32" "Iphlpapi" "Userenv")
endif()

# ===============================================

# ==================== helper ====================

if(WIN32)
    add_executable(conpty_console_list ${expty_conpty_console_list_src})
    install(
        TARGETS conpty_console_list
        RUNTIME DESTINATION "${PRIV_DIR}"
    )
    set_property(TARGET conpty_console_list PROPERTY CXX_STANDARD 14)
else()
    set(CMAKE_THREAD_PREFER_PTHREAD TRUE)
    set(THREADS_PREFER_PTHREAD_FLAG TRUE)
    find_package(Threads REQUIRED)
    add_executable(spawn-helper ${expty_spawn_helper_src})
    target_link_libraries(spawn-helper Threads::Threads)
    install(
        TARGETS spawn-helper
        RUNTIME DESTINATION "${PRIV_DIR}"
    )
    set_property(TARGET spawn-helper PROPERTY CXX_STANDARD 14)
endif()

# ===============================================

if(UNIX AND NOT APPLE)
    set_target_properties(expty PROPERTIES INSTALL_RPATH "\$ORIGIN/lib")
elseif(UNIX AND APPLE)
    # Although the compiler complains about not using these,
    # things only work with them set
    set(CMAKE_SHARED_LINKER_FLAGS "-flat_namespace -undefined suppress -undefined dynamic_lookup")
    set_target_properties(expty PROPERTIES INSTALL_RPATH "@loader_path/lib")
endif()

if(WIN32)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /bigobj /wd4996 /wd4267 /wd4068")
else()
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g3")
    else()
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3")
    endif()

    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fPIC -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wno-deprecated-declarations -Wno-unused-but-set-variable")
endif()
