# Copyright (c) 2022, Alibaba Group Holding Limited
#!/bin/sh

android_archs=(armeabi-v7a arm64-v8a)
ios_archs=(armv7 arm64 x86_64)
hmos_archs=(arm64-v8a)
CMAKE_CMD="cmake"
cur_dir=$(cd "$(dirname "$0")";pwd)

platform=$1
build_dir=$2
artifact_dir=$3

# boringssl is used as default
ssl_type="boringssl"

# The root CMakeLists falls back to find_package(SSL) when SSL_INC_PATH and
# SSL_LIB_PATH are both unset. The Android NDK toolchain sets
# CMAKE_FIND_ROOT_PATH_MODE_{INCLUDE,LIBRARY}=ONLY, which confines find_path and
# find_library to the sysroot and makes that discovery impossible, so both paths
# have to be supplied here for CMake to merely EXISTS-check them.
ssl_inc_path=$4
ssl_lib_path=$5

if [ -z "$ssl_inc_path" ] || [ -z "$ssl_lib_path" ] ; then
    echo "usage: $0 <platform> <build_dir> <artifact_dir> <ssl_inc_path> <ssl_lib_path>"
    echo "  ssl_inc_path: directory holding openssl/ssl.h"
    echo "  ssl_lib_path: semicolon-separated static libs, for example"
    echo "                /path/to/libssl.a;/path/to/libcrypto.a"
    exit 1
fi

if [ ! -d "$ssl_inc_path" ] ; then
    echo "ssl include directory not exists: $ssl_inc_path"
    exit 1
fi

create_dir_force() {
    if [ x"$2" == x ] ; then
        echo "$1 MUST NOT be empty"
        exit 1
    fi
    if [ -d $2 ] ; then
        rm -rf $2
    fi
    mkdir $2
    echo "create $1 directory($2) suc"
}

platform=$(echo $platform | tr A-Z a-z )

# Shared by every platform. Keep the flags newline-separated: $configures is
# expanded unquoted below, so a newline is what keeps SSL_LIB_PATH's ';' from
# swallowing the flag that follows it.
common_configures="-DSSL_TYPE=${ssl_type}
                   -DSSL_INC_PATH=${ssl_inc_path}
                   -DSSL_LIB_PATH=${ssl_lib_path}
                   -DCMAKE_BUILD_TYPE=Minsizerel
                   -DXQC_ENABLE_TESTING=OFF
                   -DGCOV=OFF
                   -DXQC_ENABLE_RENO=OFF
                   -DXQC_ENABLE_BBR2=ON
                   -DXQC_ENABLE_COPA=OFF
                   -DXQC_ENABLE_UNLIMITED=OFF
                   -DXQC_ENABLE_MP_INTEROP=OFF
                   -DXQC_DISABLE_LOG=OFF
                   -DXQC_ONLY_ERROR_LOG=ON
                   -DXQC_COMPAT_GENERATE_SR_PKT=ON"

if [ x"$platform" == xios ] ; then
    if [ x"$IOS_CMAKE_TOOLCHAIN" == x ] ; then
        echo "IOS_CMAKE_TOOLCHAIN MUST be defined"
        exit 0
    fi

    archs=${ios_archs[@]}
    configures="${common_configures}
                -DCMAKE_TOOLCHAIN_FILE=${IOS_CMAKE_TOOLCHAIN}
                -DDEPLOYMENT_TARGET=10.0
                -DENABLE_BITCODE=OFF
                -DXQC_NO_SHARED=ON"

elif [ x"$platform" == xandroid ] ; then
    if [ x"$ANDROID_NDK" == x ] ; then
        echo "ANDROID_NDK MUST be defined"
        exit 0
    fi

    archs=${android_archs[@]}
    configures="${common_configures}
                -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake
                -DANDROID_NATIVE_API_LEVEL=android-19"

elif [ x"$platform" == xharmony ] ; then
    if [ x"$HMOS_CMAKE_TOOLCHAIN" == x ] ; then
        echo "HMOS_CMAKE_TOOLCHAIN MUST be defined"
        exit 0
    fi
    echo "HMOS_CMAKE_TOOLCHAIN: ${HMOS_CMAKE_TOOLCHAIN}"

    if [ x"$HMOS_CMAKE_PATH" == x ] ; then
        echo "HMOS_CMAKE_PATH MUST be defined"
        exit 0
    fi
    echo "HMOS_CMAKE_PATH: ${HMOS_CMAKE_PATH}"
    CMAKE_CMD=${HMOS_CMAKE_PATH}

    archs=${hmos_archs[@]}
    configures="${common_configures}
                -DCMAKE_TOOLCHAIN_FILE=${HMOS_CMAKE_TOOLCHAIN}
                -DDISABLE_WARNINGS=ON"
else
    echo "no support platform"
    exit 0
fi


generate_plat_spec() {
    plat_spec=
    if [ x"$platform" == xios ] ; then
        plat_spec="-DARCHS=$1"
        if [ x"$1" == xx86_64 ] ; then
            plat_spec="$plat_spec -DPLATFORM=SIMULATOR64"
        elif [ x"$1" == xi386 ] ; then
            plat_spec="$plat_spec -DPLATFORM=SIMULATOR"
        fi
    elif [ x"$platform" == xharmony ] ; then
        plat_spec="-DOHOS_ARCH=$1"
    else
        plat_spec="-DANDROID_ABI=$1"
    fi
    echo $plat_spec
}

create_dir_force build $build_dir
# to absoulute path 
build_dir=$cur_dir/$build_dir

create_dir_force artifact $artifact_dir
artifact_dir=$cur_dir/$artifact_dir

# Bail out if this fails: the loop below deletes relative paths such as
# include/, which would hit the source tree if the working directory were
# still the repository root.
cd $build_dir || exit 1

for i in ${archs[@]} ;
do
    rm -f  CMakeCache.txt
    rm -rf CMakeFiles
    rm -rf Makefile
    rm -rf cmake_install.cmake
    rm -rf include
    rm -rf outputs
    rm -rf third_party

    echo "compiling xquic on $i arch"
    "${CMAKE_CMD}"  $configures  $(generate_plat_spec $i ) -DLIBRARY_OUTPUT_PATH=`pwd`/outputs/ ..
    make -j 4
    if [ $? != 0 ] ; then
        exit 0
    fi

    if [ ! -d  ${artifact_dir}/$i ] ; then
        mkdir -p ${artifact_dir}/$i
    fi
    cp -f `pwd`/outputs/*.a     ${artifact_dir}/$i/
    cp -f `pwd`/outputs/*.so    ${artifact_dir}/$i/
done


make_fat() {
    script="lipo -create"
    for i in ${archs[@]} ;
    do
        script="$script -arch $i $artifact_dir/$i/$1  "
    done
    script="$script -output $cur_dir/ios/xquic/xquic/Libs/$1"
    $($script) 
}


if [ x"$platform" == xios ] ; then
    if [ ! -d $cur_dir/ios/xquic/xquic/Headers ] ; then
        mkdir -p $cur_dir/ios/xquic/xquic/Headers
    fi
    if [ ! -d $cur_dir/ios/xquic/xquic/Libs ] ; then
        mkdir -p $cur_dir/ios/xquic/xquic/Libs
    fi
    make_fat libxquic.a
    make_fat libcrypto.a
    make_fat libssl.a
    cp -f $cur_dir/include/xquic/*   $cur_dir/ios/xquic/xquic/Headers/
    cp -f $build_dir/include/xquic/* $cur_dir/ios/xquic/xquic/Headers/

fi


