cmake_minimum_required(VERSION 3.10)
project(otclient)

# 1. Enforce modern Windows target globally
add_compile_definitions(_WIN32_WINNT=0x0A00)
add_compile_definitions(NTDDI_VERSION=0x0A000000)

# FIX: Removed the trailing space inside the quotes so MSVC parses the flag correctly
set(CMAKE_INCLUDE_SYSTEM_FLAG_CXX "-I")
set(CMAKE_INCLUDE_SYSTEM_FLAG_C "-I")

# Global include directories applied to ALL targets created downstream
include_directories("C:/Users/AnthonyWIWI/vcpkg/installed/x64-windows/include")

if(CMAKE_BASE_NAME STREQUAL "em++")                
    set(WASM ON)
endif()

set(CMAKE_CXX_STANDARD 17)

# default build type
if(NOT CMAKE_BUILD_TYPE)    
    set(CMAKE_BUILD_TYPE "Release")
endif()

# Enable /bigobj for MSVC to handle large object files from Boost templates
if(MSVC)
    add_compile_options(/bigobj)
endif()

option(FRAMEWORK_SOUND "Use SOUND " OFF)
option(FRAMEWORK_GRAPHICS "Use GRAPHICS " ON)
option(FRAMEWORK_XML "Use XML " ON)
option(FRAMEWORK_NET "Use NET " ON)

# Load sub-directories (creates source lists like framework_SOURCES)
include(src/framework/CMakeLists.txt)
include(src/client/CMakeLists.txt)

# Functions map for reading backtraces
if(NOT APPLE AND NOT WASM)    
    set(CMAKE_CXX_LINK_FLAGS "${CMAKE_CXX_LINK_FLAGS} -no-pie -Wl,-Map=${PROJECT_NAME}.map")
endif()

set(executable_SOURCES
    src/main.cpp
)

# Add executable icon for win32 platforms
if(WIN32)            
    add_custom_command(OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/otcicon.res
                       COMMAND ${CMAKE_RC_COMPILER}
                       /i "${CMAKE_CURRENT_SOURCE_DIR}/src"
                       /fo "${CMAKE_CURRENT_BINARY_DIR}/otcicon.res"
                       "${CMAKE_CURRENT_SOURCE_DIR}/src/otcicon.rc")            
    set(executable_SOURCES ${executable_SOURCES} ${CMAKE_CURRENT_BINARY_DIR}/otcicon.res)
endif()

if(VERSION)            
    add_definitions(-D"VERSION=\\"${VERSION}\\"")
endif()

# 2. Add client executable (This creates the "otclient" target)
add_executable(${PROJECT_NAME} ${framework_SOURCES} ${client_SOURCES} ${executable_SOURCES})

# Explicitly bind Boost & vcpkg includes into the target locally
target_include_directories(${PROJECT_NAME} PRIVATE "C:/Users/AnthonyWIWI/vcpkg/installed/x64-windows/include")

target_link_libraries(${PROJECT_NAME} ${framework_LIBRARIES})

if(APPLE AND USE_STATIC_LIBS)
    target_link_libraries(${PROJECT_NAME} "-framework Foundation" "-framework IOKit")
endif()

# Copy vcpkg DLLs to output directory on Windows
if(WIN32 AND MSVC)
    set(VCPKG_BIN_DIR "$ENV{VCPKG_ROOT}/installed/x64-windows/bin")
    if(NOT EXISTS "${VCPKG_BIN_DIR}")
        set(VCPKG_BIN_DIR "C:/Users/AnthonyWIWI/vcpkg/installed/x64-windows/bin")
    endif()
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${VCPKG_BIN_DIR}/zlib1.dll"
            "${VCPKG_BIN_DIR}/glew32.dll"
        $<TARGET_FILE_DIR:${PROJECT_NAME}>
        COMMENT "Copying vcpkg DLLs to output directory"
    )
endif()

# 3. Aggressive Strip of the broken XP macro flag
get_target_property(FRAMEWORK_DEFS ${PROJECT_NAME} COMPILE_DEFINITIONS)
if(FRAMEWORK_DEFS)
    list(REMOVE_ITEM FRAMEWORK_DEFS "_WIN32_WINNT=0x0501")
    set_target_properties(${PROJECT_NAME} PROPERTIES COMPILE_DEFINITIONS "${FRAMEWORK_DEFS}")
endif()

# Enforce modern platform override globally downstream
target_compile_definitions(${PROJECT_NAME} PRIVATE _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000000)