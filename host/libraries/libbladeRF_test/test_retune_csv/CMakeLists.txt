cmake_minimum_required(VERSION 3.5)
project(libbladeRF_test_retune_csv C)

include_directories(${libbladeRF_SOURCE_DIR}/include)

set(INCLUDES
    ./include
    ${libbladeRF_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../common/include
    ${libbladeRF_SOURCE_DIR}/src
    ${BLADERF_HOST_COMMON_INCLUDE_DIRS}
)

include_directories(${INCLUDES})

if(MSVC)
    set(INCLUDES ${INCLUDES} ${MSVC_C99_INCLUDES})
endif()

set(LIBS libbladerf_shared)

set(SRC
        ./src/main.c
        ./src/include.c
        ../common/src/test_common.c
        ${BLADERF_HOST_COMMON_SOURCE_DIR}/log.c
        ${BLADERF_HOST_COMMON_SOURCE_DIR}/devcfg.c
        ${BLADERF_HOST_COMMON_SOURCE_DIR}/conversions.c
)
if(MSVC)
    set(SRC ${SRC}
        ${BLADERF_HOST_COMMON_SOURCE_DIR}/windows/getopt_long.c
    )
endif()

include_directories(${INCLUDES})
add_executable(libbladeRF_test_retune_csv ${SRC})
target_link_libraries(libbladeRF_test_retune_csv ${LIBS})
